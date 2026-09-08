param([switch]$Baseline, [switch]$Whisper, [int]$Jobs = 8)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path "$PSScriptRoot/../..").Path
$sdkRoot = "$env:LOCALAPPDATA/Android/Sdk"
$ndkRoot = "$sdkRoot/ndk/28.2.13676358"
$cmakeExe = "$sdkRoot/cmake/3.22.1/bin/cmake.exe"
$variant = if ($Baseline) { 'baseline' } else { 'optimized' }
$buildRoot = "$PSScriptRoot/build/$variant"
$enabled = if ($Baseline) { 'OFF' } else { 'ON' }
& $cmakeExe -S $PSScriptRoot -B $buildRoot -G Ninja `
  "-DCMAKE_MAKE_PROGRAM=$sdkRoot/cmake/3.22.1/bin/ninja.exe" `
  "-DCMAKE_TOOLCHAIN_FILE=$ndkRoot/build/cmake/android.toolchain.cmake" `
  '-DANDROID_ABI=arm64-v8a' '-DANDROID_PLATFORM=android-28' `
  '-DANDROID_STL=c++_static' '-DCMAKE_BUILD_TYPE=Release' `
  "-DJLEXA_SNAPDRAGON_OPTIMIZED=$enabled"
if ($LASTEXITCODE) { throw 'Configure failed' }
$target = if ($Whisper) { 'jlexa_whisper_cpu' } else { 'jlexa_snapdragon' }
& $cmakeExe --build $buildRoot --target $target -j $Jobs
if ($LASTEXITCODE) { throw 'Build failed' }
$artifactName = if ($Baseline) { 'jlexa-arm64-baseline-plugin.so' } else { 'jlexa-snapdragon-plugin.so' }
if ($Whisper) { $artifactName = if ($Baseline) { 'jlexa-whisper-baseline-plugin.so' } else { 'jlexa-whisper-snapdragon-plugin.so' } }
$outputPath = "$repoRoot/release/$artifactName"
Copy-Item -LiteralPath "$buildRoot/lib$target.so" -Destination $outputPath -Force
& "$ndkRoot/toolchains/llvm/prebuilt/windows-x86_64/bin/llvm-strip.exe" --strip-unneeded $outputPath
if ($LASTEXITCODE) { throw 'Strip failed' }
Get-FileHash -Algorithm SHA256 -LiteralPath $outputPath
