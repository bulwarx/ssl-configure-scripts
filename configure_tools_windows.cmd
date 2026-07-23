@echo off
:: This tool will try to detect common cli tools and will configure the Netskope SSL certificate bundle.

:: ANSI color setup (Windows 10 1511+ supports VT sequences in cmd)
for /f %%a in ('echo prompt $E ^| cmd') do set "ESC=%%a"
set "GRN=%ESC%[92m"
set "YLW=%ESC%[93m"
set "RED=%ESC%[91m"
set "CYN=%ESC%[96m"
set "GRY=%ESC%[90m"
set "RST=%ESC%[0m"

:: Check for rollback mode
if /i "%~1"=="rollback" goto :do_rollback

:: Check for netskope-only mode (default: full bundle, Netskope + public CA
:: roots). "full-bundle" is accepted as a no-op for backward compatibility
:: since it is now the default.
set fullBundle=1
for %%a in (%*) do if /i "%%a"=="netskope-only" set fullBundle=0

:: Parse named unattended-deployment flags: tenant-name=, org-key=,
:: cert-name=, cert-dir=, cert-bundle=, recreate, create-replay. Any of
:: these let this run skip the interactive prompt(s) they cover.
set "tenantName="
set "orgKey="
set "certName="
set "certDir="
set "certBundle="
set recreateFlag=0
set createReplayFlag=0
for %%a in (%*) do call :parse_arg "%%a"

:: Tenant + orgkey (download path) or an existing bundle path both mean this
:: is a silent/unattended run — no prompt below should block it, even ones
:: (existing bundle / recreate / replay) that aren't directly about those
:: two values.
set silentRun=0
if defined certBundle set silentRun=1
if defined tenantName if defined orgKey set silentRun=1

:: Optionally use an existing bundle instead of downloading. Skipped
:: entirely for a silent/unattended run.
if not defined certBundle if "%silentRun%"=="0" (
    set /p useExisting="Use an existing certificate bundle instead of downloading? [y/N]: "
    if /i "%useExisting%"=="y" set /p certBundle="Path to existing .pem bundle: "
)
if defined certBundle goto :use_existing

:: Set Certificate bundle name and location
if not defined certName if "%silentRun%"=="0" set /p certName="Please provide certificate bundle name [netskope-cert-bundle.pem]:"
if not defined certName set certName=netskope-cert-bundle.pem

if not defined certDir if "%silentRun%"=="0" set /p certDir="Please provide certificate bundle location [C:\netskope]:"
if not defined certDir set certDir=C:\netskope

if not exist "%certDir%" (
    echo %RED%%certDir% does not exist.%RST%
    echo %YLW%Creating %certDir%%RST%
    mkdir "%certDir%"
)

:: Not maintained in netskope-only mode — remove a stale sidecar left over
:: from an earlier full-bundle run even if we end up keeping the existing
:: main bundle below, so it's never mistaken for a freshly generated one.
if "%fullBundle%"=="0" if exist "%certDir%\netskope_only.pem" del /f /q "%certDir%\netskope_only.pem" >NUL 2>&1

:: Get tenant information to create certificate bundle
if not defined tenantName if "%silentRun%"=="0" set /p tenantName="Please provide full tenant name (ex: mytenant.eu.goskope.com):"
if not defined orgKey if "%silentRun%"=="0" set /p orgKey="Please provide tenant orgkey:"

:: Strip an https:// or http:// prefix if the user pasted a full URL — otherwise
:: the addon-%tenantName% splice below produces a malformed URL.
if /i "%tenantName:~0,8%"=="https://" set tenantName=%tenantName:~8%
if /i "%tenantName:~0,7%"=="http://"  set tenantName=%tenantName:~7%
for /f "tokens=1 delims=/?#" %%H in ("%tenantName%") do set tenantName=%%H

:: Check tenant reachability
curl -k --write-out "%%{http_code}" --silent --output NUL https://%tenantName%/locallogin > temp.txt
set /p status_code=<temp.txt
del temp.txt

if "%status_code%" NEQ "307" (
    echo %RED%Tenant Unreachable%RST%
    exit /b 1
) else (
    echo %GRN%Tenant Reachable%RST%
)

