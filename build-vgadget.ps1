# build-vgadget.ps1 — package gadget/EdgeBreaker into dist/EdgeBreaker-v<version>.vgadget
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$luaText = Get-Content (Join-Path $root "gadget\EdgeBreaker\EdgeBreaker.lua") -Raw
if ($luaText -notmatch 'CO\.VERSION\s*=\s*"([0-9.]+)"') { throw "CO.VERSION not found" }
$version = $Matches[1]
# The help page ships in the gadget folder and is generated from README.md, so a
# package must never carry a stale one. CHECK, don't regenerate: regenerating
# would rewrite a tracked, already-deployed file in the middle of a build, so the
# repo would quietly stop matching what is deployed and what the shop machines
# pulled. Better to stop and be told to run the generator.
& (Join-Path $root "build-help.ps1") -Check
if ($LASTEXITCODE -ne 0) { throw "help page is stale -- run build-help.ps1, then build again" }
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

# The version-less copy is what the PERMANENT download link resolves to:
#   .../releases/latest/download/EdgeBreaker.vgadget
# That URL is published in the forum and Facebook posts and in the README, so a
# release that forgets this asset breaks every link already out in the world.
# Nothing enforced it before -- it was a step in a session report. Now the
# packager just always produces both, byte-identical, so there is nothing to
# forget: upload both files to the release.
$perm = Join-Path $dist "EdgeBreaker.vgadget"
Copy-Item $out $perm -Force
Write-Host "Built $perm (same bytes -- the permanent-link asset)"
