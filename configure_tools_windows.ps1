#Requires -Version 5.1
<#
.SYNOPSIS
    Configures or rolls back the Netskope SSL certificate bundle for developer tools.
.DESCRIPTION
    Set $rollback = $true (or any other pre-set parameter) at the top of the script
    for unattended deployment. When parameters are empty the script falls back to
    interactive prompts.

    Normal mode  : downloads the cert bundle and configures every detected tool.
    Rollback mode: removes all Netskope SSL configuration from every detected tool
                   without touching or needing the cert bundle file.
#>

# ─── Optional pre-set parameters (set to skip interactive prompts) ────────────
$tenantName   = ""
$orgKey       = ""
$certName     = "netskope-cert-bundle.pem"
$certDir      = ""      # leave empty to default to $env:USERPROFILE\netskope
$certBundle   = ""      # set to an existing .pem path to skip the download entirely
$recreateCert = $false
$rollback     = $false  # set $true to undo all Netskope SSL configuration
$netskopeOnly = $false  # set $true to use only the two Netskope certs, skipping the public curl.se CA bundle

$fullBundle = -not $netskopeOnly

# ─── TLS bypass for initial download (cert not trusted yet) ──────────────────

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $skipTls = @{}
} else {
    $skipTls = @{ SkipCertificateCheck = $true }
}

# ─── Utility helpers ─────────────────────────────────────────────────────────

function Read-Default($prompt, $default) {
    $v = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { $default } else { $v }
}

function Test-Cmd($name) {
    $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Set-PersistentEnvVar($name, $value) {
    [Environment]::SetEnvironmentVariable($name, $value, [EnvironmentVariableTarget]::User)
    Set-Item -Path "Env:\$name" -Value $value -ErrorAction SilentlyContinue
}

function Remove-PersistentEnvVar($name) {
    [Environment]::SetEnvironmentVariable($name, $null, [EnvironmentVariableTarget]::User)
    Remove-Item -Path "Env:\$name" -ErrorAction SilentlyContinue
}

$configuredToolsFile = Join-Path $PSScriptRoot 'configured_tools.ps1'
$createReplay = $false

function Add-Replay($line) {
    if ($createReplay) { Add-Content -Path $configuredToolsFile -Value $line }
}

# ─── Color + log helpers ──────────────────────────────────────────────────────
function Write-Ok($msg)     { Write-Host $msg -ForegroundColor Green }
function Write-Warn($msg)   { Write-Host $msg -ForegroundColor Yellow }
function Write-Err($msg)    { Write-Host $msg -ForegroundColor Red }
function Write-Header($msg) { Write-Host ""; Write-Host $msg -ForegroundColor Cyan }
function Write-Dim($msg)    { Write-Host $msg -ForegroundColor DarkGray }
function Write-Log($msg)    { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg) }

# ─── Python discovery ─────────────────────────────────────────────────────────

function Get-AllPythons {
    $found = [ordered]@{}

    if (Test-Cmd 'py') {
        py --list-paths 2>$null | ForEach-Object {
            if ($_ -match '(-V:\S+)\s+\*?\s+(.*python\.exe)') {
                $path = $Matches[2].Trim()
                if (Test-Path $path) { $found[$path.ToLower()] = @($path, $Matches[1]) }
            }
        }
    }

    where.exe python 2>$null | ForEach-Object {
        $p = $_.Trim()
        if ($p -and (Test-Path $p) -and -not $found.Contains($p.ToLower())) {
            $found[$p.ToLower()] = @($p, 'python')
        }
    }

    @(
        @{ Cmd = 'az'; Args = '--version'; Pattern = "Python location '(.+python\.exe)'"; Label = 'Azure CLI' }
    ) | ForEach-Object {
        $src = $_
        if (Test-Cmd $src.Cmd) {
            $out = & $src.Cmd $src.Args 2>$null | Out-String
            if ($out -match $src.Pattern) {
                $path = $Matches[1]
                if ((Test-Path $path) -and -not $found.Contains($path.ToLower())) {
                    $found[$path.ToLower()] = @($path, $src.Label)
                }
            }
        }
    }

    return $found.Values
}

# ─── JDK discovery ───────────────────────────────────────────────────────────

