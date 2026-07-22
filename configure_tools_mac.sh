#!/bin/bash
## This tool will try to detect common cli tools and will configure the Netskope SSL certificate bundle.

# Check which shell environment is used (zsh or bash)
get_shell() {
    my_shell=$(echo $SHELL)
    echo "Shell used is $my_shell"
    if [[ $my_shell == *"bash"* ]]; then
        shell=~/.bash_profile
    else
        shell=~/.zshenv
    fi
}
get_shell

# Function to check if a command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Rollback function — removes all Netskope SSL configuration
rollback() {
    echo
    echo "=== Netskope SSL Rollback ==="
    echo "Removing Netskope SSL configuration from all tools..."

    # Environment variables
    echo
    echo "--- Environment Variables ---"
    if [ -f "$shell" ]; then
        tmp=$(mktemp)
        grep -v -E '^export (SSL_CERT_FILE|AWS_CA_BUNDLE|NODE_EXTRA_CA_CERTS|REQUESTS_CA_BUNDLE|GIT_SSL_CAINFO|GIT_SSL_CAPATH)=' "$shell" > "$tmp"
        removed=$(( $(wc -l < "$shell") - $(wc -l < "$tmp") ))
        mv "$tmp" "$shell"
        echo "  $removed Netskope environment variable export(s) removed from $shell"
    else
        echo "  shell profile not found: $shell"
    fi

    # Git
    echo
    echo "--- Git ---"
    if command_exists git; then
        git config --global --unset http.sslCAInfo 2>/dev/null && \
            echo "  git http.sslCAInfo: unset" || echo "  git http.sslCAInfo: not configured"
    else
        echo "  Git is not installed"
    fi

    # .curlrc
    echo
    echo "--- cURL ---"
    if [ -f ~/.curlrc ]; then
        rm ~/.curlrc && echo "  .curlrc deleted" || echo "  .curlrc: failed to delete"
    else
        echo "  .curlrc not found"
    fi

    # Google Cloud CLI
    echo
    echo "--- Google Cloud CLI ---"
    if command_exists gcloud; then
        gcloud config unset core/custom_ca_certs_file 2>/dev/null && \
            echo "  gcloud: custom_ca_certs_file unset" || echo "  gcloud: not configured"
    else
        echo "  gcloud is not installed"
    fi

    # NPM
    echo
    echo "--- NPM ---"
    if command_exists npm; then
        npm config delete cafile 2>/dev/null && \
            echo "  npm cafile: deleted" || echo "  npm: cafile not configured"
    else
        echo "  npm is not installed"
    fi

    # PHP Composer
    echo
    echo "--- PHP Composer ---"
    if command_exists composer; then
        composer config --global --unset cafile 2>/dev/null && \
            echo "  composer cafile: unset" || echo "  composer: not configured"
    else
        echo "  composer is not installed"
    fi

    # Yarn
    echo
    echo "--- Yarn ---"
    yarn_found=0
    for yarn_cmd in yarn yarnpkg; do
        if command_exists $yarn_cmd; then
            yarn_found=1
            $yarn_cmd config delete httpsCaFilePath 2>/dev/null || $yarn_cmd config delete cafile 2>/dev/null
            echo "  $yarn_cmd: cafile config removed"
            break
        fi
    done
    if [ $yarn_found -eq 0 ]; then
        echo "  yarn is not installed"
    fi

    # Java keytool
    echo
    echo "--- Java ---"
    storepass="changeit"
    jdk_found=0
    for try_home in "$JAVA_HOME" "$(dirname "$(dirname "$(readlink "$(which java 2>/dev/null)" 2>/dev/null)" 2>/dev/null)" 2>/dev/null)"; do
        [ -z "$try_home" ] && continue
        keytool_bin="$try_home/bin/keytool"
        cacerts="$try_home/lib/security/cacerts"
        [ -f "$cacerts" ] || cacerts="$try_home/jre/lib/security/cacerts"
        if [ -f "$keytool_bin" ] && [ -f "$cacerts" ]; then
            jdk_found=1
            echo "  JDK: $try_home"
            for alias in netskope-0 netskope-1; do
                "$keytool_bin" -delete -alias "$alias" -keystore "$cacerts" \
                    -storepass "$storepass" 2>/dev/null && \
                    echo "    keytool alias $alias: removed" || \
                    echo "    keytool alias $alias: not found"
            done
        fi
    done
    if [ $jdk_found -eq 0 ]; then
        echo "  No Java installations found"
    fi

    echo
    echo "Rollback complete."
    exit 0
}

# Check for rollback mode
if [ "$1" = "--rollback" ]; then
    rollback
fi

