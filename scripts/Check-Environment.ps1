<#
.SYNOPSIS
Check every part of a gfx1030 + ZLUDA setup that commonly goes wrong.

.DESCRIPTION
Read-only. Reports what it finds and how to fix it. When something fails, look
the error up in docs\TROUBLESHOOTING.md.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.
#>
[CmdletBinding()]
param([string]$ComfyUIRoot)

. (Join-Path $PSScriptRoot 'Common.ps1')
$ErrorActionPreference = 'Continue'

$fail = 0
$warn = 0

function Ok   ($m) { Write-Host "  [ OK ] $m" -ForegroundColor Green }
function Warn ($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warn++ }
function Bad  ($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red;    $script:fail++ }
function Fix  ($m) { Write-Host "         -> $m" -ForegroundColor DarkGray }

Write-Host ""
Write-Host "=== 1. GPU ==="
$gpus = @(Get-AmdGpuNames)
$arch = Get-GpuArch $gpus
if ($gpus.Count -eq 0) {
    Bad "No AMD GPU detected."
} else {
    $gpus | ForEach-Object { Write-Host "  $_" }
    if ($arch -eq 'gfx1030')     { Ok "This is a gfx1030 (Navi 21). Stock rocBLAS ships its kernels." }
    elseif ($arch -eq 'gfx1031') { Ok "This is a gfx1031 (Navi 22). Its rocBLAS kernels have to be installed." }
    else { Warn "Not a desktop RDNA2 card this project covers (RX 6950/6900/6800 XT, RX 6700/6750 XT). These scripts may not apply." }
}

Write-Host ""
Write-Host "=== 2. HIP SDK ==="
$hips = @(Get-HipInstalls)
if ($hips.Count -eq 0) {
    Bad "No HIP SDK installed."
    Fix "Install HIP SDK for Windows, matching your ZLUDA version (see section 4)."
} else {
    foreach ($h in $hips) {
        if ($h.Runtime) {
            Write-Host "  HIP $($h.Version)  runtime $($h.Runtime)  $($h.Root)"
        } else {
            # An incomplete install like this gives ZLUDA a bare 0xC0000135.
            Bad "HIP $($h.Version) is incomplete: no amdhip64*.dll in $($h.Bin)"
            Fix "Take one from C:\Windows\System32\DriverStore\FileRepository\amdocl.inf_*, matching your installed driver version."
        }
    }
    if ($hips.Count -gt 1) {
        Warn "$($hips.Count) HIP versions installed; PATH order decides which one is used (see section 3)."
    }
}