function Get-AllJDKs {
    $found = [ordered]@{}

    function Add-JDK($jdkPath, $label) {
        if (-not $jdkPath -or -not (Test-Path $jdkPath -PathType Container)) { return }
        $keytool = Join-Path $jdkPath 'bin\keytool.exe'
        if ((Test-Path $keytool) -and -not $found.Contains($jdkPath.ToLower())) {
            $found[$jdkPath.ToLower()] = @($jdkPath, $label)
        }
    }

    if ($env:JAVA_HOME) { Add-JDK $env:JAVA_HOME 'JAVA_HOME' }

    $kt = Get-Command keytool -ErrorAction SilentlyContinue
    if ($kt) { Add-JDK (Split-Path (Split-Path $kt.Source)) 'PATH' }

    @('HKLM:\SOFTWARE\JavaSoft\JDK', 'HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK') | ForEach-Object {
        if (Test-Path $_) {
            Get-ChildItem $_ -ErrorAction SilentlyContinue | ForEach-Object {
                $jh = (Get-ItemProperty $_.PSPath -Name JavaHome -ErrorAction SilentlyContinue).JavaHome
                if ($jh) { Add-JDK $jh "Registry ($($_.PSChildName))" }
            }
        }
    }

    @('Java', 'Eclipse Adoptium', 'Amazon Corretto', 'Zulu', 'Microsoft') | ForEach-Object {
        $parent = Join-Path $env:ProgramFiles $_
        if (Test-Path $parent) {
            Get-ChildItem $parent -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Add-JDK $_.FullName "Common ($($_.Name))" }
        }
    }

    return $found.Values
}

# ─── SSL configuration functions ─────────────────────────────────────────────

function Set-PythonSslCert($pythonExe, $label, $certWasRecreated = $false) {
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "[$label]" -ForegroundColor Cyan -NoNewline
    Write-Host " $pythonExe"

    $certifiBundle = & $pythonExe -c 'import certifi; print(certifi.where())' 2>$null
    if ($LASTEXITCODE -eq 0 -and $certifiBundle) {
        $certifiBundle  = $certifiBundle.Trim()
        $existing       = [IO.File]::ReadAllBytes($certifiBundle)
        $markerBytes    = [Text.Encoding]::UTF8.GetBytes("`n# Netskope SSL bundle")
        $markerIdx      = -1
        for ($mi = 0; $mi -le $existing.Length - $markerBytes.Length; $mi++) {
            $match = $true
            for ($mj = 0; $mj -lt $markerBytes.Length; $mj++) {
                if ($existing[$mi + $mj] -ne $markerBytes[$mj]) { $match = $false; break }
            }
            if ($match) { $markerIdx = $mi; break }
        }
        $hadMarker = $markerIdx -ge 0
        if ($hadMarker -and -not $certWasRecreated) {
            Write-Warn "    certifi: already configured ($certifiBundle)"
        } else {
            if ($hadMarker) { $existing = $existing[0..($markerIdx - 1)] }
            try {
                [IO.File]::WriteAllBytes($certifiBundle, $existing)
                $stream = [IO.File]::Open($certifiBundle, [IO.FileMode]::Append)
                $marker = [Text.Encoding]::UTF8.GetBytes("`n# Netskope SSL bundle`n")
                $cert   = [IO.File]::ReadAllBytes($certPath)
                $stream.Write($marker, 0, $marker.Length)
                $stream.Write($cert, 0, $cert.Length)
                $stream.Close()
                $action = if ($hadMarker) { 'updated' } else { 'configured' }
                Write-Ok "    certifi: $action ($certifiBundle)"
                Add-Replay "# certifi patch for $pythonExe"
                Add-Replay "Add-Content -Path `"$certifiBundle`" -Value (Get-Content -Path `"$certPath`" -Raw)"
            } catch [System.UnauthorizedAccessException] {
                Write-Err "    certifi: access denied — rerun as Administrator"
            } catch {
                Write-Err "    certifi: failed — $_"
            }
        }
    } else {
        Write-Dim "    certifi: not installed"
    }

    & $pythonExe -m pip --version *>$null
    if ($LASTEXITCODE -eq 0) {
        & $pythonExe -m pip config set global.cert $certPath *>$null
        Write-Ok "    pip: configured"
        Add-Replay "`"$pythonExe`" -m pip config set global.cert `"$certPath`""
    } else {
        Write-Dim "    pip: not installed"
    }

    $reqVer = & $pythonExe -c 'import requests; print(requests.__version__)' 2>$null
    if ($LASTEXITCODE -eq 0 -and $reqVer) {
        Write-Dim "    requests $($reqVer.Trim()): present (covered by REQUESTS_CA_BUNDLE)"
    }
}