:: Create or update certificate bundle
set certWasRecreated=0
set recreate=n
if exist "%certDir%\%certName%" (
    echo %YLW%%certName% already exists in %certDir%.%RST%
    if "%recreateFlag%"=="1" (
        set recreate=y
    ) else if "%silentRun%"=="1" (
        echo %GRY%Keeping existing bundle ^(pass recreate to force regeneration^).%RST%
    ) else (
        set /p recreate="Recreate Certificate Bundle? (y/n): "
    )
) else (
    set recreate=y
)
if /i "%recreate%"=="y" (
    echo %CYN%Creating cert bundle...%RST%
    :: Fetch each URL into a temp file and check both HTTP status (curl -f
    :: fails fast on non-2xx) and that the response contains a PEM marker.
    :: Only assemble the bundle if every part is good.
    set "_tmp_root=%TEMP%\netskope_root_%RANDOM%.pem"
    set "_tmp_sub=%TEMP%\netskope_sub_%RANDOM%.pem"
    set "_tmp_pub=%TEMP%\netskope_pub_%RANDOM%.pem"

    curl -k -f -sS -o "%_tmp_root%" "https://addon-%tenantName%/config/org/cert?orgkey=%orgKey%"
    if errorlevel 1 (
        echo %RED%Certificate download failed (RootCA^). Check tenant URL and orgkey.%RST%
        del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL
        exit /b 1
    )
    findstr /c:"BEGIN CERTIFICATE" "%_tmp_root%" >NUL || (
        echo %RED%RootCA response did not contain a certificate.%RST%
        del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL
        exit /b 1
    )

    curl -k -f -sS -o "%_tmp_sub%" "https://addon-%tenantName%/config/ca/cert?orgkey=%orgKey%"
    if errorlevel 1 (
        echo %RED%Certificate download failed (SubCA^). Check tenant URL and orgkey.%RST%
        del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL
        exit /b 1
    )
    findstr /c:"BEGIN CERTIFICATE" "%_tmp_sub%" >NUL || (
        echo %RED%SubCA response did not contain a certificate.%RST%
        del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL
        exit /b 1
    )

    if "%fullBundle%"=="1" (
        curl -k -f -sS -L -o "%_tmp_pub%" "https://curl.se/ca/cacert.pem"
        if errorlevel 1 (
            echo %RED%Public CA bundle download failed.%RST%
            del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL
            exit /b 1
        )
    )

    if exist "%certDir%\%certName%" del /f /q "%certDir%\%certName%" >NUL 2>&1
    type "%_tmp_root%" >> "%certDir%\%certName%"
    type "%_tmp_sub%"  >> "%certDir%\%certName%"
    if "%fullBundle%"=="1" (
        type "%_tmp_pub%" >> "%certDir%\%certName%"
        if exist "%certDir%\netskope_only.pem" del /f /q "%certDir%\netskope_only.pem" >NUL 2>&1
        type "%_tmp_root%" >> "%certDir%\netskope_only.pem"
        type "%_tmp_sub%"  >> "%certDir%\netskope_only.pem"
    )
    del /q "%_tmp_root%" "%_tmp_sub%" "%_tmp_pub%" 2>NUL

    echo %GRN%Cert bundle created: %certDir%\%certName%%RST%
    set certWasRecreated=1
)
goto :after_bundle

:use_existing
:: Validate the provided bundle, then derive certDir / certName from its path.
if not exist "%certBundle%" (
    echo %RED%Certificate bundle not found: %certBundle%%RST%
    exit /b 1
)
findstr /c:"BEGIN CERTIFICATE" "%certBundle%" >NUL || (
    echo %RED%%certBundle% does not contain a PEM certificate.%RST%
    exit /b 1
)
for %%F in ("%certBundle%") do (
    set "certDir=%%~dpF"
    set "certName=%%~nxF"
)
if "%certDir:~-1%"=="\" set "certDir=%certDir:~0,-1%"
set certWasRecreated=1
echo %GRN%Using existing certificate bundle: %certBundle%%RST%

:after_bundle

:: Ask whether to create a replay script. Skipped for a silent/unattended
:: run — pass create-replay to get it without being asked.
set createReplay=n
if "%silentRun%"=="0" (
    set /p createReplay="Create replay script (configured_tools.bat)? [y/N]: "
) else if "%createReplayFlag%"=="1" (
    set createReplay=y
)
if /i "%createReplay%"=="y" (
    echo @echo off > "%~dp0configured_tools.bat"
    echo %GRN%Replay script: %~dp0configured_tools.bat%RST%
)

:: Tools configuration (add more tools here as needed)

