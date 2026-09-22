<#
.SYNOPSIS
Install gfx1031 (RX 6700 / 6700 XT / 6750 XT) kernels into rocBLAS.

.DESCRIPTION
Official AMD ROCm ships no gfx1031 rocBLAS kernels, so every matmul dies with
"no kernel image is available". Two ways out:

  Borrow   Rename the gfx1030 kernels already present. gfx1030 and gfx1031 are
           both RDNA2 and ISA-compatible. No network, no third-party binaries,
           but the tuning parameters were picked for gfx1030.
  Download Replace them with kernels the community actually compiled for
           gfx1031. Usually faster, needs network access.

.PARAMETER Mode
Borrow or Download. Defaults to Borrow.

.PARAMETER HipRoot
HIP install root. Auto-detected when omitted; the newest version wins.

.PARAMETER PackPath
Download mode only: a pack you already downloaded, either the archive or an
extracted directory. Skips the download when given.

.PARAMETER Yes
Download mode only: skip the confirmation before downloading.
#>
[CmdletBinding()]
param(
    [ValidateSet('Borrow', 'Download')]
    [string]$Mode = 'Borrow',
    [string]$HipRoot,
    [string]$PackPath,
    [switch]$Yes,
    [switch]$Force
)

. (Join-Path $PSScriptRoot 'Common.ps1')

# This step is for gfx1031 only. gfx1030 is on the official ROCm support list and
# stock rocBLAS already ships its kernels, so there is nothing to install and
# rewriting the shipped library would only put the install at risk.
if ((Get-GpuArch) -eq 'gfx1030' -and -not $Force) {
    Write-Host "This is a gfx1030 (RX 6950/6900/6800 XT). Stock rocBLAS already ships its kernels," -ForegroundColor Yellow
    Write-Host "so there is nothing to install here. Pass -Force if you really mean to." -ForegroundColor Yellow
    return
}

# ---- pick the target HIP ----
if ($HipRoot) {
    $hip = Get-HipInstall -Root $HipRoot
    if (-not $hip) { throw "No usable HIP at $HipRoot (no bin directory)." }
} else {
    $all = @(Get-HipInstalls)
    if ($all.Count -eq 0) { throw "No HIP SDK found. Install one first." }
    $hip = $all[0]
    if ($all.Count -gt 1) {
        Write-Host "Found several HIP installs: $(($all.Version) -join ', ') - using $($hip.Version). Pass -HipRoot to choose." -ForegroundColor Yellow
    }
}

$LIB = $hip.RocBlasLib
Write-Host "Target: HIP $($hip.Version)  ->  $LIB"
if (-not $hip.Runtime) {
    Write-Host "Note: $($hip.Bin) has no amdhip64*.dll, so this HIP install is incomplete. Kernels alone will not make it run - see Check-Environment.ps1." -ForegroundColor Yellow
}
if (-not (Test-Path $LIB)) { throw "No $LIB - this HIP install has no rocBLAS." }
Assert-Writable $LIB

# ---- back up ----
$bak = "$LIB.bak"
if (-not (Test-Path $bak)) {
    Copy-Item $LIB $bak -Recurse -Force
    Write-Host "Backed up the original library to $bak"
} else {
    Write-Host "Backup $bak already exists, leaving it alone."
}

if ($Mode -eq 'Borrow') {
    # All three kinds matter: .dat are manifests, .hsaco and .co are compiled
    # code objects. Naming is inconsistent - most are `..._gfx1030.xxx` but
    # `Kernels.so-000-gfx1030.hsaco` uses a hyphen, so match on the gfx1030
    # substring rather than on an underscore.
    $src = @(Get-ChildItem $LIB -File | Where-Object { $_.Name -like '*gfx1030*' })
    if ($src.Count -eq 0) {
        throw "No gfx1030 kernels in $LIB to borrow from. This HIP version ships no RDNA2 kernels - use -Mode Download."
    }

    $old = [System.Text.Encoding]::ASCII.GetBytes('gfx1030')
    $new = [System.Text.Encoding]::ASCII.GetBytes('gfx1031')
    $n = 0

    foreach ($f in $src) {
        $out = Join-Path $LIB ($f.Name -replace 'gfx1030', 'gfx1031')

        if ($f.Extension -eq '.dat') {
            # .dat is a binary manifest with hardcoded offsets. gfx1030 and
            # gfx1031 are the same length, so overwrite those 7 bytes in place -
            # a text replace, or any differently sized name, corrupts the file.
            $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
            for ($i = 0; $i -le $bytes.Length - $old.Length; $i++) {
                $match = $true
                for ($j = 0; $j -lt $old.Length; $j++) {
                    if ($bytes[$i + $j] -ne $old[$j]) { $match = $false; break }
                }
                if ($match) { [Array]::Copy($new, 0, $bytes, $i, $new.Length) }
            }
            [System.IO.File]::WriteAllBytes($out, $bytes)
        } else {
            # Code objects: same ISA, so the contents are fine as they are.
            Copy-Item $f.FullName $out -Force
        }
        $n++
    }

    Write-Host "OK: derived $n gfx1031 files from gfx1030." -ForegroundColor Green
}
else {
    if (-not $PackPath) {
        $PackPath = & (Join-Path $PSScriptRoot 'Get-KernelPack.ps1') -HipVersion $hip.Version -Yes:$Yes
    }

    if ((Get-Item $PackPath).PSIsContainer) {
        $dir = $PackPath
    } else {
        $dir = Join-Path $env:TEMP ("gfx1031-pack-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        Expand-KernelPack -Path $PackPath -Destination $dir | Out-Null
    }

    # Directory layout varies between packs, so find the library folder by content.
    $srcLib = Get-ChildItem $dir -Recurse -Directory -Filter 'library' |
        Where-Object { Get-ChildItem $_.FullName -File -Filter '*gfx1031*' -ErrorAction SilentlyContinue } |
        Select-Object -First 1
    if (-not $srcLib) { throw "No library directory containing gfx1031 files inside $dir" }

    # Replace the library outright rather than merging the pack into it. Leaving
    # the stock manifests next to the ones from the pack is an untested mixture,
    # and everything that was there is already in the backup.
    Get-ChildItem $LIB -Force | Remove-Item -Recurse -Force
    Copy-Item (Join-Path $srcLib.FullName '*') -Destination $LIB -Recurse -Force

    # Some packs ship a matching rocblas.dll; swap it too, with its own backup.
    $srcDll = Get-ChildItem $dir -Recurse -File -Filter 'rocblas.dll' | Select-Object -First 1
    if ($srcDll) {
        $dstDll = Join-Path $hip.Bin 'rocblas.dll'
        if ((Test-Path $dstDll) -and -not (Test-Path "$dstDll.bak")) { Copy-Item $dstDll "$dstDll.bak" -Force }
        Copy-Item $srcDll.FullName $dstDll -Force
        Write-Host "The pack included rocblas.dll, replaced it too (backup: rocblas.dll.bak)."
    }

    $g = @(Get-ChildItem $LIB -Recurse -File | Where-Object { $_.Name -like '*gfx1031*' }).Count
    Write-Host "OK: installed community gfx1031 kernels, $g gfx1031 files in place." -ForegroundColor Green
}

Write-Host ""
Write-Host "Next: scripts\Test-Setup.ps1 to check matmul and convolution actually run."