function Set-ToolSslCert($toolName, $envVar, $checkCmd, $postCmd = $null) {
    Write-Host ""
    if (Test-Cmd $checkCmd) {
        Write-Host "$toolName is installed"
        # Not all OpenSSL builds understand --version (older builds only accept "version").
        if ($checkCmd -eq 'openssl') { & openssl version } else { & $checkCmd --version }
        if ($envVar) {
            $current = [Environment]::GetEnvironmentVariable($envVar, [EnvironmentVariableTarget]::User)
            if ($current -eq $certPath) {
                Write-Warn "$toolName already configured"
            } else {
                Set-PersistentEnvVar $envVar $certPath
                Write-Ok "$toolName configured"
                Add-Replay "[Environment]::SetEnvironmentVariable('$envVar', `"$certPath`", 'User')"
            }
        }
        if ($postCmd) { Invoke-Expression $postCmd; Add-Replay $postCmd }
    } else {
        Write-Dim "$toolName is not installed"
    }
}

function Set-JavaSslCert($jdkHome, $label, $certWasRecreated = $false) {
    Write-Host ""
    Write-Host "  " -NoNewline
    Write-Host "[$label]" -ForegroundColor Cyan -NoNewline
    Write-Host " $jdkHome"

    $cacerts = Join-Path $jdkHome 'lib\security\cacerts'
    if (-not (Test-Path $cacerts)) { $cacerts = Join-Path $jdkHome 'jre\lib\security\cacerts' }
    if (-not (Test-Path $cacerts)) { Write-Err "    cacerts: not found"; return }

    $keytool   = Join-Path $jdkHome 'bin\keytool.exe'
    $storepass = 'changeit'
    $certText  = Get-Content $certPath -Raw
    $pemBlocks = [regex]::Matches($certText, '-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----') |
                 Select-Object -First 2

    if ($pemBlocks.Count -eq 0) { Write-Err "    keytool: no PEM blocks found in bundle"; return }

    for ($i = 0; $i -lt $pemBlocks.Count; $i++) {
        $alias = "netskope-$i"
        & $keytool -list -alias $alias -keystore $cacerts -storepass $storepass *>$null
        if ($LASTEXITCODE -eq 0) {
            if (-not $certWasRecreated) { Write-Warn "    keytool alias ${alias}: already configured"; continue }
            Write-Warn "    keytool alias ${alias}: removing stale entry to re-import"
            & $keytool -delete -alias $alias -keystore $cacerts -storepass $storepass *>$null
        }
        $tmp = [IO.Path]::GetTempFileName() + '.pem'
        try {
            [IO.File]::WriteAllText($tmp, $pemBlocks[$i].Value)
            & $keytool -import -trustcacerts -noprompt -alias $alias -file $tmp `
                       -keystore $cacerts -storepass $storepass *>$null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "    keytool alias ${alias}: configured"
                Add-Replay "`"$keytool`" -import -trustcacerts -noprompt -alias $alias -file `"$certPath`" -keystore `"$cacerts`" -storepass $storepass"
            } else {
                Write-Err "    keytool alias ${alias}: failed"
            }
        } catch [System.UnauthorizedAccessException] {
            Write-Err "    keytool: access denied — rerun as Administrator"
        } catch {
            Write-Err "    keytool: error — $_"
        } finally {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
        }
    }
}

# ─── Cert bundle creation ─────────────────────────────────────────────────────

function New-CertBundle {
    Write-Host 'Creating cert bundle...'
    $urls = [System.Collections.Generic.List[string]]@(
        "https://addon-$tenantName/config/org/cert?orgkey=$orgKey"   # RootCA first
        "https://addon-$tenantName/config/ca/cert?orgkey=$orgKey"    # SubCA second
    )
    if ($fullBundle) { $urls.Add('https://curl.se/ca/cacert.pem') }

    # Fetch everything into memory first. If any URL returns non-2xx or any
    # response lacks the PEM marker, abort before writing the bundle file.
    $cachedBytes = @()
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -UseBasicParsing @skipTls
        } catch {
            Write-Err "Certificate download failed: $($_.Exception.Message) for $url"
            Write-Err 'Check tenant URL and orgkey, then re-run.'
            exit 1
        }
        if ($resp.StatusCode -lt 200 -or $resp.StatusCode -ge 300) {
            Write-Err "Certificate download failed: HTTP $($resp.StatusCode) from $url"
            Write-Err 'Check tenant URL and orgkey, then re-run.'
            exit 1
        }
        $bytes = $resp.Content
        $text  = [System.Text.Encoding]::ASCII.GetString($bytes)
        if ($text -notmatch '-----BEGIN CERTIFICATE-----') {
            Write-Err "Response from $url does not contain a certificate."
            exit 1
        }
        $cachedBytes += , $bytes
    }

    if (Test-Path $certPath) { Remove-Item -Path $certPath -Force -ErrorAction SilentlyContinue }
    $stream = [IO.File]::Open($certPath, [IO.FileMode]::Create)
    try {
        foreach ($bytes in $cachedBytes) {
            $stream.Write($bytes, 0, $bytes.Length)
        }
    } finally {
        $stream.Close()
    }
    Write-Ok "Cert bundle saved: $certPath"

    if ($fullBundle) {
        # Netskope-only sidecar: RootCA (index 0) + SubCA (index 1), no public CA bundle
        $netskopeOnlyPath = Join-Path $certDir 'netskope_only.pem'
        $ns = [IO.File]::Open($netskopeOnlyPath, [IO.FileMode]::Create)
        try {
            $ns.Write($cachedBytes[0], 0, $cachedBytes[0].Length)
            $ns.Write($cachedBytes[1], 0, $cachedBytes[1].Length)
        } finally {
            $ns.Close()
        }
        Write-Ok "Netskope-only cert saved: $netskopeOnlyPath"
    }
}

