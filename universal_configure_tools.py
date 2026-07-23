#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import platform
import shutil

# Determine if the OS is Windows
is_windows = platform.system() == "Windows"


def _augment_path():
    """Add common tool directories to PATH if missing.

    Homebrew (/opt/homebrew/bin), Linuxbrew, and per-user installs like
    ~/.cargo/bin or ~/Library/pnpm are only added to PATH by a shell profile
    (.zprofile/.zshrc/.bashrc) — which a non-interactive/non-login shell (or
    this script launched some other way) never sources, making tools that
    live there invisible even though they're installed.
    """
    if is_windows:
        return
    home = os.path.expanduser('~')
    candidates = [
        '/opt/homebrew/bin', '/opt/homebrew/sbin',
        '/usr/local/bin', '/usr/local/sbin',
        '/home/linuxbrew/.linuxbrew/bin', '/home/linuxbrew/.linuxbrew/sbin',
        os.path.join(home, '.cargo', 'bin'),
        os.path.join(home, '.local', 'bin'),
        os.path.join(home, 'Library', 'pnpm'),
        os.path.join(home, '.local', 'share', 'pnpm'),
    ]
    current = os.environ.get('PATH', '')
    existing = set(current.split(os.pathsep))
    to_add = [d for d in candidates if os.path.isdir(d) and d not in existing]
    if to_add:
        # Drop any empty segment (e.g. from an unset/empty PATH) — an empty
        # entry means "search the current directory", a real security risk.
        os.environ['PATH'] = os.pathsep.join(p for p in (to_add + [current]) if p)


_augment_path()

# ─── ANSI color helpers ───────────────────────────────────────────────────────
def _enable_ansi():
    """Enable VT/ANSI escape processing on Windows 10+."""
    if is_windows:
        try:
            import ctypes
            k = ctypes.windll.kernel32
            h = k.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            m = ctypes.c_ulong()
            k.GetConsoleMode(h, ctypes.byref(m))
            k.SetConsoleMode(h, m.value | 4)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        except Exception:
            # Best-effort only — fall back to uncolored output if the console
            # doesn't support VT sequences.
            pass

_enable_ansi()
_E   = '\033'
_GRN = f'{_E}[92m'   # bright green
_YLW = f'{_E}[93m'   # bright yellow
_RED = f'{_E}[91m'   # bright red
_CYN = f'{_E}[96m'   # bright cyan
_GRY = f'{_E}[90m'   # dark gray
_BLD = f'{_E}[1m'    # bold
_RST = f'{_E}[0m'    # reset

def ok(msg):     print(f'{_GRN}{msg}{_RST}')
def warn(msg):   print(f'{_YLW}{msg}{_RST}')
def err(msg):    print(f'{_RED}{msg}{_RST}')
def header(msg): print(f'\n{_CYN}{_BLD}{msg}{_RST}')
def dim(msg):    print(f'{_GRY}{msg}{_RST}')
def info(msg):   print(msg)
# ─────────────────────────────────────────────────────────────────────────────

def get_shell():
    if is_windows:
        return None
    my_shell = os.getenv('SHELL', '')
    info(f'Shell used is {my_shell}')
    if 'bash' in my_shell:
        return os.path.expanduser('~/.bash_profile')
    return os.path.expanduser('~/.zshenv')

shell = get_shell()

def command_exists(command):
    return shutil.which(command) is not None


def get_persistent_env_var(var_name):
    """Read a user env var from the Windows registry (reflects persisted state, not just the current process).
    On Windows, os.getenv() returns the value inherited when the shell started, which may be stale
    after setx/reg-delete in the same session. The registry always reflects the true current state."""
    if not is_windows:
        return os.getenv(var_name)
    try:
        import winreg
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
            value, _ = winreg.QueryValueEx(key, var_name)
            return value
    except OSError:
        return None


def find_all_pythons():
    """Return a deduplicated list of (path, label) for every Python executable found."""
    found = {}

    if is_windows:
        try:
            result = subprocess.run(['py', '--list-paths'], capture_output=True, text=True)
            if result.returncode == 0:
                for line in result.stdout.splitlines():
                    m = re.search(r'(-V:\S+)\s+\*?\s+(.*python\.exe)', line, re.IGNORECASE)
                    if m:
                        label, path = m.group(1), m.group(2).strip()
                        if os.path.isfile(path):
                            found[os.path.normcase(path)] = (path, label)
        except FileNotFoundError:
            # The `py` launcher isn't installed — skip this discovery method.
            pass
        result = subprocess.run(['where', 'python'], capture_output=True, text=True)
        for line in result.stdout.splitlines():
            line = line.strip()
            if line and os.path.isfile(line):
                found.setdefault(os.path.normcase(line), (line, 'python'))
        bundled_sources = [
            (['az', '--version'], r"Python location '(.+python\.exe)'", 'Azure CLI'),
        ]
        for cmd, pattern, label in bundled_sources:
            try:
                r = subprocess.run(cmd, capture_output=True, text=True)
                if r.returncode == 0:
                    m = re.search(pattern, r.stdout, re.IGNORECASE)
                    if m:
                        path = m.group(1)
                        if os.path.isfile(path):
                            found.setdefault(os.path.normcase(path), (path, label))
            except FileNotFoundError:
                # This bundled-Python source (e.g. Azure CLI) isn't installed.
                pass
    else:
        for cmd in ['python3', 'python']:
            result = subprocess.run(['which', '-a', cmd], capture_output=True, text=True)
            for line in result.stdout.splitlines():
                line = line.strip()
                if line and os.path.isfile(line):
                    real = os.path.realpath(line)
                    found.setdefault(os.path.normcase(real), (real, cmd))

    return list(found.values())


