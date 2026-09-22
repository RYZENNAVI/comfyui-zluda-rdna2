<#
.SYNOPSIS
Download a community-built gfx1031 rocBLAS kernel pack, returning its path.

.DESCRIPTION
This project does not redistribute those binaries - upstream is GPL-3.0, and
redistributing would carry the corresponding obligations. The script fetches
them from upstream at install time instead, which also picks up their updates.

Sources, tried in order:
  1. likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU  published as release assets
  2. brknsoul/ROCmLibs                              files sit in the repo root

.PARAMETER HipVersion
Target HIP version, e.g. 6.2 or 6.2.4, used to pick the matching asset.

.PARAMETER OutDir
Download directory. Defaults to the temp directory.

.PARAMETER Yes
Skip the download confirmation.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HipVersion,
    [string]$OutDir = $env:TEMP,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'

$gh = @{ 'User-Agent' = 'comfyui-zluda-gfx1031'; 'Accept' = 'application/vnd.github+json' }

# Asset names spell the version every which way: "hip.6.4.2", "hip sdk 6.2.4",
# "rocm 6.2.4", "hip6.2". Match major.minor only, with a loose separator.
$parts = $HipVersion -split '\.'
$pat = "$($parts[0])[._ ]?$($parts[1])"

function Select-Match {
    param($Items)   # each needs Name / Url / Size / From
    $Items | Where-Object { $_.Name -match 'gfx1031' -and $_.Name -match $pat } | Select-Object -First 1
}

function Get-FromReleases {
    param([string]$Repo)
    $out = foreach ($r in (Invoke-RestMethod "https://api.github.com/repos/$Repo/releases" -Headers $gh)) {
        foreach ($a in $r.assets) {
            [pscustomobject]@{ Name = $a.name; Url = $a.browser_download_url; Size = $a.size; From = "$Repo ($($r.tag_name))" }
        }
    }
    Select-Match $out
}

function Get-FromRepoRoot {
    param([string]$Repo)
    $out = Invoke-RestMethod "https://api.github.com/repos/$Repo/contents/" -Headers $gh |
        Where-Object { $_.type -eq 'file' } |
        ForEach-Object { [pscustomobject]@{ Name = $_.name; Url = $_.download_url; Size = $_.size; From = $Repo } }
    Select-Match $out
}

$hit = $null
foreach ($probe in @(
    { Get-FromReleases 'likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU' },
    { Get-FromRepoRoot 'brknsoul/ROCmLibs' }
)) {
    $hit = & $probe
    if ($hit) { break }
}

if (-not $hit) {
    throw @"
Neither upstream has a pack matching gfx1031 + HIP $HipVersion. You can:
  - use -Mode Borrow instead (reuses gfx1030 kernels, no network), or
  - pick one yourself and pass it with -PackPath:
      https://github.com/likelovewant/ROCmLibs-for-gfx1103-AMD780M-APU/releases
      https://github.com/brknsoul/ROCmLibs
"@
}

Write-Host ""
Write-Host "Found: $($hit.Name)  ($([math]::Round($hit.Size / 1MB, 1)) MB)"
Write-Host "From:  $($hit.From)"
Write-Host "License: upstream is GPL-3.0 and built by a third party. Make sure you are happy with that before installing." -ForegroundColor Yellow

if (-not $Yes) {
    if ((Read-Host "Download it? [y/N]") -notmatch '^[yY]') { throw "Cancelled." }
}

$dst = Join-Path $OutDir $hit.Name
Invoke-WebRequest -Uri $hit.Url -OutFile $dst -UseBasicParsing
Write-Host "Downloaded to $dst" -ForegroundColor Green

$dst
