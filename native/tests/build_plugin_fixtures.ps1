param([string]$OutDir = "$PSScriptRoot/../../test_artifacts/plugins")
$ErrorActionPreference = 'Stop'
$pluginRoot = [IO.Path]::GetFullPath("$PSScriptRoot/../plugin")
$ndkRoot = "$env:LOCALAPPDATA/Android/Sdk/ndk/28.2.13676358/toolchains/llvm/prebuilt/windows-x86_64/bin"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
foreach ($variant in @('valid','wrong_version','missing_symbol','init_failure','init_crash','wrong_abi','load_failure')) {
    $compiler = if ($variant -eq 'wrong_abi') { "$ndkRoot/x86_64-linux-android28-clang.cmd" } else { "$ndkRoot/aarch64-linux-android28-clang.cmd" }
    $defines = switch ($variant) {
        'wrong_version' { '-DFIXTURE_API=99' }
        'missing_symbol' { '-DFIXTURE_MISSING=1' }
        'init_failure' { '-DFIXTURE_FAIL=1' }
        'init_crash' { '-DFIXTURE_CRASH=1' }
        'load_failure' { '-DFIXTURE_LINK_FAILURE=1' }
        default { '-DFIXTURE_API=1' }
    }
    & $compiler -shared -fPIC -fvisibility=hidden '-Wl,-z,max-page-size=16384' $defines "-I$pluginRoot" "$PSScriptRoot/plugin_fixture.c" -o "$OutDir/$variant.so"
    if ($LASTEXITCODE -ne 0) { throw "Fixture build failed: $variant" }
}
[IO.File]::WriteAllText("$OutDir/invalid.so", 'This is not an ELF library.')
& "$ndkRoot/aarch64-linux-android28-clang++.cmd" -std=c++17 -static-libstdc++ "-I$pluginRoot" "$PSScriptRoot/plugin_host_test.cpp" "$pluginRoot/jlexa_backend_host.cpp" -ldl -o "$OutDir/plugin_host_test"
if ($LASTEXITCODE -ne 0) { throw 'Host test build failed' }