def find_all_jdks():
    """Return a deduplicated list of (jdk_home, label) for every JDK installation found."""
    found = {}

    def add_jdk(home, label):
        if not home or not os.path.isdir(home):
            return
        keytool = os.path.join(home, 'bin', 'keytool.exe' if is_windows else 'keytool')
        if os.path.isfile(keytool):
            found.setdefault(os.path.normcase(home), (home, label))

    if is_windows:
        add_jdk(os.getenv('JAVA_HOME', ''), 'JAVA_HOME')
        keytool_path = shutil.which('keytool')
        if keytool_path:
            add_jdk(os.path.dirname(os.path.dirname(os.path.realpath(keytool_path))), 'PATH')
        try:
            import winreg
            for hive, key_path in [
                (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\JavaSoft\JDK'),
                (winreg.HKEY_LOCAL_MACHINE, r'SOFTWARE\WOW6432Node\JavaSoft\JDK'),
            ]:
                try:
                    with winreg.OpenKey(hive, key_path) as key:
                        i = 0
                        while True:
                            try:
                                version = winreg.EnumKey(key, i)
                                with winreg.OpenKey(key, version) as vkey:
                                    home, _ = winreg.QueryValueEx(vkey, 'JavaHome')
                                    add_jdk(home, f'Registry ({version})')
                            except OSError:
                                break
                            i += 1
                except OSError:
                    # Registry key (this JDK vendor path) doesn't exist — skip it.
                    pass
        except ImportError:
            # winreg is Windows-only; nothing to read from the registry elsewhere.
            pass
        prog_files = os.environ.get('ProgramFiles', r'C:\Program Files')
        for vendor in ['Java', 'Eclipse Adoptium', 'Amazon Corretto', 'Zulu', 'Microsoft']:
            parent = os.path.join(prog_files, vendor)
            if os.path.isdir(parent):
                for entry in os.listdir(parent):
                    add_jdk(os.path.join(parent, entry), f'Common ({entry})')
    else:
        add_jdk(os.getenv('JAVA_HOME', ''), 'JAVA_HOME')
        for cmd in ['java', 'keytool']:
            r = subprocess.run(['which', cmd], capture_output=True, text=True)
            if r.returncode == 0:
                real = os.path.realpath(r.stdout.strip())
                add_jdk(os.path.dirname(os.path.dirname(real)), 'PATH')

    return list(found.values())


# ─── Rollback ─────────────────────────────────────────────────────────────────

def rollback():
    print(f'\n{_CYN}{_BLD}╔══════════════════════════════════════════╗{_RST}')
    print(f'{_CYN}{_BLD}║   Bulwarx SSL Dev Tools Configuration    ║{_RST}')
    print(f'{_CYN}{_BLD}║                    Rollback              ║{_RST}')
    print(f'{_CYN}{_BLD}╚══════════════════════════════════════════╝{_RST}')

    # --- Python ---
    header('Python')
    marker = b'# Netskope SSL bundle'
    all_pythons = find_all_pythons()
    if all_pythons:
        _seen_certifi = set()
        _seen_pip = set()
        for py_exe, label in all_pythons:
            info(f'\n  {_BLD}[{label}]{_RST} {py_exe}')
            certifi_bundle = None
            r = subprocess.run([py_exe, '-c', 'import certifi; print(certifi.where())'],
                               capture_output=True, text=True)
            if r.returncode == 0:
                certifi_bundle = r.stdout.strip()
                if certifi_bundle in _seen_certifi:
                    dim(f'    certifi: same bundle already processed ({certifi_bundle})')
                else:
                    _seen_certifi.add(certifi_bundle)
                    try:
                        with open(certifi_bundle, 'rb') as f:
                            content = f.read()
                        idx = content.find(b'\n' + marker)
                        if idx == -1:
                            idx2 = content.find(marker)
                            if idx2 != -1:
                                idx = idx2 - 1 if idx2 > 0 and content[idx2 - 1:idx2] == b'\n' else idx2
                        if idx != -1:
                            with open(certifi_bundle, 'wb') as f:
                                f.write(content[:idx])
                            ok(f'    certifi: Netskope bundle removed ({certifi_bundle})')
                        else:
                            warn(f'    certifi: no Netskope marker found ({certifi_bundle})')
                    except (PermissionError, OSError) as e:
                        err(f'    certifi: failed — {e}')
            else:
                dim(f'    certifi: not installed')

            # pip dedup — use certifi_bundle as key: same certifi path = same Python
            # installation = same pip config, regardless of what pip config list returns
            pip_key = certifi_bundle if certifi_bundle else py_exe
            if pip_key in _seen_pip:
                dim(f'    pip: same installation already processed')
            else:
                _seen_pip.add(pip_key)
                r = subprocess.run([py_exe, '-m', 'pip', 'config', 'unset', 'global.cert'],
                                   capture_output=True, text=True)
                if r.returncode == 0:
                    ok(f'    pip: global cert unset')
                else:
                    dim(f'    pip: cert not configured or pip not installed')
    else:
        dim('  No Python installations found')

    # --- Environment variables ---
    header('Environment Variables')
    # Rollback also clears the legacy directory-var name that older versions
    # wrongly set to a file path (GIT_SSL_CAPATH).
    env_vars = ['SSL_CERT_FILE', 'AWS_CA_BUNDLE', 'NODE_EXTRA_CA_CERTS',
                'REQUESTS_CA_BUNDLE', 'GIT_SSL_CAINFO', 'GIT_SSL_CAPATH']
    if is_windows:
        for var in env_vars:
            r = subprocess.run(
                ['reg', 'delete', r'HKCU\Environment', '/v', var, '/f'],
                capture_output=True, text=True)
            if r.returncode == 0:
                ok(f'  {var}: removed')
            else:
                dim(f'  {var}: not set')
    else:
        if shell and os.path.isfile(shell):
            with open(shell, 'r') as f:
                lines = f.readlines()
            pattern = re.compile(
                r'^export\s+(' + '|'.join(env_vars) + r')\s*=.*\n?$')
            new_lines = [ln for ln in lines if not pattern.match(ln)]
            removed = len(lines) - len(new_lines)
            if removed > 0:
                with open(shell, 'w') as f:
                    f.writelines(new_lines)
                ok(f'  {removed} variable export(s) removed from {shell}')
            else:
                warn(f'  no Netskope environment variables found in {shell}')
        else:
            warn(f'  shell profile not found: {shell}')

    # Git is configured via GIT_SSL_CAINFO env var — already removed above.
    # cURL is configured via SSL_CERT_FILE env var — already removed above.

    # --- Google Cloud CLI ---
    header('Google Cloud CLI')
    if command_exists('gcloud'):
        r = subprocess.run(['gcloud', 'config', 'unset', 'core/custom_ca_certs_file'],
                           capture_output=True, text=True, shell=is_windows)
        if r.returncode == 0:
            ok('  gcloud: custom_ca_certs_file unset')
        else:
            warn('  gcloud: custom_ca_certs_file not configured')
    else:
        dim('  gcloud is not installed')

    # --- NPM ---
    header('NPM')
    if command_exists('npm'):
        r = subprocess.run(['npm', 'config', 'delete', 'cafile'],
                           capture_output=True, text=True, shell=is_windows)
        if r.returncode == 0:
            ok('  npm cafile: deleted')
        else:
            warn('  npm: cafile not configured')
    else:
        dim('  npm is not installed')

    # --- PHP Composer ---
    header('PHP Composer')
    if command_exists('composer'):
        r = subprocess.run(['composer', 'config', '--global', '--unset', 'cafile'],
                           capture_output=True, text=True, shell=is_windows)
        if r.returncode == 0:
            ok('  composer cafile: unset')
        else:
            warn('  composer: cafile not configured')
    else:
        dim('  composer is not installed')

    # --- Yarn ---
    header('Yarn')
    yarn_found = False
    for yarn_cmd in ['yarn', 'yarnpkg']:
        if command_exists(yarn_cmd):
            yarn_found = True
            r = subprocess.run([yarn_cmd, 'config', 'delete', 'httpsCaFilePath'],
                               capture_output=True, text=True, shell=is_windows)
            if r.returncode != 0:
                r = subprocess.run([yarn_cmd, 'config', 'delete', 'cafile'],
                                   capture_output=True, text=True, shell=is_windows)
            if r.returncode == 0:
                ok(f'  {yarn_cmd}: cafile config removed')
            else:
                warn(f'  {yarn_cmd}: cafile not configured')
            break
    if not yarn_found:
        dim('  yarn is not installed')

    # --- pnpm ---
    header('pnpm')
    if command_exists('pnpm'):
        r = subprocess.run(['pnpm', 'config', 'delete', 'cafile'],
                           capture_output=True, text=True, shell=is_windows)
        if r.returncode == 0:
            ok('  pnpm cafile: deleted')
        else:
            warn('  pnpm: cafile not configured')
    else:
        dim('  pnpm is not installed')

    # --- Java ---
    header('Java')
    storepass = 'changeit'
    all_jdks = find_all_jdks()
    if all_jdks:
        for jdk_home, label in all_jdks:
            info(f'\n  {_BLD}[{label}]{_RST} {jdk_home}')
            cacerts = os.path.join(jdk_home, 'lib', 'security', 'cacerts')
            if not os.path.isfile(cacerts):
                cacerts = os.path.join(jdk_home, 'jre', 'lib', 'security', 'cacerts')
            if not os.path.isfile(cacerts):
                warn('    cacerts: not found')
                continue
            keytool = os.path.join(jdk_home, 'bin',
                                   'keytool.exe' if is_windows else 'keytool')
            for i in range(2):
                alias = f'netskope-{i}'
                r = subprocess.run(
                    [keytool, '-delete', '-alias', alias,
                     '-keystore', cacerts, '-storepass', storepass],
                    capture_output=True, text=True)
                if r.returncode == 0:
                    ok(f'    keytool alias {alias}: removed')
                else:
                    dim(f'    keytool alias {alias}: not found')
    else:
        dim('  No Java installations found')

    # --- VS Code ---
    header('VS Code')
    if is_windows:
        appdata = os.getenv('APPDATA', '')
        settings_dirs = [
            os.path.join(appdata, 'Code', 'User'),
            os.path.join(appdata, 'Code - Insiders', 'User'),
        ]
    else:
        home = os.path.expanduser('~')
        settings_dirs = [
            os.path.join(home, '.config', 'Code', 'User'),
            os.path.join(home, '.config', 'Code - Insiders', 'User'),
            os.path.join(home, 'Library', 'Application Support', 'Code', 'User'),
        ]
    vscode_found = False
    for settings_dir in settings_dirs:
        if not os.path.isdir(settings_dir):
            continue
        vscode_found = True
        edition = 'VS Code Insiders' if 'Insiders' in settings_dir else 'VS Code'
        settings_file = os.path.join(settings_dir, 'settings.json')
        if not os.path.isfile(settings_file):
            dim(f'  {edition}: settings.json not found')
            continue
        try:
            with open(settings_file, 'r', encoding='utf-8') as f:
                settings = json.load(f)
            if 'http.systemCertificates' in settings:
                del settings['http.systemCertificates']
                with open(settings_file, 'w', encoding='utf-8') as f:
                    json.dump(settings, f, indent=4)
                ok(f'  {edition}: http.systemCertificates removed')
            else:
                warn(f'  {edition}: http.systemCertificates not configured')
        except (PermissionError, json.JSONDecodeError) as e:
            err(f'  {edition}: failed — {e}')
    if not vscode_found:
        dim('  VS Code is not installed')

    # --- Windows Certificate Store ---
    if is_windows:
        header('Windows Certificate Store')
        # Read the first 2 certs from the bundle (SubCA + RootCA) to get exact thumbprints.
        # Name-based matching alone fails when the tenant uses custom cert names without "Netskope".
        # We also search the CA (Intermediate) store in addition to Root, because certutil
        # sometimes places SubCA there rather than in Root.
        _bundle_candidates = [
            os.path.join(os.path.expanduser('~'), 'netskope', 'netskope-cert-bundle.pem'),
            r'C:\netskope\netskope-cert-bundle.pem',
        ]
        _bundle_path = next((p for p in _bundle_candidates if os.path.isfile(p)), '')
        escaped_bundle = _bundle_path.replace("'", "''")
        ps_script = (
            f"$bundlePath = '{escaped_bundle}'\n"
            "$thumbprints = @()\n"
            "if ($bundlePath -and (Test-Path $bundlePath)) {\n"
            "    $txt = Get-Content $bundlePath -Raw\n"
            "    $rx = [regex]::Matches($txt, '-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----')\n"
            # Only the first 2 PEM blocks are the Netskope SubCA and RootCA
            "    foreach ($m in $rx | Select-Object -First 2) {\n"
            "        try {\n"
            "            $b64 = $m.Value -replace '-----BEGIN CERTIFICATE-----','' "
                                    "-replace '-----END CERTIFICATE-----','' -replace '\\s',''\n"
            "            $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2("
                                    ",[Convert]::FromBase64String($b64))\n"
            "            $thumbprints += $x.Thumbprint\n"
            "        } catch {}\n"
            "    }\n"
            "}\n"
            "$removed = 0\n"
            # Search Trusted Root Certification Authorities (Root) in both LocalMachine and CurrentUser
            "@(Get-ChildItem Cert:\\LocalMachine\\Root, Cert:\\CurrentUser\\Root "
            "-ErrorAction SilentlyContinue) | "
            "Where-Object { $_.Subject -match 'Netskope' -or $_.Issuer -match 'Netskope' "
            "-or ($thumbprints.Count -gt 0 -and $thumbprints -contains $_.Thumbprint) } | "
            "ForEach-Object {\n"
            "    $sloc = if ($_.PSParentPath -match 'LocalMachine') { "
                "[System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine } else { "
                "[System.Security.Cryptography.X509Certificates.StoreLocation]::CurrentUser }\n"
            "    try {\n"
            "        $s = New-Object System.Security.Cryptography.X509Certificates.X509Store("
                "[System.Security.Cryptography.X509Certificates.StoreName]::Root, $sloc)\n"
            "        $s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)\n"
            "        $s.Remove($_)\n"
            "        $s.Close()\n"
            "        Write-Host ('  removed from Trusted Root: ' + $_.Subject) -ForegroundColor Green\n"
            "        $removed++\n"
            "    } catch {\n"
            "        Write-Host ('  failed to remove: ' + $_.Subject + ' - ' + $_) -ForegroundColor Red\n"
            "    }\n"
            "}\n"
            "if ($removed -eq 0) { Write-Host '  no certificates found in Trusted Root Certification Authorities' -ForegroundColor DarkGray }"
        )
        subprocess.run(['powershell', '-NoProfile', '-Command', ps_script])

    # --- Docker Desktop ---
    header('Docker Desktop')
    docker_ca = os.path.join(os.path.expanduser('~'), '.docker', 'ca.pem')
    if os.path.isfile(docker_ca):
        try:
            os.remove(docker_ca)
            ok(f'  Docker ca.pem removed ({docker_ca})')
        except OSError as e:
            err(f'  Docker ca.pem: failed to remove — {e}')
    else:
        dim(f'  Docker ca.pem not found ({docker_ca})')

    print()
    ok('Rollback complete.')


# ─── Rollback check (before any user prompts) ─────────────────────────────────
if '--rollback' in sys.argv:
    rollback()
    sys.exit(0)

# Default is now the full bundle (Netskope + public CA roots) — pass
# --netskope-only to opt out and get just the two Netskope certs.
# --full-bundle is accepted as a no-op for backward compatibility.
full_bundle = '--netskope-only' not in sys.argv

def get_cli_value(flag):
    """Return the value for `--flag VALUE` or `--flag=VALUE`, else None."""
    for i, a in enumerate(sys.argv):
        if a == flag and i + 1 < len(sys.argv):
            return sys.argv[i + 1]
        if a.startswith(flag + '='):
            return a.split('=', 1)[1]
    return None

# Use an existing PEM bundle instead of downloading (e.g. distributed
# centrally, or when the download endpoint is unreachable).
existing_bundle = get_cli_value('--cert-bundle')

# Pre-set download parameters for silent/unattended runs — when tenant + orgkey
# are both supplied, no prompt is shown even for the values left unset.
cli_tenant_name = get_cli_value('--tenant-name')
cli_org_key     = get_cli_value('--org-key')
cli_cert_name   = get_cli_value('--cert-name')
cli_cert_dir    = get_cli_value('--cert-dir')
cli_recreate    = '--recreate' in sys.argv
silent_download = bool(cli_tenant_name) and bool(cli_org_key)

# ─── Install mode ─────────────────────────────────────────────────────────────

print(f'\n{_CYN}{_BLD}╔══════════════════════════════════════════╗{_RST}')
print(f'{_CYN}{_BLD}║   Bulwarx SSL Dev Tools Configuration    ║{_RST}')
print(f'{_CYN}{_BLD}╚══════════════════════════════════════════╝{_RST}')

import requests
import urllib3

def get_input(prompt, default):
    user_input = input(f'{prompt} [{default}]: ')
    return user_input if user_input else default

def normalize_tenant(raw):
    """Strip https://, http://, and any path suffix so the cert URL splices cleanly."""
    t = raw.strip()
    for prefix in ('https://', 'http://'):
        if t.lower().startswith(prefix):
            t = t[len(prefix):]
            break
    # Drop anything after the host
    for sep in '/?#':
        i = t.find(sep)
        if i != -1:
            t = t[:i]
    return t.rstrip('.')

def create_cert_bundle():
    info('Creating cert bundle...')
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    bundle_path = os.path.join(cert_dir, cert_name)
    netskope_urls = [
        f'https://addon-{tenant_name}/config/org/cert?orgkey={org_key}',  # RootCA first
        f'https://addon-{tenant_name}/config/ca/cert?orgkey={org_key}',   # SubCA second
    ]
    extra_urls = ['https://curl.se/ca/cacert.pem'] if full_bundle else []

    # Fetch each URL into memory first. If any non-2xx or any response lacks a
    # PEM marker, abort BEFORE touching the on-disk bundle — otherwise we end
    # up with a half-written file that quietly omits Netskope's cert.
    cached = []
    for url in netskope_urls + extra_urls:
        resp = requests.get(url, verify=False)
        if not resp.ok:
            err(f'Certificate download failed: HTTP {resp.status_code} from {url}')
            err('Check tenant URL and orgkey, then re-run.')
            sys.exit(1)
        body = resp.content
        if b'-----BEGIN CERTIFICATE-----' not in body:
            err(f'Response from {url} does not contain a certificate.')
            sys.exit(1)
        cached.append(body)

    if os.path.exists(bundle_path):
        os.remove(bundle_path)
    with open(bundle_path, 'wb') as f:
        for body in cached:
            f.write(body)
    ok(f'Cert bundle saved: {bundle_path}')
    if full_bundle:
        netskope_only_path = os.path.join(cert_dir, 'netskope_only.pem')
        with open(netskope_only_path, 'wb') as f:
            f.write(cached[0])
            f.write(cached[1])
        ok(f'Netskope-only cert saved: {netskope_only_path}')

if existing_bundle:
    # ─── Existing bundle: validate, then copy to the canonical cert_dir/
    # cert_name location (--cert-dir/--cert-name if given, else the same
    # defaults as the download path) so every tool ends up configured
    # against a stable path — not wherever the source file happened to
    # live. This matters for MDM deployment: an Intune Win32 app's staged
    # package content is deleted right after the install command finishes,
    # so a script bundled alongside the cert just needs --cert-bundle
    # pointing at its own package directory and this copies it out to
    # somewhere permanent before that happens.
    existing_bundle = os.path.normpath(os.path.expanduser(existing_bundle))
    if not os.path.isfile(existing_bundle):
        err(f'Certificate bundle not found: {existing_bundle}')
        sys.exit(1)
    with open(existing_bundle, 'rb') as f:
        if b'-----BEGIN CERTIFICATE-----' not in f.read():
            err(f'{existing_bundle} does not contain a PEM certificate.')
            sys.exit(1)

    cert_name = cli_cert_name or 'netskope-cert-bundle.pem'
    cert_dir = os.path.normpath(os.path.expanduser(cli_cert_dir or '~/netskope'))
    os.makedirs(cert_dir, exist_ok=True)
    bundle_path = os.path.join(cert_dir, cert_name)

    if os.path.normpath(existing_bundle) != os.path.normpath(bundle_path):
        try:
            shutil.copy2(existing_bundle, bundle_path)
        except OSError as e:
            err(f'Failed to copy certificate bundle to: {bundle_path} ({e})')
            sys.exit(1)
        if not os.path.isfile(bundle_path):
            err(f'Certificate bundle copy did not produce a file at: {bundle_path}')
            sys.exit(1)
        ok(f'Copied certificate bundle to: {bundle_path}')

    # Treat as freshly provided so Python/Java stores are (re)configured.
    cert_was_recreated = True
    ok(f'Using existing certificate bundle: {bundle_path}')
else:
    # ─── Download from Netskope ────────────────────────────────────────────
    cert_name = cli_cert_name or (
        get_input('Please provide certificate bundle name', 'netskope-cert-bundle.pem')
        if not silent_download else 'netskope-cert-bundle.pem')
    cert_dir = cli_cert_dir or (
        get_input('Please provide certificate bundle location', '~/netskope')
        if not silent_download else '~/netskope')
    cert_dir = os.path.normpath(os.path.expanduser(cert_dir))

    if not os.path.isdir(cert_dir):
        warn(f'{cert_dir} does not exist — creating it')
        os.makedirs(cert_dir, exist_ok=True)

    # Not maintained in --netskope-only mode — remove a stale sidecar left
    # over from an earlier full-bundle run even if we end up keeping the
    # existing main bundle below, so it's never mistaken for a fresh one.
    if not full_bundle:
        netskope_only_path = os.path.join(cert_dir, 'netskope_only.pem')
        if os.path.exists(netskope_only_path):
            os.remove(netskope_only_path)

    tenant_name = normalize_tenant(cli_tenant_name or input(
        'Please provide full tenant name (ex: mytenant.eu.goskope.com): '))
    org_key = (cli_org_key or input('Please provide tenant orgkey: ')).strip()

    # Clear a stale REQUESTS_CA_BUNDLE from the process environment if the file no longer exists
    # (e.g. after rollback deleted the bundle in the same shell session).
    # The tenant check uses verify=False — at this point we don't have a cert bundle yet.
    _stale_ca = os.environ.get('REQUESTS_CA_BUNDLE', '')
    if _stale_ca and not os.path.isfile(_stale_ca):
        del os.environ['REQUESTS_CA_BUNDLE']
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)
    status_code = requests.get(f'https://{tenant_name}/locallogin', verify=False).status_code

    if status_code != 200:
        err('Tenant Unreachable')
        sys.exit(1)
    else:
        ok('Tenant Reachable')

    cert_was_recreated = False
    if os.path.isfile(os.path.join(cert_dir, cert_name)):
        warn(f'{cert_name} already exists in {cert_dir}.')
        if cli_recreate:
            recreate = 'y'
        elif silent_download:
            # Silent/unattended run — don't block on a prompt. Pass --recreate
            # to force regenerating an existing bundle.
            info('Keeping existing bundle (pass --recreate to force regeneration).')
            recreate = 'n'
        else:
            recreate = input('Recreate Certificate Bundle? (y/N) ').strip().lower()
        if recreate == 'y':
            create_cert_bundle()
            cert_was_recreated = True
    else:
        create_cert_bundle()
        cert_was_recreated = True

