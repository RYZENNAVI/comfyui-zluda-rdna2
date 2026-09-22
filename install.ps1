<#
.SYNOPSIS
Set up an RX 6950 XT / 6900 XT / 6800 XT (gfx1030) to run ComfyUI + ZLUDA.

.DESCRIPTION
Runs three steps in order:
  1. check the environment  scripts\Check-Environment.ps1
  2. patch ComfyUI          scripts\Patch-ComfyUI.ps1
  3. verify on the GPU      scripts\Test-Setup.ps1

There is no kernel installation step: gfx1030 is officially supported, so stock
rocBLAS already ships its kernels.

Each step also runs on its own. When something fails, look it up in
docs\TROUBLESHOOTING.md.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.

.PARAMETER SkipTest
Skip the GPU self-test, for example while ComfyUI is busy.

.EXAMPLE
.\install.ps1

.EXAMPLE
.\install.ps1 -ComfyUIRoot D:\ComfyUI-Zluda
#>
[CmdletBinding()]
param(
    [string]$ComfyUIRoot,
    [switch]$SkipTest
)

. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$gpus = @(Get-AmdGpuNames)
if (-not (Test-IsGfx1030 $gpus)) {
    Write-Host "No gfx1030 GPU detected (RX 6950 XT / 6900 XT / 6800 XT / 6800)." -ForegroundColor Yellow
    Write-Host "Found: $($gpus -join ', ')"
    if ((Read-Host "Continue anyway? [y/N]") -notmatch '^[yY]') { return }
}

Write-Host ""
Write-Host "######## 1/3 checking the environment ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Check-Environment.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
Write-Host "######## 2/3 patching ComfyUI ########" -ForegroundColor Cyan
& (Join-Path $PSScriptRoot 'scripts\Patch-ComfyUI.ps1') -ComfyUIRoot $ComfyUIRoot

Write-Host ""
if ($SkipTest) {
    Write-Host "######## 3/3 GPU self-test skipped ########" -ForegroundColor Cyan
    Write-Host "Run scripts\Test-Setup.ps1 when the GPU is free."
} else {
    Write-Host "######## 3/3 verifying on the GPU ########" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot 'scripts\Test-Setup.ps1') -ComfyUIRoot $ComfyUIRoot
}

Write-Host ""
Write-Host "Done. Environment variable changes need a fresh terminal to take effect." -ForegroundColor Green
