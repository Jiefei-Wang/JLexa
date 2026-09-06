<#
.SYNOPSIS
    Automated Android testing script for JLexa on Windows.
    Discovers/provisions the Android emulator, waits for boot completion,
    executes static analysis, unit/widget tests, builds the debug APK,
    and runs on-device Flutter integration tests.

.PARAMETER AvdName
    Name of the Android Virtual Device (AVD) to use or create.
    Defaults to "JLexa_Test_AVD".

.PARAMETER SdkPath
    Path to Android SDK directory.

.PARAMETER Headless
    Runs the emulator in headless mode (-no-window).

.PARAMETER SkipEmulator
    Skips starting the emulator if a physical device or emulator is already connected.

.PARAMETER EmulatorTimeoutSeconds
    Timeout in seconds to wait for Android emulator boot completion.

.PARAMETER ArtifactsDir
    Directory to save screenshots and logcat dumps upon failure.
#>

[CmdletBinding()]
param(
    [string]$AvdName = "JLexa_Test_AVD",
    [string]$SdkPath = "",
    [switch]$Headless = $false,
    [switch]$SkipEmulator = $false,
    [int]$EmulatorTimeoutSeconds = 180,
    [string]$ArtifactsDir = "test_artifacts"
)

$ErrorActionPreference = "Stop"

function Write-Header([string]$text) {
    Write-Host "`n========================================================" -ForegroundColor Cyan
    Write-Host "  $text" -ForegroundColor Cyan
    Write-Host "========================================================`n" -ForegroundColor Cyan
}

function Write-Success([string]$text) {
    Write-Host "[SUCCESS] $text" -ForegroundColor Green
}

function Write-Info([string]$text) {
    Write-Host "[INFO] $text" -ForegroundColor Yellow
}