:: Windows Certificate Store
echo.
echo %CYN%Windows Certificate Store:%RST%
powershell -NoProfile -Command "$cr='%createReplay%'; $certContent = Get-Content '%certDir%\%certName%' -Raw; if ($certContent -match '-----BEGIN CERTIFICATE-----\s*([\s\S]*?)\s*-----END CERTIFICATE-----') { $b64 = $Matches[1] -replace '\s',''; try { $x509 = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2(,[Convert]::FromBase64String($b64)); $thumb = $x509.Thumbprint; $inStore = @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue | Where-Object { $_.Thumbprint -eq $thumb }).Count -gt 0; if ($inStore) { Write-Host '  already configured (certificate found in store)' -ForegroundColor Yellow } else { Write-Host '  importing certificate...' -ForegroundColor DarkGray; $r = certutil -addstore -f Root '%certDir%\%certName%' 2>&1; if ($LASTEXITCODE -eq 0) { Write-Host '  configured (imported into LocalMachine\Root)' -ForegroundColor Green; if ($cr -ieq 'y') { Add-Content -Path configured_tools.bat -Value 'certutil -addstore -f Root \"%certDir%\%certName%\"' } } else { $r2 = certutil -addstore -f -user Root '%certDir%\%certName%' 2>&1; if ($LASTEXITCODE -eq 0) { Write-Host '  configured (imported into CurrentUser\Root)' -ForegroundColor Green; if ($cr -ieq 'y') { Add-Content -Path configured_tools.bat -Value 'certutil -addstore -f -user Root \"%certDir%\%certName%\"' } } else { Write-Host '  access denied - rerun as Administrator to import into machine store' -ForegroundColor Red } } } } catch { Write-Host ('  could not check certificate store: ' + $_) -ForegroundColor Red } } else { Write-Host '  no PEM certificate found in bundle' -ForegroundColor Red }"

echo.
call :command_exists git
if %ERRORLEVEL% EQU 0 call :configure_tool git "git config --global http.sslCAInfo" "git config --global http.sslCAInfo" "git config --global http.sslCAInfo %certDir%\%certName%"

echo.
call :command_exists openssl
if %ERRORLEVEL% EQU 0 call :configure_tool openssl "openssl version -a" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists curl
if %ERRORLEVEL% EQU 0 (
    echo %GRN%cURL is installed%RST%
    curl --version
    echo --ca-native > %HOMEPATH%\.curlrc
	echo --ssl-revoke-best-effort >> %HOMEPATH%\.curlrc
    echo %GRN%cURL configured%RST%
    if /i "%createReplay%"=="y" echo echo --ca-native ^> %%HOMEPATH%%\.curlrc >> configured_tools.bat
	if /i "%createReplay%"=="y" echo echo --ssl-revoke-best-effort ^>^> %%HOMEPATH%%\.curlrc >> configured_tools.bat
) else (
    echo %GRY%cURL is not installed%RST%
)

echo.
set REQUESTS_CA_BUNDLE=
for /f "tokens=*" %%P in ('python -m requests') do (
    if "%%P"=="built on:" set REQUESTS_CA_BUNDLE=%%P
)
if "%REQUESTS_CA_BUNDLE%"=="%certDir%\%certName%" (
    echo %YLW%Python Requests already configured%RST%
) else (
    setx REQUESTS_CA_BUNDLE "%certDir%\%certName%"
    echo %GRN%Python Requests configured%RST%
    if /i "%createReplay%"=="y" echo setx REQUESTS_CA_BUNDLE "%certDir%\%certName%" >> configured_tools.bat
)

echo.
call :command_exists aws
if %ERRORLEVEL% EQU 0 call :configure_tool aws "aws --version" "setx AWS_CA_BUNDLE" "setx AWS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists gcloud
if %ERRORLEVEL% EQU 0 (
    echo %GRN%Google Cloud CLI is installed%RST%
    gcloud --version
    gcloud config set core/custom_ca_certs_file %certDir%\%certName%
    echo %GRN%Google Cloud CLI configured%RST%
    if /i "%createReplay%"=="y" echo gcloud config set core/custom_ca_certs_file %certDir%\%certName% >> configured_tools.bat
) else (
    echo %GRY%Google Cloud CLI is not installed%RST%
)

echo.
call :command_exists npm
if %ERRORLEVEL% EQU 0 (
    echo %GRN%NodeJS Package Manager (NPM) is installed%RST%
    npm --version
    npm config set cafile %certDir%\%certName%
    echo %GRN%NodeJS Package Manager (NPM) configured%RST%
    if /i "%createReplay%"=="y" echo npm config set cafile %certDir%\%certName% >> configured_tools.bat
) else (
    echo %GRY%NodeJS Package Manager (NPM) is not installed%RST%
)

echo.
call :command_exists node
if %ERRORLEVEL% EQU 0 call :configure_tool node "node --version" "setx NODE_EXTRA_CA_CERTS" "setx NODE_EXTRA_CA_CERTS %certDir%\%certName%"