# Check for netskope-only mode (default: full bundle, Netskope + public CA
# roots) and existing-bundle path. --full-bundle is accepted as a no-op for
# backward compatibility since it is now the default.
full_bundle=1
cert_bundle=""
tenantName=""
orgKey=""
certName=""
certDir=""
recreate_cert=0
prev=""
for arg in "$@"; do
    [ "$arg" = "--netskope-only" ] && full_bundle=0
    [ "$arg" = "--recreate" ] && recreate_cert=1
    case "$arg" in
        --cert-bundle=*)  cert_bundle="${arg#*=}" ;;
        --tenant-name=*)  tenantName="${arg#*=}" ;;
        --org-key=*)      orgKey="${arg#*=}" ;;
        --cert-name=*)    certName="${arg#*=}" ;;
        --cert-dir=*)     certDir="${arg#*=}" ;;
    esac
    case "$prev" in
        --cert-bundle)  cert_bundle="$arg" ;;
        --tenant-name)  tenantName="$arg" ;;
        --org-key)      orgKey="$arg" ;;
        --cert-name)    certName="$arg" ;;
        --cert-dir)     certDir="$arg" ;;
    esac
    prev="$arg"
done

# Tenant + orgkey supplied via CLI means this is a silent/unattended run —
# recorded now, before any prompt fills these in, so later checks can tell
# "supplied on the command line" apart from "answered a prompt".
silent_download=0
[ -n "$tenantName" ] && [ -n "$orgKey" ] && silent_download=1

# Function to create or update certificate bundle
# Fetch each URL into a temp file first and verify HTTP status (-f fails fast
# on non-2xx) + presence of a PEM marker. Only assemble the bundle if every
# part is good — otherwise we'd silently produce a bundle missing the real cert.
fetch_pem() {
  local url="$1" out="$2" label="$3"
  if ! curl -k -f -sS -o "$out" "$url"; then
    echo "Certificate download failed ($label). Check tenant URL and orgkey." >&2
    return 1
  fi
  if ! grep -q "BEGIN CERTIFICATE" "$out"; then
    echo "Response for $label did not contain a certificate." >&2
    return 1
  fi
}

create_cert_bundle() {
  echo "Creating cert bundle"
  local tmp_root tmp_sub tmp_pub
  tmp_root=$(mktemp); tmp_sub=$(mktemp); tmp_pub=$(mktemp)
  trap 'rm -f "$tmp_root" "$tmp_sub" "$tmp_pub"' RETURN

  fetch_pem "https://addon-$tenantName/config/org/cert?orgkey=$orgKey" "$tmp_root" "RootCA" || exit 1
  fetch_pem "https://addon-$tenantName/config/ca/cert?orgkey=$orgKey"  "$tmp_sub"  "SubCA"  || exit 1
  if [ $full_bundle -eq 1 ]; then
    if ! curl -k -f -sS -L -o "$tmp_pub" "https://curl.se/ca/cacert.pem"; then
      echo "Public CA bundle download failed." >&2
      exit 1
    fi
  fi

  cat "$tmp_root" > "$certDir/$certName"
  cat "$tmp_sub" >> "$certDir/$certName"
  if [ $full_bundle -eq 1 ]; then
    cat "$tmp_pub" >> "$certDir/$certName"
    # Netskope-only sidecar for tools/endpoints that bypass the proxy and need the minimal set.
    cat "$tmp_root" "$tmp_sub" > "$certDir/netskope_only.pem"
  fi
}

# Prompt for an existing bundle if not supplied via --cert-bundle. Skipped
# entirely for a silent/unattended run (tenant + orgkey already supplied).
if [ -z "$cert_bundle" ] && [ $silent_download -eq 0 ]; then
  read -p "Use an existing certificate bundle instead of downloading? (y/N) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Path to existing .pem bundle: " cert_bundle
  fi
fi

if [ -n "$cert_bundle" ]; then
  # Existing bundle: validate and use in place, no download
  cert_bundle="${cert_bundle/#\~/$HOME}"
  if [ ! -f "$cert_bundle" ]; then
    echo "Certificate bundle not found: $cert_bundle" >&2
    exit 1
  fi
  if ! grep -q "BEGIN CERTIFICATE" "$cert_bundle"; then
    echo "$cert_bundle does not contain a PEM certificate." >&2
    exit 1
  fi
  certDir=$(cd "$(dirname "$cert_bundle")" && pwd)
  certName=$(basename "$cert_bundle")
  echo "Using existing certificate bundle: $certDir/$certName"
