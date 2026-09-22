<#
.SYNOPSIS
Run real work on the GPU from the ComfyUI venv to prove the setup works.

.DESCRIPTION
Check-Environment.ps1 only inspects files and environment variables. This one
dispatches real work to the GPU to prove the plumbing carries it:
  - matmul        goes through rocBLAS
  - convolution   the VAE and UNet path
  - attention     SDPA, with the backends pinned the way ComfyUI pins them

It deliberately exercises only what ComfyUI itself runs, in the configuration
ComfyUI runs it in. It is a check that the setup works, not a stability survey
of your card, and it does not poke at code paths a working ComfyUI never enters.
That matters for attention in particular: called with the default backends,
SDPA resets the display driver on this hardware.

The first run is slow because ZLUDA JIT-compiles kernels, cached under
%LOCALAPPDATA%\ZLUDA\ComputeCache. Later runs are fast.

Refuses to start while ComfyUI is running, so the two do not fight over VRAM.

.PARAMETER ComfyUIRoot
ComfyUI root directory. Auto-detected when omitted.

.PARAMETER TimeoutSeconds
How long to wait for a result. Defaults to 900, since the first run has to
JIT-compile kernels.

.PARAMETER Force
Run even when ComfyUI appears to be running.
#>
[CmdletBinding()]
param(
    [string]$ComfyUIRoot,
    [int]$TimeoutSeconds = 900,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')

$root = Find-ComfyUIRoot -Hint $ComfyUIRoot
if (-not $root) { throw "ComfyUI root not found. Pass -ComfyUIRoot." }

$py = Join-Path $root 'venv\Scripts\python.exe'
if (-not (Test-Path $py)) { throw "No $py - the ComfyUI venv is not set up." }

$zdir = Find-ZludaDir -ComfyUIRoot $root
if (-not $zdir) { throw "The ZLUDA directory was not found under $root." }
$zexe = Join-Path $zdir 'zluda.exe'
if (-not (Test-Path $zexe)) { throw "No zluda.exe in $zdir." }

# Sharing the GPU with a running ComfyUI turns any result here into guesswork, and
# an out-of-memory failure looks nothing like the problems this script tests for.
# Match on main.py as well as the path, so an unrelated script using the same venv
# is not mistaken for ComfyUI. Never kill a process this script did not start.
$rootPrefix = $root.TrimEnd('\') + '\'
$others = @(Get-CimInstance Win32_Process -Filter "Name='python.exe' OR Name='zluda.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$rootPrefix*" })

$running = @($others | Where-Object { $_.CommandLine -match '\bmain\.py\b' })
if ($running.Count -gt 0 -and -not $Force) {
    Write-Host "ComfyUI looks like it is running (PID $(($running.ProcessId) -join ', '))." -ForegroundColor Yellow
    Write-Host "Close it first so the two do not fight over VRAM, or pass -Force." -ForegroundColor Yellow
    exit 1
}
if ($others.Count -gt $running.Count) {
    # A stuck probe from an earlier run can sit here holding VRAM for a long time.
    Write-Host "Note: $($others.Count - $running.Count) other process(es) are using this install (PID $((($others | Where-Object { $_.CommandLine -notmatch '\bmain\.py\b' }).ProcessId) -join ', ')). They may still be holding VRAM." -ForegroundColor Yellow
}

$code = @'
import torch, sys, os

print("torch       ", torch.__version__)
print("cuda avail  ", torch.cuda.is_available())
if not torch.cuda.is_available():
    sys.exit("torch cannot see the GPU, stopping here.")
print("device      ", torch.cuda.get_device_name(0))

# ComfyUI runs with cuDNN off, because comfy\zluda.py turns it off on import.
# A bare interpreter does not, so set it here or this would test a different
# configuration from the one that matters.
torch.backends.cudnn.enabled = False
print("cudnn       ", torch.backends.cudnn.enabled, "(forced off, the way ComfyUI runs)")

# Same for the attention backends. The mem-efficient one resets the display
# driver here: its CUTLASS kernel is built for the wrong SM version, so one call
# floods "is for sm80-sm100, but was built for sm37" and takes the driver with
# it. ComfyUI turns it off on import; a bare interpreter leaves it on.
torch.backends.cuda.enable_flash_sdp(False)
torch.backends.cuda.enable_math_sdp(True)
torch.backends.cuda.enable_mem_efficient_sdp(False)
print("sdp backend  math only, mem-efficient off")
print()

fail = []

# rocBLAS
try:
    a = torch.randn(1024, 1024, device="cuda", dtype=torch.float16)
    r = (a @ a).float().sum().item()
    assert r == r, "matmul produced NaN"
    print("matmul fp16  OK")
except Exception as e:
    fail.append(("matmul fp16", e))
    print("matmul fp16  FAILED:", e)

# convolution: the VAE and UNet path
try:
    x = torch.randn(1, 4, 64, 64, device="cuda", dtype=torch.float16)
    w = torch.randn(8, 4, 3, 3, device="cuda", dtype=torch.float16)
    y = torch.nn.functional.conv2d(x, w, padding=1)
    assert y.shape == (1, 8, 64, 64), y.shape
    print("conv2d fp16  OK")
except Exception as e:
    fail.append(("conv2d fp16", e))
    print("conv2d fp16  FAILED:", e)

# attention, through the real entry point, safe now that the backend is pinned.
# The first run can sit here for minutes while ZLUDA compiles the math kernels.
# That is compilation, not a hang.
try:
    q = torch.randn(1, 8, 256, 64, device="cuda", dtype=torch.float16)
    torch.nn.functional.scaled_dot_product_attention(q, q, q)
    torch.cuda.synchronize()
    print("sdpa fp16    OK (math backend)")
except Exception as e:
    fail.append(("sdpa fp16", e))
    print("sdpa fp16    FAILED:", e)

print()
rc = 0
if fail:
    print("%d of 3 checks failed." % len(fail))
    rc = 1
else:
    print("All checks passed; this GPU can run ComfyUI.")

print("__RDNA2_DONE__ %d" % rc)
sys.stdout.flush()
os._exit(rc)
'@

$tmp = Join-Path $env:TEMP "rdna2-selftest-$PID.py"
$log = Join-Path $env:TEMP "rdna2-selftest-$PID.log"
Set-Content -Path $tmp -Value $code -Encoding UTF8

$env:PYTHONIOENCODING = 'utf-8'

Write-Host "Running the self-test in $root (the first run is slow while ZLUDA JIT-compiles kernels)..."
Write-Host ""

# Quote each path: Start-Process joins ArgumentList with spaces and quotes
# nothing, so an install under a path like "C:\My Stuff\ComfyUI" would arrive
# at python split in two.
$p = Start-Process -FilePath $zexe -ArgumentList @('--', "`"$py`"", "`"$tmp`"") `
    -WorkingDirectory $root -NoNewWindow -PassThru `
    -RedirectStandardOutput $log -RedirectStandardError "$log.err"

# Once the work is done, python under zluda.exe often refuses to exit, spinning
# on CUDA context teardown. So wait for the sentinel line rather than for exit.
$rc = $null
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 500
    if (Test-Path $log) {
        $m = Select-String -Path $log -Pattern '^__RDNA2_DONE__ (\d+)' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($m) { $rc = [int]$m.Matches[0].Groups[1].Value; break }
    }
    if ($p.HasExited) { $rc = $p.ExitCode; break }
}

# The sentinel is printed immediately before os._exit, so give the process a
# moment to go on its own. Killing zluda.exe while it is still tearing down a
# CUDA context can take the display driver with it.
for ($i = 0; $i -lt 20 -and -not $p.HasExited; $i++) { Start-Sleep -Milliseconds 500 }
if (-not $p.HasExited) { Stop-ProcessTree -Id $p.Id }

if (Test-Path $log) {
    Get-Content $log -Encoding UTF8 | Where-Object { $_ -notmatch '^__RDNA2_DONE__' } | ForEach-Object { Write-Host $_ }
}
if ((Test-Path "$log.err") -and (Get-Item "$log.err").Length -gt 0) {
    Write-Host "--- stderr ---" -ForegroundColor DarkGray
    Get-Content "$log.err" -Encoding UTF8 | ForEach-Object { Write-Host $_ -ForegroundColor DarkGray }
}
Remove-Item $tmp, $log, "$log.err" -ErrorAction SilentlyContinue

Write-Host ""
if ($rc -eq 0) {
    Write-Host "Self-test passed." -ForegroundColor Green
} elseif ($null -eq $rc) {
    Write-Host "No result after $TimeoutSeconds seconds. A first run really can take longer while kernels compile; raise -TimeoutSeconds and try again." -ForegroundColor Yellow
    exit 1
} else {
    Write-Host "Self-test failed. Look the errors above up in docs\TROUBLESHOOTING.md." -ForegroundColor Red
    exit 1
}