function Write-Err([string]$text) {
    Write-Host "[ERROR] $text" -ForegroundColor Red
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$AppDir = Join-Path $ProjectRoot "app"

Write-Header "JLexa Automated Android Test Runner"
Write-Info "Project Root: $ProjectRoot"
Write-Info "App Directory: $AppDir"

# 1. Resolve Android SDK and Java
if (-not $SdkPath) {
    if ($env:ANDROID_HOME -and (Test-Path $env:ANDROID_HOME)) {
        $SdkPath = $env:ANDROID_HOME
    } elseif ($env:ANDROID_SDK_ROOT -and (Test-Path $env:ANDROID_SDK_ROOT)) {
        $SdkPath = $env:ANDROID_SDK_ROOT
    } elseif (Test-Path "$env:LOCALAPPDATA\Android\Sdk") {
        $SdkPath = "$env:LOCALAPPDATA\Android\Sdk"
    } else {
        Write-Err "Could not locate Android SDK directory. Please specify -SdkPath."
        exit 1
    }
}
Write-Info "Using Android SDK at: $SdkPath"

if (-not $env:JAVA_HOME) {
    $StudioJbr = "C:\Program Files\Android\Android Studio\jbr"
    if (Test-Path $StudioJbr) {
        $env:JAVA_HOME = $StudioJbr
        Write-Info "Set JAVA_HOME to Android Studio JBR: $StudioJbr"
    }
}

$AdbBin = Join-Path $SdkPath "platform-tools\adb.exe"
if (-not (Test-Path $AdbBin)) {
    $AdbCmd = Get-Command adb -ErrorAction SilentlyContinue
    if ($AdbCmd) { $AdbBin = $AdbCmd.Source } else {
        Write-Err "Could not find adb.exe."
        exit 1
    }
}

$EmulatorBin = Join-Path $SdkPath "emulator\emulator.exe"
$SdkManagerBin = Join-Path $SdkPath "cmdline-tools\latest\bin\sdkmanager.bat"
$AvdManagerBin = Join-Path $SdkPath "cmdline-tools\latest\bin\avdmanager.bat"

# 2. Check Device / Emulator Status
Write-Header "Checking Device / Emulator Status"

$startedEmulatorProcess = $null
$connectedDevice = ""

# Check if adb is running and devices are already attached
$adbDevicesOutput = & $AdbBin devices
$attachedDevices = @()
foreach ($line in ($adbDevicesOutput -split "`r?`n")) {
    if ($line -match "^(\S+)\s+device$") {
        $attachedDevices += $Matches[1]
    }
}

if ($attachedDevices.Count -gt 0) {
    $connectedDevice = $attachedDevices[0]
    Write-Success "Found already connected Android device/emulator: $connectedDevice"
} elseif ($SkipEmulator) {
    Write-Err "No connected Android devices found and -SkipEmulator was specified."
    exit 1
} else {
    # Ensure AVD exists
    $targetAvd = $AvdName
    $availableAvds = & $EmulatorBin -list-avds
    $avdList = @($availableAvds | Where-Object { $_.Trim().Length -gt 0 })

    if ($avdList -notcontains $targetAvd) {
        Write-Info "AVD '$targetAvd' not found. Creating AVD..."
        $cmdCreate = "echo no | `"$AvdManagerBin`" create avd -n $targetAvd -k `"system-images;android-34;google_apis;x86_64`" --force"
        cmd.exe /c $cmdCreate
    }

    Write-Info "Booting Android emulator with AVD: $targetAvd..."
    $emuArgs = @("-avd", $targetAvd, "-no-snapshot-save", "-no-audio", "-gpu", "swiftshader_indirect")
    if ($Headless) {
        $emuArgs += @("-no-window", "-no-boot-anim")
    }

    $startedEmulatorProcess = Start-Process -FilePath $EmulatorBin -ArgumentList $emuArgs -PassThru
    Write-Info "Emulator process started (PID: $($startedEmulatorProcess.Id)). Waiting for device..."

    # Wait for adb to see device
    & $AdbBin wait-for-device
    Write-Info "Device attached to adb. Waiting for Android OS to complete booting..."

    $elapsed = 0
    $bootCompleted = $false
    while ($elapsed -lt $EmulatorTimeoutSeconds) {
        Start-Sleep -Seconds 3
        $elapsed += 3
        $prop = (& $AdbBin shell getprop sys.boot_completed 2>$null)
        if ($prop -and $prop.Trim() -eq "1") {
            $bootCompleted = $true
            break
        }
        Write-Host -NoNewline "."
    }
    Write-Host ""

    if (-not $bootCompleted) {
        Write-Err "Android emulator failed to complete boot within $EmulatorTimeoutSeconds seconds."
        if ($startedEmulatorProcess) { Stop-Process -Id $startedEmulatorProcess.Id -Force }
        exit 1
    }

    # Dismiss keyguard and awake screen
    & $AdbBin shell wm dismiss-keyguard 2>$null
    & $AdbBin shell input keyevent 82 2>$null

    # Identify device name
    $adbDevicesOutput = & $AdbBin devices
    foreach ($line in ($adbDevicesOutput -split "`r?`n")) {
        if ($line -match "^(emulator-\d+|\S+)\s+device$") {
            $connectedDevice = $Matches[1]
            break
        }
    }
    Write-Success "Emulator is online and ready: $connectedDevice"
}

function Capture-FailureArtifacts([string]$stepName) {
    try {
        $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
        $destDir = Join-Path $ProjectRoot (Join-Path $ArtifactsDir "${timestamp}_${stepName}")
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null

        Write-Info "Capturing failure artifacts to $destDir..."
        if ($connectedDevice) {
            # Screenshot
            & $AdbBin -s $connectedDevice exec-out screencap -p > (Join-Path $destDir "screenshot.png") 2>$null
            # Full Logcat
            & $AdbBin -s $connectedDevice logcat -d > (Join-Path $destDir "logcat_full.txt") 2>$null
            # Crash buffer
            & $AdbBin -s $connectedDevice logcat -b crash -d > (Join-Path $destDir "logcat_crash.txt") 2>$null
            # Native JLexa & llama.cpp logs
            & $AdbBin -s $connectedDevice logcat -d -s JLexaLlama:V JLexaJNI:V JLexaSpeech:V AndroidRuntime:E DEBUG:E > (Join-Path $destDir "logcat_jlexa.txt") 2>$null
        }
        Write-Success "Artifacts saved: $destDir"
    } catch {
        Write-Info "Could not capture artifacts: $_"
    }
}

# 3. Execute Automated Steps
try {
    # Step A: Flutter Pub Get
    Write-Header "Step 1/5: Fetching Flutter Dependencies"
    Push-Location $AppDir
    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed" }
    Pop-Location
    Write-Success "Dependencies resolved."

    # Step B: Static Analysis
    Write-Header "Step 2/5: Running Flutter Analyze"
    Push-Location $AppDir
    flutter analyze
    if ($LASTEXITCODE -ne 0) { throw "flutter analyze failed" }
    Pop-Location
    Write-Success "Analysis passed cleanly."

    # Step C: Unit and Widget Tests
    Write-Header "Step 3/5: Running Unit and Widget Tests"
    Push-Location $AppDir
    flutter test --concurrency=1
    if ($LASTEXITCODE -ne 0) { throw "flutter test failed" }
    Pop-Location
    Write-Success "All unit & widget tests passed."

    # Step D: Build Debug APK
    Write-Header "Step 4/5: Building Android Debug APK"
    Push-Location $AppDir
    flutter build apk --debug
    if ($LASTEXITCODE -ne 0) { throw "flutter build apk --debug failed" }
    Pop-Location
    Write-Success "Debug APK built successfully."

    # Step E: Run Integration Tests on Connected Emulator/Device
    Write-Header "Step 5/5: Running Flutter Integration Tests on Device ($connectedDevice)"
    Push-Location $AppDir
    if ($connectedDevice) {
        flutter test integration_test/model_settings_test.dart -d $connectedDevice
        if ($LASTEXITCODE -ne 0) { throw "Flutter model_settings_test integration test failed on $connectedDevice" }
        flutter test integration_test/native_inference_test.dart -d $connectedDevice
        if ($LASTEXITCODE -ne 0) { throw "Flutter native_inference_test integration test failed on $connectedDevice" }
    } else {
        flutter test integration_test/model_settings_test.dart
        if ($LASTEXITCODE -ne 0) { throw "Flutter model_settings_test integration test failed" }
        flutter test integration_test/native_inference_test.dart
        if ($LASTEXITCODE -ne 0) { throw "Flutter native_inference_test integration test failed" }
    }
    Pop-Location
    Write-Success "On-device integration tests passed!"

    Write-Header "All Android Automated Tests Passed Successfully!"
    exit 0
} catch {
    Write-Err "Automated Android Test Workflow failed: $_"
    Capture-FailureArtifacts "failure"
    exit 1
} finally {
    if ((Get-Location).Path -ne $ProjectRoot) {
        Set-Location $ProjectRoot
    }
}
