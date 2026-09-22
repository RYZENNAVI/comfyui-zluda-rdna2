<#
.SYNOPSIS
Set up a desktop RDNA2 GPU to run ComfyUI + ZLUDA on Windows.

.DESCRIPTION
Detects the architecture and runs the steps it needs:
  1. check the environment   scripts\Check-Environment.ps1
  2. install gfx1031 kernels scripts\Install-Kernels.ps1   (gfx1031 only)
  3. patch ComfyUI           scripts\Patch-ComfyUI.ps1
  4. verify on the GPU       scripts\Test-Setup.ps1

Step 2 is skipped on gfx1030 (RX 6950/6900/6800 XT): that architecture is on the
official ROCm support list, so stock rocBLAS already ships its kernels.

Each step also runs on its own. When something fails, look it up in
docs\TROUBLESHOOTING.md.

.PARAMETER Mode
gfx1031 only. Kernel source: Borrow (reuse gfx1030 kernels, no network, the
default) or Download (community-built real gfx1031 kernels).

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.

.PARAMETER HipRoot
HIP install root. Auto-detected when omitted.

.PARAMETER Yes
Download mode only: skip the confirmation before downloading the kernel pack.

.EXAMPLE
.\install.ps1

.EXAMPLE
.\install.ps1 -Mode Download
#>
[CmdletBinding()]
param(
    [ValidateSet('Borrow', 'Download')]
    [string]$Mode = 'Borrow',
    [string]$ComfyUIRoot,
    [string]$HipRoot,
    [switch]$Yes
)

. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$gpus = @(Get-AmdGpuNames)
$arch = Get-GpuArch $gpus
if (-not $arch) {
    Write-Host "No desktop RDNA2 GPU detected (RX 6950/6900/6800 XT, RX 6700/6750 XT)." -ForegroundColor Yellow
    Write-Host "Found: $($gpus -join ', ')"
    if ((Read-Host "Continue anyway? [y/N]") -notmatch '^[yY]') { return }
    $arch = 'gfx1030'   # the path that installs no kernels
}

# gfx1030 is on the official ROCm support list, so stock rocBLAS already ships its
# kernels and there is nothing to install. gfx1031 is not, so it gets a step more.
$steps = 3
if ($arch -eq 'gfx1031') { $steps = 4 }
$n = 0

Write-Host ""
Write-Host "Detected $arch, running $steps steps." -ForegroundColor Cyan

$n++
Write-Host ""
Write-Host "######## $n/$steps checking the environment ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Check-Environment.ps1') -ComfyUIRoot $ComfyUIRoot

if ($arch -eq 'gfx1031') {
    $n++
    Write-Host ""
    Write-Host "######## $n/$steps installing gfx1031 kernels ########" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'scripts\Install-Kernels.ps1') -Mode $Mode -HipRoot $HipRoot -Yes:$Yes
}

$n++
Write-Host ""
Write-Host "######## $n/$steps patching ComfyUI ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Patch-ComfyUI.ps1') -ComfyUIRoot $ComfyUIRoot

$n++
Write-Host ""
Write-Host "######## $n/$steps verifying on the GPU ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Test-Setup.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
Write-Host "Done. Environment variable changes need a fresh terminal to take effect." -ForegroundColor Green