echo.
call :command_exists ruby
if %ERRORLEVEL% EQU 0 call :configure_tool ruby "ruby --version" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists composer
if %ERRORLEVEL% EQU 0 (
    echo %GRN%PHP Composer is installed%RST%
    composer --version
    composer config --global cafile %certDir%\%certName%
    echo %GRN%PHP Composer configured%RST%
    if /i "%createReplay%"=="y" echo composer config --global cafile %certDir%\%certName% >> configured_tools.bat
) else (
    echo %GRY%PHP Composer is not installed%RST%
)

echo.
call :command_exists go
if %ERRORLEVEL% EQU 0 call :configure_tool go "go --version" "setx SSL_CERT_FILE" "setx SSL_CERT_FILE %certDir%\%certName%"

echo.
call :command_exists az
if %ERRORLEVEL% EQU 0 call :configure_tool az "az --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists pip
if %ERRORLEVEL% EQU 0 call :configure_tool pip "pip --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists oci
if %ERRORLEVEL% EQU 0 call :configure_tool oci "oci --version" "setx REQUESTS_CA_BUNDLE" "setx REQUESTS_CA_BUNDLE %certDir%\%certName%"

echo.
call :command_exists cargo
if %ERRORLEVEL% EQU 0 (
    echo %GRN%Cargo Package Manager is installed%RST%
    cargo --version
    set SSL_CERT_FILE=
    for /f "tokens=*" %%P in ('cargo --version') do (
        if "%%P"=="built on:" set SSL_CERT_FILE=%%P
    )
    if "%SSL_CERT_FILE%"=="%certDir%\%certName%" (
        echo %YLW%Cargo SSL_CERT_FILE already configured%RST%
    ) else (
        setx SSL_CERT_FILE "%certDir%\%certName%"
        if /i "%createReplay%"=="y" echo setx SSL_CERT_FILE "%certDir%\%certName%" >> configured_tools.bat
    )
    set GIT_SSL_CAINFO=
    for /f "tokens=*" %%P in ('cargo --version') do (
        if "%%P"=="built on:" set GIT_SSL_CAINFO=%%P
    )
    if "%GIT_SSL_CAINFO%"=="%certDir%\%certName%" (
        echo %YLW%Cargo GIT_SSL_CAINFO already configured%RST%
    ) else (
        setx GIT_SSL_CAINFO "%certDir%\%certName%"
        if /i "%createReplay%"=="y" echo setx GIT_SSL_CAINFO "%certDir%\%certName%" >> configured_tools.bat
    )
    echo %GRN%Cargo Package Manager configured%RST%
) else (
    echo %GRY%Cargo Package Manager is not installed%RST%
)

echo.
call :command_exists yarn
if %ERRORLEVEL% EQU 0 (
    echo %GRN%Yarn is installed%RST%
    yarn --version
    yarn config set cafile "%certDir%\%certName%"
    echo %GRN%Yarn configured%RST%
    if /i "%createReplay%"=="y" echo yarn config set cafile "%certDir%\%certName%" >> configured_tools.bat
) else (
    echo %GRY%Yarn is not installed%RST%
)

echo.
call :command_exists pnpm
if %ERRORLEVEL% EQU 0 (
    echo %GRN%pnpm is installed%RST%
    pnpm --version
    pnpm config set cafile "%certDir%\%certName%"
    echo %GRN%pnpm configured%RST%
    if /i "%createReplay%"=="y" echo pnpm config set cafile "%certDir%\%certName%" >> configured_tools.bat
) else (
    echo %GRY%pnpm is not installed%RST%
)