else
  # Download from Netskope
  if [ -z "$certName" ] && [ $silent_download -eq 0 ]; then
    read -p "Please provide certificate bundle name [netskope-cert-bundle.pem]: " certName
  fi
  certName=${certName:-netskope-cert-bundle.pem}
  if [ -z "$certDir" ] && [ $silent_download -eq 0 ]; then
    read -p "Please provide certificate bundle location [~/netskope]: " certDir
  fi
  certDir=${certDir:-~/netskope}
  certDir="${certDir/#\~/$HOME}"
  if [ ! -d "$certDir" ]; then
    echo "$certDir does not exist."
    echo "creating $certDir"
    mkdir -p $certDir
  fi

  if [ -z "$tenantName" ]; then
    read -p "Please provide full tenant name (ex: mytenant.eu.goskope.com): " tenantName
  fi
  if [ -z "$orgKey" ]; then
    read -p "Please provide tenant orgkey: " orgKey
  fi

  # Strip https://, http://, and any path suffix so the cert URL splices cleanly.
  tenantName="${tenantName#https://}"
  tenantName="${tenantName#http://}"
  tenantName="${tenantName%%/*}"
  tenantName="${tenantName%%\?*}"
  tenantName="${tenantName%%#*}"

  status_code=$(curl -k --write-out %{http_code} --silent --output /dev/null https://$tenantName/locallogin)

  if [[ "$status_code" -ne "307" ]] ; then
    echo "Tenant Unreachable"
    exit 1
  else
    echo "Tenant Reachable"
  fi

  if [ -f "$certDir/$certName" ]; then
    echo "$certName already exists in $certDir."
    if [ $recreate_cert -eq 1 ]; then
      create_cert_bundle
    elif [ $silent_download -eq 1 ]; then
      # Silent/unattended run (tenant + orgkey supplied via CLI) — don't block on a
      # prompt. Pass --recreate to force regenerating an existing bundle.
      echo "Keeping existing bundle (pass --recreate to force regeneration)."
    else
      read -p "Recreate Certificate Bundle? (y/N) " -n 1 -r
      echo
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        create_cert_bundle
      fi
    fi
  else
    create_cert_bundle
  fi
fi

# Function to configure a tool with the certificate bundle
configure_tool() {
  local tool_name=$1
  local env_var=$2
  local check_command=$3
  local post_command=$4
  local version_command=${5:-"$check_command --version"}

  echo
  if command_exists $check_command; then
    echo "$tool_name is installed"
    $version_command
    if [[ -n "$env_var" ]]; then
      if [[ ${!env_var} == "$certDir/$certName" ]]; then
        echo "$tool_name already configured"
      else
        echo "export $env_var=\"$certDir/$certName\"" >> $shell
        echo "$tool_name configured"
        source $shell
        echo "export $env_var=\"$certDir/$certName\"" >> configured_tools.sh
      fi
    fi
    if [[ -n "$post_command" ]]; then
      eval $post_command
      echo "$post_command" >> configured_tools.sh
    fi
  else
    echo "$tool_name is not installed"
  fi
}

# This allows for later silent runs on other machines
> configured_tools.sh

# Configure tools
configure_tool "Git" "GIT_SSL_CAINFO" "git" ""
# LibreSSL/Apple's system openssl doesn't understand --version, only "version".
configure_tool "OpenSSL" "SSL_CERT_FILE" "openssl" "" "openssl version"
configure_tool "cURL" "SSL_CERT_FILE" "curl" ""
configure_tool "Python Requests Library" "REQUESTS_CA_BUNDLE" "" ""
configure_tool "AWS CLI" "AWS_CA_BUNDLE" "aws" ""
configure_tool "Google Cloud CLI" "" "gcloud" "gcloud config set core/custom_ca_certs_file $certDir/$certName"
configure_tool "NodeJS Package Manager (NPM)" "" "npm" "npm config set cafile $certDir/$certName"
configure_tool "NodeJS" "NODE_EXTRA_CA_CERTS" "node" ""
configure_tool "Ruby" "SSL_CERT_FILE" "ruby" ""
configure_tool "PHP Composer" "" "composer" "composer config --global cafile $certDir/$certName"
configure_tool "GoLang" "SSL_CERT_FILE" "go" ""
configure_tool "Azure CLI" "REQUESTS_CA_BUNDLE" "az" ""
configure_tool "Python PIP" "REQUESTS_CA_BUNDLE" "pip3" ""
configure_tool "Oracle Cloud CLI" "REQUESTS_CA_BUNDLE" "oci" ""
configure_tool "Cargo Package Manager" "SSL_CERT_FILE" "cargo" ""
# Homebrew installs the Yarn binary as "yarn" (unlike Debian, which ships it as "yarnpkg").
configure_tool "Yarn" "" "yarn" "yarn config set httpsCaFilePath $certDir/$certName"

# Check if Azure Storage Explorer exists
echo
if [ -d ~/Library/Application\ Support/StorageExplorer/certs ]; then
  echo "Azure Storage Explorer is installed"
  cp "$certDir/$certName" ~/Library/Application\ Support/StorageExplorer/certs
  echo "Azure Storage Explorer configured"
  echo "cp \"$certDir/$certName\" ~/Library/Application\ Support/StorageExplorer/certs" >> configured_tools.sh
else
  echo "Azure Storage Explorer is not installed"
fi

# Adding a new tool
# To add a new tool, use the `configure_tool` function with the appropriate parameters.
# Example:
# configure_tool "Tool Name" "ENV_VAR_NAME" "check_command" "post_command"
# - tool_name: The name of the tool (for display purposes)
# - env_var: The environment variable to set (if applicable)
# - check_command: The command to check if the tool is installed (usually the tool's executable name)
# - post_command: Any additional configuration command needed after setting the environment variable (can be empty if not needed)
#
# Example for adding a hypothetical tool "MyTool":
# configure_tool "MyTool" "MYTOOL_CA_CERTS" "mytool" "mytool config set cafile $certDir/$certName"