# ─── Rollback ─────────────────────────────────────────────────────────────────

function Invoke-Rollback {
    # Git
    Write-Header "Git"
    if (Test-Cmd 'git') {
        $cur = git config --global http.sslCAInfo 2>$null
        if ($cur) {
            git config --global --unset http.sslCAInfo
            Write-Ok "  http.sslCAInfo removed"
        } else { Write-Dim "  not configured" }
    } else { Write-Dim "  not installed" }

    # Environment variables
    Write-Header "Environment variables"
    # Also clears legacy GIT_SSL_CAPATH that older runs wrongly set to a file path.
    foreach ($var in @('SSL_CERT_FILE', 'AWS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS',
                        'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO', 'GIT_SSL_CAPATH')) {
        $cur = [Environment]::GetEnvironmentVariable($var, 'User')
        if ($cur) {
            Remove-PersistentEnvVar $var
            Write-Ok "  $var cleared"
        } else { Write-Dim "  $var not set" }
    }

    # cURL
    Write-Header "cURL"
    $curlrc = Join-Path $env:USERPROFILE '.curlrc'
    if (Test-Path $curlrc) {
        Remove-Item $curlrc -Force
        Write-Ok "  .curlrc removed"
    } else { Write-Dim "  .curlrc not found" }

    # Google Cloud CLI
    Write-Header "Google Cloud CLI"
    if (Test-Cmd 'gcloud') {
        gcloud config unset core/custom_ca_certs_file 2>$null
        Write-Ok "  custom_ca_certs_file unset"
    } else { Write-Dim "  not installed" }

    # NPM
    Write-Header "NPM"
    if (Test-Cmd 'npm') {
        npm config delete cafile 2>$null
        Write-Ok "  cafile removed"
    } else { Write-Dim "  not installed" }

    # PHP Composer
    Write-Header "PHP Composer"
    if (Test-Cmd 'composer') {
        composer config --global --unset cafile 2>$null
        Write-Ok "  cafile removed"
    } else { Write-Dim "  not installed" }

    # Yarn
    Write-Header "Yarn"
    if (Test-Cmd 'yarn') {
        yarn config delete cafile 2>$null
        Write-Ok "  cafile removed"
    } else { Write-Dim "  not installed" }

    # pnpm
    Write-Header "pnpm"
    if (Test-Cmd 'pnpm') {
        pnpm config delete cafile 2>$null
        Write-Ok "  cafile removed"
    } else { Write-Dim "  not installed" }

    # Python
    Write-Header "Python installations"
    $allPythons = @(Get-AllPythons)
    if ($allPythons.Count -gt 0) {
        foreach ($entry in $allPythons) {
            $pyExe = $entry[0]; $pyLabel = $entry[1]
            Write-Host ""
            Write-Host "  " -NoNewline
            Write-Host "[$pyLabel]" -ForegroundColor Cyan -NoNewline
            Write-Host " $pyExe"

            # certifi — strip Netskope marker block
            $cb = & $pyExe -c 'import certifi; print(certifi.where())' 2>$null
            if ($LASTEXITCODE -eq 0 -and $cb) {
                $cb          = $cb.Trim()
                $existing    = [IO.File]::ReadAllBytes($cb)
                $markerBytes = [Text.Encoding]::UTF8.GetBytes("`n# Netskope SSL bundle")
                $markerIdx   = -1
                for ($mi = 0; $mi -le $existing.Length - $markerBytes.Length; $mi++) {
                    $match = $true
                    for ($mj = 0; $mj -lt $markerBytes.Length; $mj++) {
                        if ($existing[$mi + $mj] -ne $markerBytes[$mj]) { $match = $false; break }
                    }
                    if ($match) { $markerIdx = $mi; break }
                }
                if ($markerIdx -ge 0) {
                    try {
                        [IO.File]::WriteAllBytes($cb, $existing[0..($markerIdx - 1)])
                        Write-Ok "    certifi: Netskope bundle stripped"
                    } catch [System.UnauthorizedAccessException] {
                        Write-Err "    certifi: access denied — rerun as Administrator"
                    } catch {
                        Write-Err "    certifi: failed — $_"
                    }
                } else { Write-Dim "    certifi: not patched" }
            } else { Write-Dim "    certifi: not installed" }

            # pip
            & $pyExe -m pip --version *>$null
            if ($LASTEXITCODE -eq 0) {
                & $pyExe -m pip config unset global.cert *>$null
                Write-Ok "    pip: global.cert removed"
            } else { Write-Dim "    pip: not installed" }
        }
    } else { Write-Dim "  No Python installations found" }

    # Java JDK
    Write-Header "Java installations"
    $allJDKs = @(Get-AllJDKs)
    if ($allJDKs.Count -gt 0) {
        foreach ($entry in $allJDKs) {
            $jdkHome = $entry[0]; $jdkLabel = $entry[1]
            Write-Host ""
            Write-Host "  " -NoNewline
            Write-Host "[$jdkLabel]" -ForegroundColor Cyan -NoNewline
            Write-Host " $jdkHome"
            $cacerts = Join-Path $jdkHome 'lib\security\cacerts'
            if (-not (Test-Path $cacerts)) { $cacerts = Join-Path $jdkHome 'jre\lib\security\cacerts' }
            if (-not (Test-Path $cacerts)) { Write-Err "    cacerts: not found"; continue }
            $keytool = Join-Path $jdkHome 'bin\keytool.exe'
            foreach ($alias in @('netskope-0', 'netskope-1')) {
                & $keytool -list -alias $alias -keystore $cacerts -storepass 'changeit' *>$null
                if ($LASTEXITCODE -eq 0) {
                    & $keytool -delete -alias $alias -keystore $cacerts -storepass 'changeit' *>$null
                    if ($LASTEXITCODE -eq 0) { Write-Ok "    keytool: alias $alias removed" }
                    else { Write-Err "    keytool: failed to remove $alias" }
                } else { Write-Dim "    keytool: alias $alias not present" }
            }
        }
    } else { Write-Dim "  No Java installations found" }

    # VS Code
    Write-Header "VS Code"
    $vsCodeFound = $false
    @(
        @{ Dir = "$env:APPDATA\Code\User";            Edition = 'VS Code' }
        @{ Dir = "$env:APPDATA\Code - Insiders\User"; Edition = 'VS Code Insiders' }
    ) | ForEach-Object {
        $settingsFile = Join-Path $_.Dir 'settings.json'
        if (-not (Test-Path $_.Dir)) { return }
        $vsCodeFound = $true
        try {
            if (Test-Path $settingsFile) {
                $s = Get-Content $settingsFile -Raw | ConvertFrom-Json
                if ($s.PSObject.Properties['http.systemCertificates']) {
                    $s.PSObject.Properties.Remove('http.systemCertificates')
                    $s | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
                    Write-Ok "  $($_.Edition): http.systemCertificates removed"
                } else { Write-Dim "  $($_.Edition): not configured" }
            } else { Write-Dim "  $($_.Edition): no settings.json" }
        } catch { Write-Err "  $($_.Edition): failed — $_" }
    }
    if (-not $vsCodeFound) { Write-Dim "  VS Code is not installed" }

    # Windows Certificate Store
    Write-Header "Windows Certificate Store"
    $netscopeCerts = @(
        Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -match 'Netskope' -or $_.Issuer -match 'Netskope' }
    )
    if ($netscopeCerts.Count -gt 0) {
        foreach ($cert in $netscopeCerts) {
            try {
                $location = if ($cert.PSPath -match 'LocalMachine') { 'LocalMachine' } else { 'CurrentUser' }
                $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('Root', $location)
                $store.Open('ReadWrite')
                $store.Remove($cert)
                $store.Close()
                Write-Ok "  removed: $($cert.Subject) [$($cert.Thumbprint)]"
            } catch {
                Write-Err "  failed to remove $($cert.Subject): $_"
            }
        }
    } else { Write-Dim "  no Netskope certificates found in store" }

    # Docker Desktop
    Write-Header "Docker Desktop"
    $dockerCa = Join-Path $env:USERPROFILE '.docker\ca.pem'
    if (Test-Path $dockerCa) {
        try {
            Remove-Item $dockerCa -Force
            Write-Ok "  ~/.docker/ca.pem removed"
            Write-Host "  Note: restart Docker Desktop to apply changes"
        } catch { Write-Err "  failed to remove ca.pem: $_" }
    } else { Write-Dim "  ~/.docker/ca.pem not found" }

    Write-Host ""
    Write-Ok "Rollback complete."
}