:: Java JDK
echo.
echo %CYN%Java installations:%RST%
powershell -NoProfile -Command "$storepass='changeit'; $certPath='%certDir%\%certName%'; $cwr='%certWasRecreated%'; $certText=Get-Content $certPath -Raw; $pemBlocks=[regex]::Matches($certText,'-----BEGIN CERTIFICATE-----[\s\S]*?-----END CERTIFICATE-----') | Select-Object -First 2; function Get-AllJDKs { $found=@{}; function Add-JDK($home,$label){ if(-not $home -or -not (Test-Path $home)){return}; $kt=Join-Path $home 'bin\keytool.exe'; if((Test-Path $kt)-and-not $found.Contains($home.ToLower())){ $found[$home.ToLower()]=@($home,$label) } }; if($env:JAVA_HOME){Add-JDK $env:JAVA_HOME 'JAVA_HOME'}; $ktCmd=Get-Command keytool -ErrorAction SilentlyContinue; if($ktCmd){Add-JDK (Split-Path (Split-Path $ktCmd.Source)) 'PATH'}; @('HKLM:\SOFTWARE\JavaSoft\JDK','HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK')|ForEach-Object{ if(Test-Path $_){ Get-ChildItem $_ -ErrorAction SilentlyContinue|ForEach-Object{ $jh=(Get-ItemProperty $_.PSPath -Name JavaHome -ErrorAction SilentlyContinue).JavaHome; if($jh){Add-JDK $jh ('Registry ('+$_.PSChildName+')')} } } }; @('Java','Eclipse Adoptium','Amazon Corretto','Zulu','Microsoft')|ForEach-Object{ $p=Join-Path $env:ProgramFiles $_; if(Test-Path $p){ Get-ChildItem $p -Directory -ErrorAction SilentlyContinue|ForEach-Object{ Add-JDK $_.FullName ('Common ('+$_.Name+')') } } }; return $found.Values }; $allJDKs=@(Get-AllJDKs); if($allJDKs.Count -eq 0){ Write-Host '  No Java installations found' -ForegroundColor DarkGray } else { foreach($entry in $allJDKs){ $home=$entry[0]; $label=$entry[1]; Write-Host ('  ['+$label+'] '+$home) -ForegroundColor Cyan; $cacerts=Join-Path $home 'lib\security\cacerts'; if(-not(Test-Path $cacerts)){ $cacerts=Join-Path $home 'jre\lib\security\cacerts' }; if(-not(Test-Path $cacerts)){ Write-Host '    cacerts: not found' -ForegroundColor Yellow; continue }; $keytool=Join-Path $home 'bin\keytool.exe'; for($i=0;$i -lt $pemBlocks.Count;$i++){ $alias='netskope-'+$i; & $keytool -list -alias $alias -keystore $cacerts -storepass $storepass *>$null; if($LASTEXITCODE -eq 0){ if($cwr -ne '1'){ Write-Host ('    keytool alias '+$alias+': already configured') -ForegroundColor Yellow } else { Write-Host ('    keytool alias '+$alias+': removing stale entry to re-import') -ForegroundColor Yellow; & $keytool -delete -alias $alias -keystore $cacerts -storepass $storepass *>$null } }; if($LASTEXITCODE -ne 0 -or $cwr -eq '1'){ $tmp=[IO.Path]::GetTempFileName()+'.pem'; try { [IO.File]::WriteAllText($tmp,$pemBlocks[$i].Value); & $keytool -import -trustcacerts -noprompt -alias $alias -file $tmp -keystore $cacerts -storepass $storepass *>$null; if($LASTEXITCODE -eq 0){ Write-Host ('    keytool alias '+$alias+': configured') -ForegroundColor Green } else { Write-Host ('    keytool alias '+$alias+': failed') -ForegroundColor Red } } catch [System.UnauthorizedAccessException]{ Write-Host '    keytool: access denied - rerun as Administrator' -ForegroundColor Red } finally { if(Test-Path $tmp){ Remove-Item $tmp -Force } } } } } }"

:: VS Code
echo.
echo %CYN%VS Code:%RST%
powershell -NoProfile -Command "@(@{Dir=($env:APPDATA+'\Code\User');Edition='VS Code'},@{Dir=($env:APPDATA+'\Code - Insiders\User');Edition='VS Code Insiders'})|ForEach-Object{ $dir=$_.Dir; $edition=$_.Edition; $sf=Join-Path $dir 'settings.json'; if(-not(Test-Path $dir)){return}; try{ if(Test-Path $sf){ $s=Get-Content $sf -Raw|ConvertFrom-Json } else { $s=New-Object PSObject }; if($s.PSObject.Properties['http.systemCertificates'] -and $s.'http.systemCertificates' -eq $true){ Write-Host ('  '+$edition+': already configured') -ForegroundColor Yellow } else { $s|Add-Member -NotePropertyName 'http.systemCertificates' -NotePropertyValue $true -Force; $s|ConvertTo-Json -Depth 10|Set-Content $sf -Encoding UTF8; Write-Host ('  '+$edition+': configured') -ForegroundColor Green } } catch { Write-Host ('  '+$edition+': failed - '+$_) -ForegroundColor Red } }; if(-not(Test-Path ($env:APPDATA+'\Code\User'))-and-not(Test-Path ($env:APPDATA+'\Code - Insiders\User'))){ Write-Host '  VS Code is not installed' -ForegroundColor DarkGray }"

