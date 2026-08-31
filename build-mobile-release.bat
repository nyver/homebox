@echo off
setlocal EnableExtensions DisableDelayedExpansion

set "PROJECT_ROOT=%~dp0"
set "CLIENT_DIR=%PROJECT_ROOT%client"
set "ANDROID_DIR=%CLIENT_DIR%\android"
set "KEYSTORE_PATH=%ANDROID_DIR%\homebox-release.jks"
set "SIGNING_SECRETS=%ANDROID_DIR%\release-signing.local.bat"
set "APK_PATH=%CLIENT_DIR%\build\app\outputs\flutter-apk\app-release.apk"
set "KEY_ALIAS=homebox-release"

if not exist "%CLIENT_DIR%\pubspec.yaml" (
    echo ERROR: Flutter client was not found at "%CLIENT_DIR%".
    goto :failure
)

set "KEYTOOL="
for /f "delims=" %%K in ('where.exe keytool.exe 2^>nul') do if not defined KEYTOOL set "KEYTOOL=%%K"
if not defined KEYTOOL if defined JAVA_HOME if exist "%JAVA_HOME%\bin\keytool.exe" set "KEYTOOL=%JAVA_HOME%\bin\keytool.exe"
if not defined KEYTOOL (
    echo ERROR: keytool.exe was not found. Install JDK 17 or newer and add its bin directory to PATH.
    goto :failure
)

where.exe flutter.bat >nul 2>&1
if errorlevel 1 (
    echo ERROR: flutter.bat was not found in PATH.
    goto :failure
)

if exist "%KEYSTORE_PATH%" if not exist "%SIGNING_SECRETS%" (
    echo ERROR: The release keystore exists, but its local password file is missing:
    echo        "%SIGNING_SECRETS%"
    echo Restore that file from a secure backup. Replacing the key would prevent app updates.
    goto :failure
)

if not exist "%SIGNING_SECRETS%" (
    echo Creating local Android signing credentials...
    setlocal EnableDelayedExpansion
    set "GENERATED_PASSWORD="
    for /f "usebackq delims=" %%P in (`powershell.exe -NoProfile -Command "$b=New-Object byte[] 32;$r=[Security.Cryptography.RandomNumberGenerator]::Create();$r.GetBytes($b);$r.Dispose();$h=[BitConverter]::ToString($b);$h.Replace('-','').ToLowerInvariant()"`) do set "GENERATED_PASSWORD=%%P"
    if not defined GENERATED_PASSWORD (
        endlocal
        echo ERROR: Could not generate a signing password.
        goto :failure
    )
    >"%SIGNING_SECRETS%" echo @echo off
    >>"%SIGNING_SECRETS%" echo set "HOMEBOX_RELEASE_STORE_PASSWORD=!GENERATED_PASSWORD!"
    >>"%SIGNING_SECRETS%" echo set "HOMEBOX_RELEASE_KEY_PASSWORD=!GENERATED_PASSWORD!"
    >>"%SIGNING_SECRETS%" echo set "HOMEBOX_RELEASE_KEY_ALIAS=%KEY_ALIAS%"
    set "GENERATED_PASSWORD="
    endlocal
)

call "%SIGNING_SECRETS%"
set "HOMEBOX_RELEASE_STORE_FILE=%KEYSTORE_PATH%"
if not defined HOMEBOX_RELEASE_STORE_PASSWORD goto :invalid_credentials
if not defined HOMEBOX_RELEASE_KEY_PASSWORD goto :invalid_credentials
if not defined HOMEBOX_RELEASE_KEY_ALIAS goto :invalid_credentials

if not exist "%KEYSTORE_PATH%" (
    echo Creating the HomeBox Android release keystore...
    "%KEYTOOL%" -genkeypair -noprompt -keystore "%KEYSTORE_PATH%" -storetype PKCS12 -storepass "%HOMEBOX_RELEASE_STORE_PASSWORD%" -keypass "%HOMEBOX_RELEASE_KEY_PASSWORD%" -alias "%HOMEBOX_RELEASE_KEY_ALIAS%" -keyalg RSA -keysize 4096 -validity 10000 -dname "CN=HomeBox, OU=Mobile, O=HomeBox, L=Moscow, ST=Moscow, C=RU"
    if errorlevel 1 (
        echo ERROR: Keystore creation failed.
        goto :failure
    )
)

"%KEYTOOL%" -list -keystore "%KEYSTORE_PATH%" -storepass "%HOMEBOX_RELEASE_STORE_PASSWORD%" -alias "%HOMEBOX_RELEASE_KEY_ALIAS%" >nul 2>&1
if errorlevel 1 (
    echo ERROR: The local signing credentials do not unlock the release keystore.
    goto :failure
)

pushd "%CLIENT_DIR%"
echo Restoring Flutter dependencies...
call flutter.bat pub get
if errorlevel 1 (
    popd
    echo ERROR: flutter pub get failed.
    goto :failure
)

echo Building the signed Android release APK...
call flutter.bat build apk --release
if errorlevel 1 (
    popd
    echo ERROR: Android release build failed.
    goto :failure
)
popd

if not exist "%APK_PATH%" (
    echo ERROR: Flutter completed without producing "%APK_PATH%".
    goto :failure
)

echo.
echo Signed release APK created successfully:
echo "%APK_PATH%"
echo.
echo IMPORTANT: Back up both files below securely. Keep them private and never
echo replace them after distributing the app, or future APK updates will fail:
echo "%KEYSTORE_PATH%"
echo "%SIGNING_SECRETS%"

if /I not "%~1"=="--no-open" start "" explorer.exe /select,"%APK_PATH%"
goto :success

:invalid_credentials
echo ERROR: "%SIGNING_SECRETS%" is incomplete.
goto :failure

:failure
set "EXIT_CODE=1"
goto :finish

:success
set "EXIT_CODE=0"

:finish
if /I not "%~1"=="--no-open" pause
exit /b %EXIT_CODE%