# ══════════════════════════════════════════════════════════════════════════════
# MAIN
# ══════════════════════════════════════════════════════════════════════════════

$_startTime = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'

if ($rollback) {
    Write-Host '################################################################'
    Write-Host " Netskope SSL rollback ($_startTime)"
    Write-Host '################################################################'
    Write-Host ''
    Invoke-Rollback
    exit 0
}

Write-Host '################################################################'
Write-Host " Starting Netskope SSL configuration ($_startTime)"
Write-Host '################################################################'
Write-Host ''

# ─── User inputs ──────────────────────────────────────────────────────────────

# Prompt for an existing bundle if not pre-set and running interactively.
if ([string]::IsNullOrWhiteSpace($certBundle)) {
    $useExisting = (Read-Host 'Use an existing certificate bundle instead of downloading? [y/N]') -ieq 'y'
    if ($useExisting) { $certBundle = Read-Host 'Path to existing .pem bundle' }
}

if (-not [string]::IsNullOrWhiteSpace($certBundle)) {
    # ─── Existing bundle: validate and use in place, no download ──────────────
    $certPath = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($certBundle))
    if (-not (Test-Path $certPath -PathType Leaf)) {
        Write-Err "Certificate bundle not found: $certPath"
        exit 1
    }
    if ((Get-Content $certPath -Raw) -notmatch '-----BEGIN CERTIFICATE-----') {
        Write-Err "$certPath does not contain a PEM certificate."
        exit 1
    }
    $certDir  = Split-Path -Parent $certPath
    $certName = Split-Path -Leaf   $certPath
    $certWasRecreated = $true   # treat as freshly provided so stores are (re)configured
    Write-Ok "Using existing certificate bundle: $certPath"
} else {
    # ─── Download from Netskope ───────────────────────────────────────────────
    if ([string]::IsNullOrWhiteSpace($certName)) {
        $certName = Read-Default 'Certificate bundle name' 'netskope-cert-bundle.pem'
    } else { Write-Log "certName: $certName" }

    if ([string]::IsNullOrWhiteSpace($certDir)) {
        $certDir = Read-Default 'Certificate bundle location' (Join-Path $env:USERPROFILE 'netskope')
    } else { Write-Log "certDir: $certDir" }

    $certDir  = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($certDir))
    $certPath = Join-Path $certDir $certName

    if ([string]::IsNullOrWhiteSpace($tenantName)) {
        $tenantName = Read-Host 'Full tenant name (e.g. mytenant.eu.goskope.com)'
    } else { Write-Log "tenantName: $tenantName" }

    # Strip https://, http://, trailing path — anything else would produce a
    # malformed `https://addon-{tenantName}/...` URL when we splice it in.
    $tenantName = $tenantName.Trim() -replace '^https?://', ''
    $tenantName = ($tenantName -split '[/?#]')[0].TrimEnd('.')

    if ([string]::IsNullOrWhiteSpace($orgKey)) {
        $orgKey = Read-Host 'Tenant orgkey'
    } else { Write-Log 'orgKey: [configured]' }

    if (-not (Test-Path $certDir)) {
        Write-Warn "$certDir does not exist — creating it"
        New-Item -ItemType Directory -Path $certDir -Force | Out-Null
    }

    # Not maintained in --netskope-only mode — remove a stale sidecar left
    # over from an earlier full-bundle run even if we end up keeping the
    # existing main bundle below, so it's never mistaken for a fresh one.
    if (-not $fullBundle) {
        $staleNetskopeOnly = Join-Path $certDir 'netskope_only.pem'
        if (Test-Path $staleNetskopeOnly) { Remove-Item $staleNetskopeOnly -Force }
    }

    # Tenant reachability
    try {
        Invoke-WebRequest -Uri "https://$tenantName/locallogin" -UseBasicParsing @skipTls `
                          -ErrorAction Stop | Out-Null
        Write-Ok 'Tenant Reachable'
    } catch {
        Write-Err "Tenant Unreachable: $_"
        exit 1
    }

    $certWasRecreated = $false
    if (Test-Path $certPath) {
        Write-Warn "$certName already exists in $certDir."
        if ($recreateCert) {
            New-CertBundle; $certWasRecreated = $true
        } else {
            $rec = Read-Host 'Recreate Certificate Bundle? (y/N)'
            if ($rec -ieq 'y') { New-CertBundle; $certWasRecreated = $true }
        }
    } else {
        New-CertBundle; $certWasRecreated = $true
    }
}

$createReplay = (Read-Host 'Create replay script (configured_tools.ps1)? [y/N]') -ieq 'y'
if ($createReplay) {
    Set-Content -Path $configuredToolsFile -Value '# Netskope SSL configuration - replay script'
    Write-Ok "Replay script: $configuredToolsFile"
}

# ─── Windows Certificate Store ────────────────────────────────────────────────

Write-Header "Windows Certificate Store"
$certContent = Get-Content $certPath -Raw -ErrorAction SilentlyContinue
if ($certContent -match '-----BEGIN CERTIFICATE-----\s*([\s\S]*?)\s*-----END CERTIFICATE-----') {
    $b64 = $Matches[1] -replace '\s', ''
    try {
        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(
            ,[Convert]::FromBase64String($b64))
        $thumb   = $x509.Thumbprint
        $inStore = @(
            Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $thumb }
        ).Count -gt 0
        if ($inStore) {
            Write-Warn "  already configured (certificate found in store)"
        } else {
            Write-Host "  importing certificate into Windows store..."
            certutil -addstore -f Root $certPath 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                Write-Ok "  configured (imported into LocalMachine\Root)"
                Add-Replay "certutil -addstore -f Root `"$certPath`""
            } else {
                certutil -addstore -f -user Root $certPath 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    Write-Ok "  configured (imported into CurrentUser\Root)"
                    Add-Replay "certutil -addstore -f -user Root `"$certPath`""
                } else {
                    Write-Err "  access denied — rerun as Administrator to import into machine store"
                }
            }
        }
    } catch { Write-Err "  could not check certificate store: $_" }
} else { Write-Err "  no PEM certificate found in bundle" }

# ─── Python ───────────────────────────────────────────────────────────────────

Write-Header "Python installations"
$allPythons = @(Get-AllPythons)
if ($allPythons.Count -gt 0) {
    foreach ($entry in $allPythons) { Set-PythonSslCert $entry[0] $entry[1] $certWasRecreated }
    Write-Host ""
    Set-PersistentEnvVar 'REQUESTS_CA_BUNDLE' $certPath
    Write-Ok "REQUESTS_CA_BUNDLE set globally"
    Add-Replay "[Environment]::SetEnvironmentVariable('REQUESTS_CA_BUNDLE', `"$certPath`", 'User')"
} else { Write-Dim "  No Python installations found" }