:: .NET / NuGet
echo.
echo %CYN%.NET / NuGet:%RST%
set dotnetFound=0
where dotnet >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   %GRN%dotnet is installed%RST% - covered by Windows Certificate Store
    if /i "%createReplay%"=="y" echo # dotnet: covered by Windows Certificate Store >> configured_tools.bat
    set dotnetFound=1
)
where nuget >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   %GRN%nuget is installed%RST% - covered by Windows Certificate Store
    if /i "%createReplay%"=="y" echo # nuget: covered by Windows Certificate Store >> configured_tools.bat
    set dotnetFound=1
)
if "%dotnetFound%"=="0" echo   %GRY%.NET / NuGet is not installed%RST%

:: Docker Desktop
echo.
echo %CYN%Docker Desktop:%RST%
set dockerInstalled=0
where docker >NUL 2>&1
if %ERRORLEVEL% EQU 0 set dockerInstalled=1
if "%dockerInstalled%"=="0" if exist "%LOCALAPPDATA%\Docker\Desktop" set dockerInstalled=1
if "%dockerInstalled%"=="0" (
    echo   %GRY%Docker is not installed%RST%
    goto :after_docker
)
fc /b "%USERPROFILE%\.docker\ca.pem" "%certDir%\%certName%" >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    echo   %YLW%already configured%RST%
    goto :after_docker
)
if not exist "%USERPROFILE%\.docker" mkdir "%USERPROFILE%\.docker"
copy /y "%certDir%\%certName%" "%USERPROFILE%\.docker\ca.pem" >NUL
echo   %GRN%configured (%USERPROFILE%\.docker\ca.pem)%RST%
echo   %YLW%Note: restart Docker Desktop to apply changes%RST%
if /i "%createReplay%"=="y" echo copy /y "%certDir%\%certName%" "%USERPROFILE%\.docker\ca.pem" >> configured_tools.bat
:after_docker

echo.
echo %GRN%Done.%RST%
goto :eof

:: ─── Rollback ─────────────────────────────────────────────────────────────────
:do_rollback
echo.
echo %CYN%Netskope SSL Rollback%RST%
echo Removing Netskope SSL configuration from all tools...

:: Environment variables
echo.
echo %CYN%--- Environment Variables ---%RST%
for %%V in (SSL_CERT_FILE AWS_CA_BUNDLE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE GIT_SSL_CAINFO GIT_SSL_CAPATH) do (
    reg delete "HKCU\Environment" /v %%V /f >NUL 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo   %GRN%%%V: removed%RST%
    ) else (
        echo   %GRY%%%V: not set%RST%
    )
)

:: Git
echo.
echo %CYN%--- Git ---%RST%
where git >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    git config --global --unset http.sslCAInfo >NUL 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo   %GRN%git http.sslCAInfo: unset%RST%
    ) else (
        echo   %YLW%git http.sslCAInfo: not configured%RST%
    )
) else (
    echo   %GRY%Git is not installed%RST%
)

:: .curlrc
echo.
echo %CYN%--- cURL ---%RST%
if exist "%HOMEPATH%\.curlrc" (
    del /f /q "%HOMEPATH%\.curlrc" >NUL 2>&1
    echo   %GRN%.curlrc deleted%RST%
) else (
    echo   %GRY%.curlrc not found%RST%
)

:: Google Cloud CLI
echo.
echo %CYN%--- Google Cloud CLI ---%RST%
where gcloud >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    gcloud config unset core/custom_ca_certs_file >NUL 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo   %GRN%gcloud: custom_ca_certs_file unset%RST%
    ) else (
        echo   %YLW%gcloud: not configured%RST%
    )
) else (
    echo   %GRY%gcloud is not installed%RST%
)

:: NPM
echo.
echo %CYN%--- NPM ---%RST%
where npm >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    npm config delete cafile >NUL 2>&1
    echo   %GRN%npm cafile: deleted%RST%
) else (
    echo   %GRY%npm is not installed%RST%
)

:: PHP Composer
echo.
echo %CYN%--- PHP Composer ---%RST%
where composer >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    composer config --global --unset cafile >NUL 2>&1
    if %ERRORLEVEL% EQU 0 (
        echo   %GRN%composer cafile: unset%RST%
    ) else (
        echo   %YLW%composer: cafile not configured%RST%
    )
) else (
    echo   %GRY%composer is not installed%RST%
)

:: Yarn
echo.
echo %CYN%--- Yarn ---%RST%
where yarn >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    yarn config delete httpsCaFilePath >NUL 2>&1
    if %ERRORLEVEL% NEQ 0 yarn config delete cafile >NUL 2>&1
    echo   %GRN%yarn: cafile config removed%RST%
) else (
    where yarnpkg >NUL 2>&1
    if %ERRORLEVEL% EQU 0 (
        yarnpkg config delete httpsCaFilePath >NUL 2>&1
        if %ERRORLEVEL% NEQ 0 yarnpkg config delete cafile >NUL 2>&1
        echo   %GRN%yarnpkg: cafile config removed%RST%
    ) else (
        echo   %GRY%yarn is not installed%RST%
    )
)

