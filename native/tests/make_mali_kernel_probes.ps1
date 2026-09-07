param([string]$OutputDirectory = 'artifacts/opencl-pixel/mali-kernels')
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$output = [System.IO.Path]::GetFullPath((Join-Path $repo $OutputDirectory))
if (-not $output.StartsWith($repo + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Generated kernels must stay within this repository.'
}
New-Item -ItemType Directory -Force $output | Out-Null
foreach ($bits in @(4, 6)) {
    $name = "mul_mv_q${bits}_k_f32.cl"
    $source = Join-Path $repo "native/whisper.cpp/ggml/src/ggml-opencl/kernels/$name"
    $text = [System.IO.File]::ReadAllText($source).Replace("`r`n", "`n")
    $needle = "#ifdef INTEL_GPU`n#define N_DST"
    if ([regex]::Matches($text, [regex]::Escape($needle)).Count -ne 1) {
        throw "Pinned kernel structure changed: $name"
    }
    $rows = if ($bits -eq 4) { 4 } else { 1 }
    $groups = if ($bits -eq 4) { 1 } else { 2 }
    $branch = "#if defined(MALI_GPU)`n#define N_DST $rows`n#define N_SIMDGROUP $groups`n#define N_SIMDWIDTH 16`n#elif defined(INTEL_GPU)`n#define N_DST"
    $text = $text.Replace($needle, $branch)
    [System.IO.File]::WriteAllText((Join-Path $output $name), $text, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Generated $name with an explicit Mali subgroup-16 branch."
}