# ─── Tools ────────────────────────────────────────────────────────────────────

Write-Host ""
if (Test-Cmd 'git') {
    Write-Host "Git is installed"; git --version
    $cur = git config --global http.sslCAInfo
    if ($cur -eq $certPath) { Write-Warn "Git already configured" }
    else {
        git config --global http.sslCAInfo $certPath
        Write-Ok "Git configured"
        Add-Replay "git config --global http.sslCAInfo `"$certPath`""
    }
} else { Write-Dim "Git is not installed" }

Set-ToolSslCert 'OpenSSL' 'SSL_CERT_FILE' 'openssl'

Write-Host ""
if (Test-Cmd 'curl') {
    Write-Host "cURL is installed"; curl --version
    $curlrc = Join-Path $env:USERPROFILE '.curlrc'
    "--cacert `"$certPath`"" | Set-Content -Path $curlrc -Encoding ASCII
    Write-Ok "cURL configured ($curlrc)"
    Add-Replay "Set-Content -Path `"$curlrc`" -Value `"--cacert \`"$certPath\`"`" -Encoding ASCII"
} else { Write-Dim "cURL is not installed" }

Set-ToolSslCert 'AWS CLI'   'AWS_CA_BUNDLE'      'aws'
Set-ToolSslCert 'NodeJS'    'NODE_EXTRA_CA_CERTS' 'node'

Write-Host ""
if (Test-Cmd 'gcloud') {
    Write-Host "Google Cloud CLI is installed"; gcloud --version
    gcloud config set core/custom_ca_certs_file $certPath
    Write-Ok "Google Cloud CLI configured"
    Add-Replay "gcloud config set core/custom_ca_certs_file `"$certPath`""
} else { Write-Dim "Google Cloud CLI is not installed" }

Write-Host ""
if (Test-Cmd 'npm') {
    Write-Host "NodeJS Package Manager (NPM) is installed"; npm --version
    npm config set cafile $certPath
    Write-Ok "NodeJS Package Manager (NPM) configured"
    Add-Replay "npm config set cafile `"$certPath`""
} else { Write-Dim "NodeJS Package Manager (NPM) is not installed" }

Set-ToolSslCert 'Ruby' 'SSL_CERT_FILE' 'ruby'

Write-Host ""
if (Test-Cmd 'composer') {
    Write-Host "PHP Composer is installed"; composer --version
    composer config --global cafile $certPath
    Write-Ok "PHP Composer configured"
    Add-Replay "composer config --global cafile `"$certPath`""
} else { Write-Dim "PHP Composer is not installed" }

Set-ToolSslCert 'GoLang'           'SSL_CERT_FILE'      'go'
Set-ToolSslCert 'Azure CLI'        'REQUESTS_CA_BUNDLE'  'az'
Set-ToolSslCert 'Oracle Cloud CLI' 'REQUESTS_CA_BUNDLE'  'oci'

Write-Host ""
if (Test-Cmd 'cargo') {
    Write-Host "Cargo Package Manager is installed"; cargo --version
    Set-PersistentEnvVar 'SSL_CERT_FILE'  $certPath
    Set-PersistentEnvVar 'GIT_SSL_CAINFO' $certPath
    Write-Ok "Cargo Package Manager configured"
    Add-Replay "[Environment]::SetEnvironmentVariable('SSL_CERT_FILE',  `"$certPath`", 'User')"
    Add-Replay "[Environment]::SetEnvironmentVariable('GIT_SSL_CAINFO', `"$certPath`", 'User')"
} else { Write-Dim "Cargo Package Manager is not installed" }

Write-Host ""
if (Test-Cmd 'yarn') {
    Write-Host "Yarn is installed"; yarn --version
    yarn config set cafile $certPath
    Write-Ok "Yarn configured"
    Add-Replay "yarn config set cafile `"$certPath`""
} else { Write-Dim "Yarn is not installed" }

