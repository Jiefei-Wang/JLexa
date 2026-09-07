param(
    [string[]]$Sources,
    [string]$OutputDirectory = 'artifacts/whisper-range/probe'
)
$ErrorActionPreference = 'Stop'
$java = 'C:/Program Files/Android/Android Studio/jbr/bin/java.exe'
$sdk = "$env:LOCALAPPDATA/Android/Sdk"
$cache = "$env:USERPROFILE/.gradle/caches/modules-2/files-2.1"
function Find-Jar([string]$group, [string]$name, [string]$version) {
    return (Get-ChildItem "$cache/$group/$name/$version" -Recurse -Filter '*.jar' | Select-Object -First 1).FullName
}
$stdlib = Find-Jar 'org.jetbrains.kotlin' 'kotlin-stdlib' '2.2.21'
$compilerJars = @(
    (Find-Jar 'org.jetbrains.kotlin' 'kotlin-compiler-embeddable' '2.2.21'),
    $stdlib,
    (Find-Jar 'org.jetbrains.kotlin' 'kotlin-reflect' '2.2.21'),
    (Find-Jar 'org.jetbrains.kotlin' 'kotlin-script-runtime' '2.2.21'),
    (Find-Jar 'org.jetbrains.kotlin' 'kotlin-daemon-embeddable' '2.2.21'),
    (Find-Jar 'org.jetbrains.intellij.deps' 'trove4j' '1.0.20200330'),
    (Find-Jar 'org.jetbrains' 'annotations' '23.0.0'),
    (Find-Jar 'org.jetbrains.kotlinx' 'kotlinx-coroutines-core-jvm' '1.8.0')
)
$android = "$sdk/platforms/android-36/android.jar"
New-Item -ItemType Directory -Force $OutputDirectory | Out-Null
& $java -cp ($compilerJars -join ';') org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect -jvm-target 11 -classpath "$stdlib;$android" -d "$OutputDirectory/probe.jar" @Sources
if ($LASTEXITCODE -ne 0) { throw 'Kotlin probe compilation failed' }
& $java -cp "$sdk/build-tools/36.0.0/lib/d8.jar" com.android.tools.r8.D8 --min-api 28 --lib $android --output $OutputDirectory "$OutputDirectory/probe.jar" $stdlib
if ($LASTEXITCODE -ne 0) { throw 'D8 probe compilation failed' }
