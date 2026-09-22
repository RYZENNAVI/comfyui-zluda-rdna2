# Shared detection helpers. Dot-source it: . .\Common.ps1

$ErrorActionPreference = 'Stop'

# Describe one HIP root. Returns $null when there is no bin directory.
function Get-HipInstall {
    param([Parameter(Mandatory)][string]$Root)

    $Root = $Root.TrimEnd('\')
    $bin = Join-Path $Root 'bin'
    if (-not (Test-Path $bin)) { return $null }

    # The HIP SDK installer sometimes skips the core runtime, leaving bin without
    # any amdhip64*.dll. Report that honestly instead of pretending it installed.
    $rt = Get-ChildItem $bin -Filter 'amdhip64*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1

    [pscustomobject]@{
        Version    = Split-Path $Root -Leaf
        Root       = $Root
        Bin        = $bin
        RocBlasLib = Join-Path $bin 'rocblas\library'
        Runtime    = if ($rt) { $rt.Name } else { $null }
    }
}

# Every HIP install found, newest version first.
function Get-HipInstalls {
    $roots = New-Object System.Collections.Generic.List[string]

    foreach ($v in 'HIP_PATH', 'HIP_PATH_57', 'HIP_PATH_61', 'HIP_PATH_62', 'HIP_PATH_63', 'HIP_PATH_64', 'HIP_PATH_70') {
        foreach ($scope in 'Process', 'User', 'Machine') {
            $p = [Environment]::GetEnvironmentVariable($v, $scope)
            if ($p) { $roots.Add($p) }
        }
    }

    foreach ($base in @("$env:ProgramFiles\AMD\ROCm", "${env:ProgramFiles(x86)}\AMD\ROCm")) {
        if (Test-Path $base) {
            Get-ChildItem $base -Directory | ForEach-Object { $roots.Add($_.FullName) }
        }
    }

    $seen = @{}
    $out = foreach ($r in $roots) {
        $key = $r.TrimEnd('\').ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        Get-HipInstall -Root $r
    }

    $out | Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending
}

# ZLUDA's nvcuda.dll hardcodes amdhip64_6.dll or _7 in its import table; a
# mismatch is a bare 0xC0000135. Read the PE to find out which one it wants.
function Get-ZludaHipRequirement {
    param([Parameter(Mandatory)][string]$NvcudaPath)

    if (-not (Test-Path $NvcudaPath)) { return $null }
    $bytes = [System.IO.File]::ReadAllBytes($NvcudaPath)
    $text = [System.Text.Encoding]::ASCII.GetString($bytes)
    $m = [regex]::Matches($text, 'amdhip64(_\d+)?\.dll')
    if ($m.Count -eq 0) { return $null }
    $m[0].Value
}

# Locate ComfyUI: explicit hint, then upwards from the current directory,
# then the usual names at each drive root.
function Find-ComfyUIRoot {
    param([string]$Hint)

    $cands = New-Object System.Collections.Generic.List[string]
    if ($Hint) { $cands.Add($Hint) }

    $d = (Get-Location).Path
    while ($d) {
        $cands.Add($d)
        $d = Split-Path $d -Parent
    }

    foreach ($drive in (Get-PSDrive -PSProvider FileSystem).Root) {
        foreach ($name in 'ComfyUI-Zluda', 'ComfyUI') {
            $cands.Add((Join-Path $drive $name))
        }
    }

    foreach ($c in $cands) {
        if (Test-Path (Join-Path $c 'comfy\ldm\modules\attention.py')) { return (Resolve-Path $c).Path }
    }
    $null
}

# The ZLUDA DLL directory inside a ComfyUI install.
function Find-ZludaDir {
    param([Parameter(Mandatory)][string]$ComfyUIRoot)

    $nv = Get-ChildItem $ComfyUIRoot -Recurse -Filter 'nvcuda.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($nv) { return (Split-Path $nv.FullName -Parent) }
    $null
}

# Python 3.8+ no longer searches PATH for extension-module dependencies, so these
# have to sit in torch\lib under the names torch asks for. Note what is absent:
# cublasLt64_11.dll stays NVIDIA's own build, and nvcuda.dll is injected by
# zluda.exe rather than copied. Overwriting either one breaks the install.
function Get-TorchDllMap {
    @{
        'cublas.dll'   = 'cublas64_11.dll'
        'cusparse.dll' = 'cusparse64_11.dll'
        'cufft.dll'    = 'cufft64_10.dll'
        'nvrtc.dll'    = 'nvrtc64_112_0.dll'
    }
}

function Get-AmdGpuNames {
    Get-CimInstance Win32_VideoController |
        Where-Object { $_.Name -match 'AMD|Radeon' } |
        Select-Object -ExpandProperty Name
}

# This project targets gfx1030: the Navi 21 desktop parts. RX 6800M and
# RX 6850M XT are Navi 22 despite the model number, so exclude mobile suffixes.
function Test-IsGfx1030 {
    param([string[]]$GpuNames)
    [bool]($GpuNames | Where-Object { $_ -match '6950|6900|6800' -and $_ -notmatch '6800M|6800S|6850M' })
}

# Windows does not reap children when the parent dies. zluda.exe injects via
# Detours and keeps python underneath it, so pull up the whole tree.
function Stop-ProcessTree {
    param([Parameter(Mandatory)][int]$Id)

    $kids = Get-CimInstance Win32_Process -Filter "ParentProcessId=$Id" -ErrorAction SilentlyContinue
    foreach ($k in $kids) { Stop-ProcessTree -Id $k.ProcessId }
    Stop-Process -Id $Id -Force -ErrorAction SilentlyContinue
}