Write-Host ""
if (Test-Cmd 'pnpm') {
    Write-Host "pnpm is installed"; pnpm --version
    pnpm config set cafile $certPath
    Write-Ok "pnpm configured"
    Add-Replay "pnpm config set cafile `"$certPath`""
} else { Write-Dim "pnpm is not installed" }

Write-Host ""
$storageExplorerCerts = Join-Path $env:APPDATA 'StorageExplorer\certs'
if (Test-Path $storageExplorerCerts) {
    Write-Host "Azure Storage Explorer is installed"
    Copy-Item -Path $certPath -Destination $storageExplorerCerts -Force
    Write-Ok "Azure Storage Explorer configured"
    Add-Replay "Copy-Item -Path `"$certPath`" -Destination `"$storageExplorerCerts`" -Force"
} else { Write-Dim "Azure Storage Explorer is not installed" }

# ─── Java ─────────────────────────────────────────────────────────────────────

Write-Header "Java installations"
$allJDKs = @(Get-AllJDKs)
if ($allJDKs.Count -gt 0) {
    foreach ($entry in $allJDKs) { Set-JavaSslCert $entry[0] $entry[1] $certWasRecreated }
} else { Write-Dim "  No Java installations found" }

# ─── VS Code ──────────────────────────────────────────────────────────────────