:: pnpm
echo.
echo %CYN%--- pnpm ---%RST%
where pnpm >NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    pnpm config delete cafile >NUL 2>&1
    echo   %GRN%pnpm: cafile config removed%RST%
) else (
    echo   %GRY%pnpm is not installed%RST%
)

:: Java keytool
echo.
echo %CYN%--- Java ---%RST%
powershell -NoProfile -Command "$storepass='changeit'; function Get-AllJDKs { $found=@{}; function Add-JDK($jdkPath,$label){ if(-not $jdkPath -or -not (Test-Path $jdkPath)){return}; $kt=Join-Path $jdkPath 'bin\keytool.exe'; if((Test-Path $kt)-and-not $found.Contains($jdkPath.ToLower())){ $found[$jdkPath.ToLower()]=@($jdkPath,$label) } }; if($env:JAVA_HOME){Add-JDK $env:JAVA_HOME 'JAVA_HOME'}; $ktCmd=Get-Command keytool -ErrorAction SilentlyContinue; if($ktCmd){Add-JDK (Split-Path (Split-Path $ktCmd.Source)) 'PATH'}; @('HKLM:\SOFTWARE\JavaSoft\JDK','HKLM:\SOFTWARE\WOW6432Node\JavaSoft\JDK')|ForEach-Object{ if(Test-Path $_){ Get-ChildItem $_ -ErrorAction SilentlyContinue|ForEach-Object{ $jh=(Get-ItemProperty $_.PSPath -Name JavaHome -ErrorAction SilentlyContinue).JavaHome; if($jh){Add-JDK $jh ('Registry ('+$_.PSChildName+')')} } } }; @('Java','Eclipse Adoptium','Amazon Corretto','Zulu','Microsoft')|ForEach-Object{ $p=Join-Path $env:ProgramFiles $_; if(Test-Path $p){ Get-ChildItem $p -Directory -ErrorAction SilentlyContinue|ForEach-Object{ Add-JDK $_.FullName ('Common ('+$_.Name+')') } } }; return $found.Values }; $allJDKs=@(Get-AllJDKs); if($allJDKs.Count -eq 0){ Write-Host '  No Java installations found' -ForegroundColor DarkGray } else { foreach($entry in $allJDKs){ $jdkHome=$entry[0]; $label=$entry[1]; Write-Host ('  ['+$label+'] '+$jdkHome) -ForegroundColor Cyan; $cacerts=Join-Path $jdkHome 'lib\security\cacerts'; if(-not(Test-Path $cacerts)){ $cacerts=Join-Path $jdkHome 'jre\lib\security\cacerts' }; if(-not(Test-Path $cacerts)){ Write-Host '    cacerts: not found' -ForegroundColor Yellow; continue }; $keytool=Join-Path $jdkHome 'bin\keytool.exe'; for($i=0;$i -lt 2;$i++){ $alias='netskope-'+$i; & $keytool -delete -alias $alias -keystore $cacerts -storepass $storepass *>$null; if($LASTEXITCODE -eq 0){ Write-Host ('    keytool alias '+$alias+': removed') -ForegroundColor Green } else { Write-Host ('    keytool alias '+$alias+': not found') -ForegroundColor DarkGray } } } }"

:: VS Code
echo.
echo %CYN%--- VS Code ---%RST%
powershell -NoProfile -Command "$found=$false; @(@{Dir=($env:APPDATA+'\Code\User');Edition='VS Code'},@{Dir=($env:APPDATA+'\Code - Insiders\User');Edition='VS Code Insiders'})|ForEach-Object{ $dir=$_.Dir; $edition=$_.Edition; if(-not(Test-Path $dir)){return}; $found=$true; $sf=Join-Path $dir 'settings.json'; if(-not(Test-Path $sf)){ Write-Host ('  '+$edition+': settings.json not found') -ForegroundColor DarkGray; return }; try{ $s=Get-Content $sf -Raw|ConvertFrom-Json; if($s.PSObject.Properties['http.systemCertificates']){ $s.PSObject.Properties.Remove('http.systemCertificates'); $s|ConvertTo-Json -Depth 10|Set-Content $sf -Encoding UTF8; Write-Host ('  '+$edition+': http.systemCertificates removed') -ForegroundColor Green } else { Write-Host ('  '+$edition+': http.systemCertificates not configured') -ForegroundColor Yellow } } catch { Write-Host ('  '+$edition+': failed - '+$_) -ForegroundColor Red } }; if(-not $found){ Write-Host '  VS Code is not installed' -ForegroundColor DarkGray }"