Write-Host ""
Write-Host "=== 3. Environment variables and PATH ==="
$hu = [Environment]::GetEnvironmentVariable('HIP_PATH', 'User')
$hm = [Environment]::GetEnvironmentVariable('HIP_PATH', 'Machine')
if ($hu -and $hm -and ($hu.TrimEnd('\') -ne $hm.TrimEnd('\'))) {
    # The installer writes the machine scope; a stale user value silently wins.
    Bad "HIP_PATH differs between user ($hu) and machine ($hm) scope; the user one wins."
    Fix "Decide which you want, then delete the user-scope HIP_PATH from System Properties > Environment Variables."
} elseif ($hu -or $hm) {
    if ($hu) { Ok "HIP_PATH = $hu" } else { Ok "HIP_PATH = $hm" }
} else {
    Warn "HIP_PATH is not set."
}

$first = @($env:Path -split ';' | Where-Object { $_ -like '*AMD\ROCm*' } | Select-Object -First 1)
if ($first) {
    Write-Host "  First ROCm entry on PATH: $first"
    if ($hips.Count -gt 1) { Fix "With several versions installed, put the one you want first." }
} elseif ($hips.Count -gt 0) {
    Bad "No ROCm bin directory on PATH."
    Fix "Put the bin directory of your target HIP first on PATH."
}

Write-Host ""
Write-Host "=== 4. ZLUDA and HIP version match ==="
$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
$zdir = $null
if (-not $root) {
    Warn "ComfyUI root not found, skipping the ZLUDA check. Pass -ComfyUIRoot."
} else {
    Write-Host "  ComfyUI: $root"
    $zdir = Find-ZludaDir -ComfyUIRoot $root
    if (-not $zdir) {
        Warn "The ZLUDA nvcuda.dll was not found."
    } else {
        $nvcuda = Join-Path $zdir 'nvcuda.dll'
        Write-Host "  $nvcuda"
        $zexe = Join-Path $zdir 'zluda.exe'
        if (Test-Path $zexe) {
            $ver = (& $zexe --version 2>&1 | Select-Object -First 1)
            Write-Host "  $ver"
        }
        $need = Get-ZludaHipRequirement $nvcuda
        if (-not $need) {
            Warn "Could not read which amdhip64 it imports."
        } else {
            # A mismatch here is 0xC0000135 or 0xC0000139 with no other clue.
            $have = @($hips | Where-Object { $_.Runtime -eq $need })
            if ($have.Count -gt 0) {
                Ok "ZLUDA wants $need, HIP $($have[0].Version) provides it."
            } else {
                Bad "ZLUDA wants $need, but none of the installed HIP versions provide it."
                Fix "Either install the matching HIP major version or change ZLUDA (3.9.5 goes with HIP 6.x, 3.9.6 with HIP 7.x)."
            }
        }
    }
}

Write-Host ""
$want = $arch
if (-not $want) { $want = 'gfx1030' }   # nothing better to look for
Write-Host "=== 5. $want kernels in rocBLAS ==="
# This is the one place the two architectures differ. gfx1030 is on the official
# ROCm support list and stock rocBLAS ships its kernels, so an absence there means
# a broken HIP install. gfx1031 is not, so an absence is expected until they are
# installed. Match on the bare architecture string: most files are named
# ..._gfx1031.xxx, but Kernels.so-000-gfx1031.hsaco uses a hyphen, and matching on
# an underscore silently skips it along with every .co code object.
foreach ($h in $hips) {
    if (-not $h.Runtime) { continue }   # section 2 already reported this one as broken
    if (-not (Test-Path $h.RocBlasLib)) {
        Bad "HIP $($h.Version): no rocblas\library directory at $($h.RocBlasLib)"
        Fix "Reinstall the HIP SDK; this install is missing rocBLAS entirely."
        continue
    }
    $n = @(Get-ChildItem $h.RocBlasLib -Recurse -File -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -like "*$want*" }).Count
    if ($n -gt 0) {
        if ($want -eq 'gfx1030') { Ok "HIP $($h.Version): $n gfx1030 files, as shipped." }
        else { Ok "HIP $($h.Version): $n gfx1031 files installed." }
    }
    elseif ($want -eq 'gfx1031') {
        Bad "HIP $($h.Version): no gfx1031 kernels, so you will get 'no kernel image is available'."
        Fix "Run scripts\Install-Kernels.ps1 (-Mode Borrow by default, or -Mode Download for real community kernels)."
    }
    else {
        Bad "HIP $($h.Version): no gfx1030 kernels, so you will get 'no kernel image is available'."
        Fix "Unexpected on this GPU, which ships with them. Reinstall the HIP SDK rather than sourcing kernels from elsewhere."
    }
}

Write-Host ""
Write-Host "=== 6. ZLUDA DLLs in torch\lib ==="
if ($root -and $zdir) {
    $torchLib = Join-Path $root 'venv\Lib\site-packages\torch\lib'
    if (-not (Test-Path $torchLib)) {
        Warn "No torch\lib at $torchLib - the ComfyUI venv is not set up."
    } else {
        # Python 3.8+ no longer searches PATH for extension-module dependencies,
        # so these have to be copied in under the names torch expects.
        $map = Get-TorchDllMap
        $stale = foreach ($k in $map.Keys) {
            $src = Join-Path $zdir $k
            $dst = Join-Path $torchLib $map[$k]
            if (-not (Test-Path $src)) { continue }
            if (-not (Test-Path $dst)) { $map[$k]; continue }
            if ((Get-FileHash $src).Hash -ne (Get-FileHash $dst).Hash) { $map[$k] }
        }
        if (@($stale).Count -eq 0) {
            Ok "The CUDA DLLs in torch\lib are the ZLUDA builds."
        } else {
            Bad "These in torch\lib are not the ZLUDA builds: $($stale -join ', ')"
            Fix "Run scripts\Patch-ComfyUI.ps1. Editing PATH instead achieves nothing on Python 3.8+."
        }

        # cublasLt is deliberately not in the map: torch keeps its own build, and
        # replacing it with the much smaller ZLUDA one breaks torch.
        $lt = Join-Path $torchLib 'cublasLt64_11.dll'
        $ltSrc = Join-Path $zdir 'cublasLt.dll'
        if ((Test-Path $lt) -and (Test-Path $ltSrc) -and ((Get-FileHash $lt).Hash -eq (Get-FileHash $ltSrc).Hash)) {
            Bad "cublasLt64_11.dll in torch\lib was overwritten with the ZLUDA cublasLt.dll."
            Fix "Restore it by reinstalling torch. Only the four DLLs above get replaced."
        }
    }
}

Write-Host ""
Write-Host "=== 7. ComfyUI-side changes ==="
if ($root) {
    $att = Join-Path $root 'comfy\ldm\modules\attention.py'
    if (Test-Path $att) {
        # comfy_kitchen has no int8_attention_is_available under ZLUDA.
        if (Select-String -Path $att -Pattern 'hasattr\(comfy_kitchen, "int8_attention_is_available"\)' -Quiet) {
            Ok "attention.py has the int8_attention guard."
        } else {
            Bad "attention.py is unpatched; startup will fail with AttributeError under ZLUDA."
            Fix "Run scripts\Patch-ComfyUI.ps1"
        }
    }

    # comfyui.bat copies customzluda\zluda-default.py over comfy\zluda.py on every
    # launch, and model_management.py imports comfy.zluda. So the default file is
    # what actually runs, and edits to comfy\zluda.py are silently discarded.
    $default = Join-Path $root 'comfy\customzluda\zluda-default.py'
    $active  = Join-Path $root 'comfy\zluda.py'
    if (Test-Path $default) {
        # This is the line that keeps the display driver up. The mem-efficient
        # backend's CUTLASS kernel is built for the wrong SM version, and one
        # SDPA call through it resets the driver.
        if (Select-String -Path $default -Pattern 'enable_mem_efficient_sdp\(False\)' -Quiet) {
            Ok "zluda-default.py disables the mem-efficient attention backend."
        } else {
            Bad "zluda-default.py does not disable the mem-efficient attention backend; attention will reset the display driver."
            Fix "Run scripts\Patch-ComfyUI.ps1"
        }
        if ((Test-Path $active) -and ((Get-FileHash $default).Hash -ne (Get-FileHash $active).Hash)) {
            Warn "comfy\zluda.py differs from zluda-default.py; the launcher overwrites it at startup."
            Fix "Put any change in comfy\customzluda\zluda-default.py instead."
        }
    } elseif (Test-Path $active) {
        # An install without the default file: the active module is the only one.
        if (Select-String -Path $active -Pattern 'enable_mem_efficient_sdp\(False\)' -Quiet) {
            Ok "comfy\zluda.py disables the mem-efficient attention backend."
        } else {
            Bad "comfy\zluda.py does not disable the mem-efficient attention backend; attention will reset the display driver."
            Fix "Run scripts\Patch-ComfyUI.ps1"
        }
    }

    $bat = Join-Path $root 'comfyui.bat'
    if (Test-Path $bat) {
        $text = Get-Content $bat -Raw
        foreach ($flag in '--disable-async-offload', '--disable-pinned-memory') {
            if ($text -match [regex]::Escape($flag)) {
                Ok "comfyui.bat passes $flag"
            } else {
                Bad "comfyui.bat does not pass $flag"
                Fix "Run scripts\Patch-ComfyUI.ps1"
            }
        }
        # Not needed on every machine, so this is a hint rather than a failure.
        if ($text -notmatch '--disable-mmap') {
            Write-Host "  comfyui.bat does not pass --disable-mmap. Add it only if loading a large model dies with an access violation." -ForegroundColor DarkGray
        }
    }
}

Write-Host ""
if ($fail -eq 0 -and $warn -eq 0) {
    Write-Host "All checks passed." -ForegroundColor Green
} else {
    $color = 'Yellow'
    if ($fail -gt 0) { $color = 'Red' }
    Write-Host "Failed: $fail   Warnings: $warn   Fix these and run this again." -ForegroundColor $color
}