Write-Header "VS Code"
$vsInstalled = $false
@(
    @{ Dir = "$env:APPDATA\Code\User";            Edition = 'VS Code' }
    @{ Dir = "$env:APPDATA\Code - Insiders\User"; Edition = 'VS Code Insiders' }
) | ForEach-Object {
    $settingsDir  = $_.Dir
    $edition      = $_.Edition
    $settingsFile = Join-Path $settingsDir 'settings.json'
    if (-not (Test-Path $settingsDir)) { return }
    $vsInstalled = $true
    try {
        $settings = if (Test-Path $settingsFile) {
            Get-Content $settingsFile -Raw | ConvertFrom-Json
        } else { New-Object PSObject }
        if ($settings.PSObject.Properties['http.systemCertificates'] -and
            $settings.'http.systemCertificates' -eq $true) {
            Write-Warn "  ${edition}: already configured"
        } else {
            $settings | Add-Member -NotePropertyName 'http.systemCertificates' -NotePropertyValue $true -Force
            $settings | ConvertTo-Json -Depth 10 | Set-Content $settingsFile -Encoding UTF8
            Write-Ok "  ${edition}: configured"
            Add-Replay "# VS Code: set http.systemCertificates in $settingsFile"
        }
    } catch { Write-Err "  ${edition}: failed — $_" }
}
if (-not $vsInstalled) { Write-Dim "  VS Code is not installed" }

# ─── .NET / NuGet ─────────────────────────────────────────────────────────────

Write-Header ".NET / NuGet"
$dotnetFound = $false
foreach ($dotnetCmd in @('dotnet', 'nuget')) {
    if (Test-Cmd $dotnetCmd) {
        $ver = (& $dotnetCmd --version 2>$null)
        Write-Ok "  $dotnetCmd $ver — covered by Windows Certificate Store"
        Add-Replay "# ${dotnetCmd}: covered by Windows Certificate Store"
        $dotnetFound = $true
    }
}
if (-not $dotnetFound) { Write-Dim "  .NET / NuGet is not installed" }

# ─── Docker Desktop ───────────────────────────────────────────────────────────

Write-Header "Docker Desktop"
$dockerInstalled = (Test-Cmd 'docker') -or (Test-Path "$env:LOCALAPPDATA\Docker\Desktop")
if (-not $dockerInstalled) {
    Write-Dim "  Docker is not installed"
} else {
    $dockerDir = Join-Path $env:USERPROFILE '.docker'
    $dockerCa  = Join-Path $dockerDir 'ca.pem'
    $alreadyOk = (Test-Path $dockerCa) -and
                 ((Get-FileHash $dockerCa).Hash -eq (Get-FileHash $certPath).Hash)
    if ($alreadyOk) {
        Write-Warn "  already configured"
    } else {
        if (-not (Test-Path $dockerDir)) { New-Item -ItemType Directory $dockerDir -Force | Out-Null }
        try {
            Copy-Item $certPath $dockerCa -Force
            Write-Ok "  configured ($dockerCa)"
            Write-Host "  Note: restart Docker Desktop to apply changes"
            Add-Replay "Copy-Item -Path `"$certPath`" -Destination `"$dockerCa`" -Force"
        } catch [System.UnauthorizedAccessException] {
            Write-Err "  access denied — could not write to $dockerCa"
        }
    }
}

Write-Host ""
if ($createReplay) { Write-Ok "Done. Replay script: $configuredToolsFile" }
else { Write-Ok "Done." }

# ─── How to add a new tool ────────────────────────────────────────────────────
# Tool using an env var:   Set-ToolSslCert 'MyTool' 'MYTOOL_CA_CERTS' 'mytool'
# Tool using a command:    Set-ToolSslCert 'MyTool' $null 'mytool' "mytool config set cafile `"$certPath`""