# --- Replay script ---
_replay_ext = 'bat' if is_windows else 'sh'
# Always create the replay script in a silent/unattended run or when using an
# existing bundle non-interactively — matches the shell scripts' behavior of
# writing it unconditionally, so silent runs never block on this prompt.
if silent_download or existing_bundle:
    create_replay = '--no-replay' not in sys.argv
else:
    create_replay = input(f'Create replay script (configured_tools.{_replay_ext})? (y/N) ').strip().lower() == 'y'
configured_tools_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), f'configured_tools.{_replay_ext}')
if create_replay:
    with open(configured_tools_file, 'w') as f:
        if is_windows:
            f.write('@echo off\n')
    ok(f'Replay script: {configured_tools_file}')

def replay(line):
    if create_replay:
        with open(configured_tools_file, 'a') as f:
            f.write(line + '\n')

def set_env_var(env_var, value):
    if is_windows:
        subprocess.run(f'setx {env_var} "{value}"', shell=True)
    else:
        with open(shell, 'a') as f:
            f.write(f'export {env_var}="{value}"\n')
        # Note: the export takes effect in new shells. We can't `source` the
        # profile from here — a subprocess can't mutate the parent shell's env.


def configure_python_ssl(python_exe, label, cert_path, cert_was_recreated=False):
    """Patch certifi and pip for a specific Python installation."""
    info(f'\n  {_BLD}[{label}]{_RST} {python_exe}')

    r = subprocess.run([python_exe, '-c', 'import certifi; print(certifi.where())'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        certifi_bundle = r.stdout.strip()
        marker = b'# Netskope SSL bundle'
        with open(certifi_bundle, 'rb') as f:
            existing = f.read()
        had_marker = marker in existing
        if had_marker and not cert_was_recreated:
            warn(f'    certifi: already configured ({certifi_bundle})')
        else:
            if had_marker:
                existing = existing[:existing.index(b'\n' + marker)]
            try:
                with open(certifi_bundle, 'wb') as f:
                    f.write(existing)
                with open(cert_path, 'rb') as src, open(certifi_bundle, 'ab') as dst:
                    dst.write(b'\n' + marker + b'\n')
                    dst.write(src.read())
                action = 'updated' if had_marker else 'configured'
                ok(f'    certifi: {action} ({certifi_bundle})')
                replay(f'# certifi patch for {python_exe}')
                if is_windows:
                    replay(f'type "{cert_path}" >> "{certifi_bundle}"')
                else:
                    replay(f'cat "{cert_path}" >> "{certifi_bundle}"')
            except PermissionError:
                err(f'    certifi: access denied — rerun as Administrator to patch {certifi_bundle}')
    else:
        dim(f'    certifi: not installed')

    r = subprocess.run([python_exe, '-m', 'pip', '--version'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        subprocess.run([python_exe, '-m', 'pip', 'config', 'set', 'global.cert', cert_path],
                       capture_output=True)
        ok(f'    pip: configured')
        replay(f'"{python_exe}" -m pip config set global.cert "{cert_path}"')
    else:
        dim(f'    pip: not installed')

    r = subprocess.run([python_exe, '-c', 'import requests; print(requests.__version__)'],
                       capture_output=True, text=True)
    if r.returncode == 0:
        dim(f'    requests {r.stdout.strip()}: present (covered by REQUESTS_CA_BUNDLE)')


def configure_windows_cert_store(cert_path):
    """Import the Netskope CA cert into the Windows certificate store."""
    header('Windows Certificate Store')
    escaped = cert_path.replace("'", "''")
    check_script = (
        f"$p = '{escaped}'\n"
        "$txt = Get-Content $p -Raw -ErrorAction SilentlyContinue\n"
        "if ($txt -match '-----BEGIN CERTIFICATE-----[\\s\\S]*?-----END CERTIFICATE-----') {\n"
        "    $b64 = ($Matches[0] -replace '-----BEGIN CERTIFICATE-----','' "
                   "-replace '-----END CERTIFICATE-----','' -replace '\\s','')\n"
        "    try {\n"
        "        $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(\n"
        "            ,[Convert]::FromBase64String($b64))\n"
        "        $thumb = $x509.Thumbprint\n"
        "        $found = @(Get-ChildItem Cert:\\LocalMachine\\Root, Cert:\\CurrentUser\\Root "
                            "-ErrorAction SilentlyContinue |\n"
        "            Where-Object { $_.Thumbprint -eq $thumb }).Count -gt 0\n"
        "        if ($found) { Write-Output 'FOUND' } else { Write-Output 'NOTFOUND' }\n"
        "    } catch { Write-Output 'ERROR' }\n"
        "} else { Write-Output 'ERROR' }"
    )
    r = subprocess.run(['powershell', '-NoProfile', '-Command', check_script],
                       capture_output=True, text=True)
    result = r.stdout.strip()
    if result == 'FOUND':
        warn('  already configured (found in Trusted Root Certification Authorities)')
        return
    if result == 'ERROR' or not result:
        err('  could not check certificate store')
        return

    info('  importing certificate into Windows store...')
    ret = subprocess.run(['certutil', '-addstore', '-f', 'Root', cert_path],
                         capture_output=True)
    if ret.returncode == 0:
        ok('  configured (Trusted Root Certification Authorities — computer store)')
        replay(f'certutil -addstore -f Root "{cert_path}"')
    else:
        ret2 = subprocess.run(['certutil', '-addstore', '-f', '-user', 'Root', cert_path],
                              capture_output=True)
        if ret2.returncode == 0:
            ok('  configured (Trusted Root Certification Authorities — user store)')
            replay(f'certutil -addstore -f -user Root "{cert_path}"')
        else:
            err('  access denied — rerun as Administrator to import into computer store')


def configure_java_ssl(jdk_home, label, cert_path, cert_was_recreated=False):
    """Import Netskope certs into a JDK truststore."""
    info(f'\n  {_BLD}[{label}]{_RST} {jdk_home}')
    cacerts = os.path.join(jdk_home, 'lib', 'security', 'cacerts')
    if not os.path.isfile(cacerts):
        cacerts = os.path.join(jdk_home, 'jre', 'lib', 'security', 'cacerts')
    if not os.path.isfile(cacerts):
        err('    cacerts: not found')
        return

    keytool = os.path.join(jdk_home, 'bin', 'keytool.exe' if is_windows else 'keytool')
    with open(cert_path, 'r', errors='ignore') as f:
        content = f.read()
    pem_blocks = re.findall(
        r'-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----', content, re.DOTALL)[:2]
    if not pem_blocks:
        err('    keytool: no PEM blocks found in bundle')
        return

    storepass = 'changeit'
    for i, pem in enumerate(pem_blocks):
        alias = f'netskope-{i}'
        r = subprocess.run([keytool, '-list', '-alias', alias, '-keystore', cacerts,
                            '-storepass', storepass], capture_output=True, text=True)
        if r.returncode == 0:
            if not cert_was_recreated:
                warn(f'    keytool alias {alias}: already configured')
                continue
            warn(f'    keytool alias {alias}: removing stale entry to re-import')
            subprocess.run([keytool, '-delete', '-alias', alias, '-keystore', cacerts,
                            '-storepass', storepass], capture_output=True)
        tmp = None
        try:
            with tempfile.NamedTemporaryFile(mode='w', suffix='.pem', delete=False) as t:
                t.write(pem)
                tmp = t.name
            r2 = subprocess.run([keytool, '-import', '-trustcacerts', '-noprompt',
                                  '-alias', alias, '-file', tmp,
                                  '-keystore', cacerts, '-storepass', storepass],
                                 capture_output=True, text=True)
            if r2.returncode == 0:
                ok(f'    keytool alias {alias}: configured')
                replay(f'# Java keytool import for {jdk_home} alias {alias}')
                replay(f'"{keytool}" -import -trustcacerts -noprompt -alias {alias}'
                       f' -file "{cert_path}" -keystore "{cacerts}" -storepass {storepass}')
            else:
                err(f'    keytool alias {alias}: failed — {r2.stderr.strip()}')
        except PermissionError:
            err(f'    keytool: access denied — rerun as Administrator to patch {cacerts}')
        finally:
            if tmp and os.path.exists(tmp):
                os.unlink(tmp)


def configure_vscode(cert_path):
    """Configure VS Code to trust the system certificate store."""
    header('VS Code')
    if is_windows:
        appdata = os.getenv('APPDATA', '')
        settings_dirs = [
            os.path.join(appdata, 'Code', 'User'),
            os.path.join(appdata, 'Code - Insiders', 'User'),
        ]
    else:
        home = os.path.expanduser('~')
        settings_dirs = [
            os.path.join(home, '.config', 'Code', 'User'),
            os.path.join(home, '.config', 'Code - Insiders', 'User'),
            os.path.join(home, 'Library', 'Application Support', 'Code', 'User'),
        ]

    found_any = False
    for settings_dir in settings_dirs:
        if not os.path.isdir(settings_dir):
            continue
        found_any = True
        edition = 'VS Code Insiders' if 'Insiders' in settings_dir else 'VS Code'
        settings_file = os.path.join(settings_dir, 'settings.json')
        try:
            if os.path.isfile(settings_file):
                with open(settings_file, 'r', encoding='utf-8') as f:
                    settings = json.load(f)
            else:
                settings = {}
            if settings.get('http.systemCertificates') is True:
                warn(f'  {edition}: already configured')
                continue
            settings['http.systemCertificates'] = True
            with open(settings_file, 'w', encoding='utf-8') as f:
                json.dump(settings, f, indent=4)
            ok(f'  {edition}: configured')
            replay(f'# VS Code: set http.systemCertificates in {settings_file}')
        except (PermissionError, json.JSONDecodeError) as e:
            err(f'  {edition}: failed — {e}')

    if not found_any:
        dim('  VS Code is not installed')


def configure_dotnet():
    """.NET and NuGet are covered by the Windows Certificate Store — report only."""
    header('.NET / NuGet')
    found = False
    for cmd in ['dotnet', 'nuget']:
        if command_exists(cmd):
            r = subprocess.run([cmd, '--version'], capture_output=True, text=True)
            version = r.stdout.strip() if r.returncode == 0 else 'unknown'
            ok(f'  {cmd} {version} — covered by Windows Certificate Store')
            replay(f'# {cmd}: covered by Windows Certificate Store')
            found = True
    if not found:
        dim('  .NET / NuGet is not installed')


def configure_docker(cert_path):
    """Copy cert bundle to Docker's trusted CA location."""
    header('Docker Desktop')
    docker_dir = os.path.join(os.path.expanduser('~'), '.docker')
    docker_ca = os.path.join(docker_dir, 'ca.pem')

    docker_installed = command_exists('docker')
    if is_windows and not docker_installed:
        docker_desktop_dir = os.path.join(os.getenv('LOCALAPPDATA', ''), 'Docker', 'Desktop')
        docker_installed = os.path.isdir(docker_desktop_dir)

    if not docker_installed:
        dim('  Docker is not installed')
        return

    if os.path.isfile(docker_ca):
        with open(docker_ca, 'rb') as f1, open(cert_path, 'rb') as f2:
            if f1.read() == f2.read():
                warn('  already configured')
                return

    os.makedirs(docker_dir, exist_ok=True)
    try:
        shutil.copy2(cert_path, docker_ca)
        ok(f'  configured ({docker_ca})')
        info('  Note: restart Docker Desktop to apply changes')
        replay(f'cp "{cert_path}" "{docker_ca}"')
    except PermissionError:
        err(f'  access denied — could not write to {docker_ca}')


def configure_tool(tool_name, env_var, check_command, post_command=None):
    print()
    if command_exists(check_command):
        info(f'{_BLD}{tool_name}{_RST} is installed')
        # Not all OpenSSL builds understand --version (older builds only accept "version").
        version_command = 'openssl version' if check_command == 'openssl' else f'{check_command} --version'
        subprocess.run(version_command, shell=True)
        if env_var:
            current_env = _env_before_run.get(env_var)
            if current_env == os.path.join(cert_dir, cert_name):
                warn(f'{tool_name} already configured')
            else:
                set_env_var(env_var, os.path.join(cert_dir, cert_name))
                ok(f'{tool_name} configured')
                if is_windows:
                    replay(f'setx {env_var} "{os.path.join(cert_dir, cert_name)}"')
                else:
                    replay(f'export {env_var}="{os.path.join(cert_dir, cert_name)}"')
        if post_command:
            subprocess.run(post_command, shell=True)
            replay(post_command)
    else:
        dim(f'{tool_name} is not installed')

_cert_path = os.path.join(cert_dir, cert_name)

# Snapshot persisted env vars BEFORE this run touches anything.
# configure_tool uses this so "already configured" only fires for values
# that existed before this run — not for shared vars set earlier in the same run
# (e.g. OpenSSL and cURL both use SSL_CERT_FILE; once OpenSSL sets it, cURL
# should still show "configured", not "already configured").
# get_persistent_env_var reads the registry on Windows and os.getenv elsewhere,
# so the same snapshot logic applies on every platform.
_env_before_run = {
    var: get_persistent_env_var(var)
    for var in ['GIT_SSL_CAINFO', 'SSL_CERT_FILE', 'AWS_CA_BUNDLE',
                'NODE_EXTRA_CA_CERTS', 'REQUESTS_CA_BUNDLE']
}

tools = [
    # Git: GIT_SSL_CAINFO is the *file* path variant. The directory variant
    # (GIT_SSL_CAPATH) is wrong for a single PEM bundle — strict consumers
    # like `uv` warn when a file is in a directory-typed env var.
    ("Git", "GIT_SSL_CAINFO", "git", ""),
    ("OpenSSL", "SSL_CERT_FILE", "openssl", ""),
    ("cURL", "SSL_CERT_FILE", "curl", ""),
    ("AWS CLI", "AWS_CA_BUNDLE", "aws", ""),
    ("Google Cloud CLI", None, "gcloud", f'gcloud config set core/custom_ca_certs_file "{_cert_path}"'),
    ("NodeJS Package Manager (NPM)", None, "npm", f'npm config set cafile "{_cert_path}"'),
    # pnpm reads the same npm-compatible "cafile" config key.
    ("pnpm", None, "pnpm", f'pnpm config set cafile "{_cert_path}"'),
    ("NodeJS", "NODE_EXTRA_CA_CERTS", "node", ""),
    ("Ruby", "SSL_CERT_FILE", "ruby", ""),
    ("PHP Composer", None, "composer", f'composer config --global cafile "{_cert_path}"'),
    ("GoLang", "SSL_CERT_FILE", "go", ""),
    ("Azure CLI", "REQUESTS_CA_BUNDLE", "az", ""),
    ("Oracle Cloud CLI", "REQUESTS_CA_BUNDLE", "oci", ""),
    ("Cargo Package Manager", "SSL_CERT_FILE", "cargo", ""),
]

# Yarn's binary name differs by platform: Homebrew (macOS) and most Linux
# distros ship "yarn"; Debian/Ubuntu's apt package ships "yarnpkg" instead
# because a conflicting "yarn" binary already exists there.
_yarn_cmd = next((c for c in ('yarn', 'yarnpkg') if command_exists(c)), None)
if _yarn_cmd:
    tools.append(("Yarn", None, _yarn_cmd, f'{_yarn_cmd} config set httpsCaFilePath "{_cert_path}"'))
else:
    tools.append(("Yarn", None, "yarn", ""))

# --- Python: find all installations and patch each one ---
header('Python')
_all_pythons = find_all_pythons()
if _all_pythons:
    for _py_exe, _label in _all_pythons:
        configure_python_ssl(_py_exe, _label, _cert_path, cert_was_recreated)
    set_env_var('REQUESTS_CA_BUNDLE', _cert_path)
    ok('\nREQUESTS_CA_BUNDLE set globally')
    if is_windows:
        replay(f'setx REQUESTS_CA_BUNDLE "{_cert_path}"')
    else:
        replay(f'export REQUESTS_CA_BUNDLE="{_cert_path}"')
else:
    dim('  No Python installations found')

for tool_name, env_var, check_command, post_command in tools:
    configure_tool(tool_name, env_var, check_command, post_command)

azure_storage_path = (os.path.expanduser('~/Library/Application Support/StorageExplorer/certs')
                      if not is_windows else
                      os.path.join(os.getenv('USERPROFILE', ''), 'AppData', 'Roaming', 'StorageExplorer', 'certs'))
print()
if os.path.isdir(azure_storage_path):
    info(f'{_BLD}Azure Storage Explorer{_RST} is installed')
    shutil.copy(os.path.join(cert_dir, cert_name), azure_storage_path)
    ok('Azure Storage Explorer configured')
    replay(f'cp "{os.path.join(cert_dir, cert_name)}" "{azure_storage_path}"')
else:
    dim('Azure Storage Explorer is not installed')

if is_windows:
    configure_windows_cert_store(_cert_path)

header('Java')
_all_jdks = find_all_jdks()
if _all_jdks:
    for _jdk_home, _jdk_label in _all_jdks:
        configure_java_ssl(_jdk_home, _jdk_label, _cert_path, cert_was_recreated)
else:
    dim('  No Java installations found')

configure_vscode(_cert_path)

if is_windows:
    configure_dotnet()

configure_docker(_cert_path)

if create_replay:
    ok(f'\nReplay script saved: {configured_tools_file}')
