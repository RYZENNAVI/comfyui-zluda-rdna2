<#
.SYNOPSIS
Apply the ComfyUI-side changes that gfx1030 + ZLUDA needs.

.DESCRIPTION
1. comfy\ldm\modules\attention.py
   comfy_kitchen has no int8_attention_is_available under ZLUDA, so calling it
   raises AttributeError during startup.

2. comfy\customzluda\zluda-default.py
   The mem-efficient attention backend resets the display driver: its CUTLASS
   kernel is built for the wrong SM version. This is the file to edit, not
   comfy\zluda.py: comfyui.bat copies the default over comfy\zluda.py on every
   launch, so edits there are silently discarded.

3. comfyui.bat
   --disable-async-offload and --disable-pinned-memory are known to break ZLUDA
   setups. --disable-mmap is not added here; it is only needed when loading a
   large model dies with an access violation.

4. venv\Lib\site-packages\torch\lib
   Python 3.8+ no longer searches PATH for extension-module dependencies, so the
   ZLUDA DLLs are copied in under the names torch asks for. cublasLt64_11.dll is
   left alone: torch keeps its own build.

Every file is backed up as .gfx1030.bak before its first change. Running this
more than once is harmless.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.
#>
[CmdletBinding()]
param([string]$ComfyUIRoot)

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
if (-not $root) { throw "ComfyUI root not found. Pass -ComfyUIRoot." }
Write-Host "ComfyUI: $root"

function Backup-Once {
    param([string]$Path)
    $b = "$Path.gfx1030.bak"
    if (-not (Test-Path $b)) { Copy-Item $Path $b }
}

# ---- 1) attention.py ----
$att = Join-Path $root 'comfy\ldm\modules\attention.py'
if (-not (Test-Path $att)) { throw "No $att" }

$text = Get-Content $att -Raw
$call = 'COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = comfy_kitchen.int8_attention_is_available()'

if ($text -match 'hasattr\(comfy_kitchen, "int8_attention_is_available"\)') {
    Write-Host "  attention.py: already patched." -ForegroundColor DarkGray
} elseif ($text -notmatch [regex]::Escape($call)) {
    Write-Host "  attention.py: the line to patch was not found, upstream may have changed. Skipping." -ForegroundColor Yellow
} else {
    Backup-Once $att
    $guard = @'
if hasattr(comfy_kitchen, "int8_attention_is_available"):
    COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = comfy_kitchen.int8_attention_is_available()
else:
    COMFY_KITCHEN_INT8_ATTENTION_IS_AVAILABLE = False
'@
    [IO.File]::WriteAllText($att, $text.Replace($call, $guard.TrimEnd()), (New-Object Text.UTF8Encoding $false))
    Write-Host "  attention.py: added the hasattr guard." -ForegroundColor Green
}

# ---- 2) the ZLUDA module the launcher actually installs ----
$default = Join-Path $root 'comfy\customzluda\zluda-default.py'
$target = $default
if (-not (Test-Path $target)) { $target = Join-Path $root 'comfy\zluda.py' }

if (-not (Test-Path $target)) {
    Write-Host "  zluda module: not found, skipping the cuDNN change." -ForegroundColor Yellow
} else {
    $name = Split-Path $target -Leaf
    $zt = Get-Content $target -Raw
    if ($zt -match 'enable_mem_efficient_sdp\(False\)') {
        Write-Host "  ${name}: already disables the mem-efficient attention backend." -ForegroundColor DarkGray
    } elseif ($zt -match 'enable_mem_efficient_sdp\(True\)') {
        Backup-Once $target
        $zt = $zt -replace 'enable_mem_efficient_sdp\(True\)', 'enable_mem_efficient_sdp(False)'
        [IO.File]::WriteAllText($target, $zt, (New-Object Text.UTF8Encoding $false))
        Write-Host "  ${name}: disabled the mem-efficient attention backend." -ForegroundColor Green
    } else {
        # Do not inject a call into a file whose shape is unknown; say so instead.
        Write-Host "  ${name}: no enable_mem_efficient_sdp call found, upstream may have changed. Add this by hand:" -ForegroundColor Yellow
        Write-Host "      torch.backends.cuda.enable_mem_efficient_sdp(False)" -ForegroundColor Yellow
    }

    # comfy\zluda.py is regenerated from the default on every launch, so keep it
    # in step now rather than leaving a stale copy for this session.
    $active = Join-Path $root 'comfy\zluda.py'
    if (($target -eq $default) -and (Test-Path $active) -and ((Get-FileHash $default).Hash -ne (Get-FileHash $active).Hash)) {
        Backup-Once $active
        Copy-Item $default $active -Force
        Write-Host "  comfy\zluda.py: refreshed from zluda-default.py (the launcher does this too)." -ForegroundColor Green
    }
}

# ---- 3) comfyui.bat ----
$bat = Join-Path $root 'comfyui.bat'
if (-not (Test-Path $bat)) {
    Write-Host "  comfyui.bat: not found, skipping the launch flags." -ForegroundColor Yellow
} else {
    $lines = Get-Content $bat
    $changed = $false

    foreach ($flag in '--disable-async-offload', '--disable-pinned-memory') {
        # -match on an array filters rather than tests, so this needs the outer -not.
        if (-not ($lines -match [regex]::Escape($flag))) {
            for ($i = 0; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*set "COMMANDLINE_ARGS=') {
                    $lines[$i] = $lines[$i] -replace '"\s*$', " $flag`""
                    $changed = $true
                }
            }
        }
    }

    if ($changed) {
        Backup-Once $bat
        [IO.File]::WriteAllLines($bat, $lines, (New-Object Text.UTF8Encoding $false))
        Write-Host "  comfyui.bat: updated (backup: comfyui.bat.gfx1030.bak)." -ForegroundColor Green
    } else {
        Write-Host "  comfyui.bat: already has the launch flags." -ForegroundColor DarkGray
    }
}

# ---- 4) ZLUDA DLLs into torch\lib ----
$zdir = Find-ZludaDir -ComfyUIRoot $root
$torchLib = Join-Path $root 'venv\Lib\site-packages\torch\lib'
if (-not $zdir) {
    Write-Host "  torch\lib: no ZLUDA directory found, skipping." -ForegroundColor Yellow
} elseif (-not (Test-Path $torchLib)) {
    Write-Host "  torch\lib: not found, the venv is not set up. Skipping." -ForegroundColor Yellow
} else {
    $copied = 0
    foreach ($e in (Get-TorchDllMap).GetEnumerator()) {
        $src = Join-Path $zdir $e.Key
        $dst = Join-Path $torchLib $e.Value
        if (-not (Test-Path $src)) { continue }
        if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -eq (Get-FileHash $dst).Hash)) { continue }
        if (Test-Path $dst) { Backup-Once $dst }
        Copy-Item $src $dst -Force
        Write-Host "  torch\lib: $($e.Key) -> $($e.Value)" -ForegroundColor Green
        $copied++
    }
    if ($copied -eq 0) { Write-Host "  torch\lib: already holds the ZLUDA builds." -ForegroundColor DarkGray }
}

Write-Host ""
Write-Host "Next: scripts\Test-Setup.ps1"