:: Windows Certificate Store
echo.
echo %CYN%--- Windows Certificate Store ---%RST%
powershell -NoProfile -Command "$removed=0; @(Get-ChildItem Cert:\LocalMachine\Root, Cert:\CurrentUser\Root -ErrorAction SilentlyContinue) | Where-Object { $_.Subject -match 'Netskope' -or $_.Issuer -match 'Netskope' } | ForEach-Object { $loc=if($_.PSParentPath -match 'LocalMachine'){'LocalMachine'}else{'CurrentUser'}; try { $s=New-Object System.Security.Cryptography.X509Certificates.X509Store([System.Security.Cryptography.X509Certificates.StoreName]::Root,[System.Security.Cryptography.X509Certificates.StoreLocation]::$loc); $s.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite); $s.Remove($_); $s.Close(); Write-Host ('  removed: '+$_.Subject) -ForegroundColor Green; $removed++ } catch { Write-Host ('  failed to remove: '+$_.Subject+' - '+$_) -ForegroundColor Red } }; if($removed -eq 0){ Write-Host '  no Netskope certificates found in store' -ForegroundColor DarkGray }"

:: Docker Desktop
echo.
echo %CYN%--- Docker Desktop ---%RST%
if exist "%USERPROFILE%\.docker\ca.pem" (
    del /f /q "%USERPROFILE%\.docker\ca.pem" >NUL 2>&1
    echo   %GRN%Docker ca.pem removed%RST%
) else (
    echo   %GRY%Docker ca.pem not found%RST%
)

echo.
echo %GRN%Rollback complete.%RST%
goto :eof

:: ─── Helpers ──────────────────────────────────────────────────────────────────

:: Parses one "key=value" or bare-flag argument for unattended deployment:
:: tenant-name=, org-key=, cert-dir=, cert-name=, cert-bundle=, recreate,
:: create-replay. Called once per %* argument from the top of the script.
:parse_arg
set "arg=%~1"
set "prefix=%arg:~0,12%"
if /i "%prefix%"=="tenant-name=" set "tenantName=%arg:~12%"
set "prefix=%arg:~0,8%"
if /i "%prefix%"=="org-key=" set "orgKey=%arg:~8%"
set "prefix=%arg:~0,9%"
if /i "%prefix%"=="cert-dir=" set "certDir=%arg:~9%"
set "prefix=%arg:~0,10%"
if /i "%prefix%"=="cert-name=" set "certName=%arg:~10%"
set "prefix=%arg:~0,12%"
if /i "%prefix%"=="cert-bundle=" set "certBundle=%arg:~12%"
if /i "%arg%"=="recreate" set recreateFlag=1
if /i "%arg%"=="create-replay" set createReplayFlag=1
exit /b 0

:: Function to check if a command exists
:command_exists
where %1 > NUL 2>&1
if %ERRORLEVEL% EQU 0 (
    exit /b 0
) else (
    exit /b 1
)

:: Function to configure tools
:configure_tool
:: %1 - Tool name
:: %2 - Command to retrieve the current configuration
:: %3 - Command to set the new configuration
:: %4 - Command to log configuration
echo %GRN%%~1 is installed%RST%
if /i "%~1"=="openssl" (openssl version) else (%~1 --version)
set toolConfigured=0
for /f "tokens=*" %%P in ('%~2') do set toolConfigured=%%P
if "%toolConfigured%"=="%certDir%\%certName%" (
    echo %YLW%%~1 already configured%RST%
) else (
    %~3 "%certDir%\%certName%"
    echo %GRN%%~1 configured%RST%
    if /i "%createReplay%"=="y" echo %~4 >> configured_tools.bat
)
exit /b 0
:: How to add a new tool:
:: 1. Add a call to :command_exists followed by the tool name (e.g., "call :command_exists mytool").
:: 2. If the tool is found (ERRORLEVEL is 0), call :configure_tool with the following parameters:
::    - Tool name (e.g., "mytool")
::    - Command to retrieve the current configuration (e.g., "mytool config --global cafile")
::    - Command to set the new configuration (e.g., "mytool config --global cafile")
::    - Command to log configuration (e.g., "mytool config --global cafile %certDir%\%certName%" >> configured_tools.bat)
:: Example:
:: echo.
:: call :command_exists mytool
:: if %ERRORLEVEL% EQU 0 call :configure_tool mytool "mytool config --global cafile" "mytool config --global cafile" "mytool config --global cafile %certDir%\%certName%" >> configured_tools.bat
