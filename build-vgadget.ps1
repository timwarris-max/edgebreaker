# build-vgadget.ps1 — package gadget/EdgeBreaker into dist/EdgeBreaker-v<version>.vgadget
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$luaText = Get-Content (Join-Path $root "gadget\EdgeBreaker\EdgeBreaker.lua") -Raw
if ($luaText -notmatch 'CO\.VERSION\s*=\s*"([0-9.]+)"') { throw "CO.VERSION not found" }
$version = $Matches[1]
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "EdgeBreaker-v$version.zip"
$out = Join-Path $dist "EdgeBreaker-v$version.vgadget"
if (Test-Path $zip) { Remove-Item $zip -Confirm:$false }
if (Test-Path $out) { Remove-Item $out -Confirm:$false }
# Folder at archive root (per docs/m0-results.md '.vgadget format' — adjust if findings differ)
Compress-Archive -Path (Join-Path $root "gadget\EdgeBreaker") -DestinationPath $zip
Rename-Item $zip $out
Write-Host "Built $out"
