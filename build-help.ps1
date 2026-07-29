# build-help.ps1 -- generate gadget/EdgeBreaker/EdgeBreaker-Help.htm from README.md
#
# The help page the user opens at the machine is GENERATED, so the words live in
# exactly one place: gadget/EdgeBreaker/README.md. Run this on its own after any
# README edit; build-vgadget.ps1 also calls it before packaging.
#
#   powershell -File build-help.ps1
#
# It supports only the markdown the README actually uses and THROWS on anything
# else rather than emitting broken HTML. It also refuses to write unless the
# README's "##" headings and $ORDER below are the same set -- that is the whole
# point of generating: a renamed heading must break the build, not silently drop
# a section out of the help.
#
#   powershell -File build-help.ps1 -Check
#
# -Check generates the page but writes NOTHING: it compares against the file on
# disk and exits 1 if they differ. That is the gate. A generator only keeps the
# words in one place if something notices when the committed page has fallen
# behind the README -- otherwise the repo, the deploy and the shop machines all
# carry a stale help page with every test still green. It is also why packaging
# checks rather than regenerates: a release must FAIL on a stale page, not
# quietly rewrite a tracked file in the middle of a build.

param([switch]$Check)

$ErrorActionPreference = "Stop"
$root   = Split-Path -Parent $MyInvocation.MyCommand.Path
$SRC    = Join-Path $root "gadget\EdgeBreaker\README.md"
$OUT    = Join-Path $root "gadget\EdgeBreaker\EdgeBreaker-Help.htm"
$LUA    = Join-Path $root "gadget\EdgeBreaker\EdgeBreaker.lua"

# Reading order for the help page -- NOT the README's order. This page opens
# when someone at the machine is stuck, so the banner table and the
# troubleshooting notes come first and install instructions go last. Entries
# must match the README's "##" headings exactly.
$ORDER = @(
  "How it decides what to build",
  "Notes",
  "Start depth",
  "The section view",
  "What a chamfer remembers",
  "More than one chamfer in a job",
  "Bits come from your tool database",
  "Chamfers from older versions",
  "The strategy template",
  "Quick start (60 seconds)"
)

$SENT = [char]1   # placeholder marker for code spans; cannot occur in the README

function Fail([string]$msg) { throw "build-help: $msg" }

function Get-Slug([string]$text) {
  $s = $text.ToLower()
  $s = [regex]::Replace($s, '[^a-z0-9 \-]', '')
  $s = $s.Trim() -replace '\s+', '-'
  return $s
}

# --- inline markup -------------------------------------------------------
# Escape first, so code spans and link URLs are safe by construction. Code
# spans are then lifted out so that **, * and [] inside them stay literal.
function Convert-Inline([string]$s, [hashtable]$slugs, [string]$where) {
  $s = $s -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;'

  $codes = New-Object System.Collections.ArrayList
  $s = [regex]::Replace($s, '`([^`]+)`', {
    param($m)
    $i = $codes.Add($m.Groups[1].Value)
    "$SENT$i$SENT"
  })

  $s = [regex]::Replace($s, '\[([^\]]+)\]\(([^)]+)\)', {
    param($m)
    $target = $m.Groups[2].Value
    if ($target.StartsWith("#")) {
      $anchor = $target.Substring(1)
      if (-not $slugs.ContainsKey($anchor)) {
        Fail "$where`: link to '#$anchor' matches no heading in the README."
      }
    }
    '<a href="' + $target + '">' + $m.Groups[1].Value + '</a>'
  })

  $s = [regex]::Replace($s, '\*\*(.+?)\*\*', '<strong>$1</strong>')
  $s = [regex]::Replace($s, '(?<![\*\w])\*([^\*]+)\*(?!\*)', '<em>$1</em>')

  for ($i = 0; $i -lt $codes.Count; $i++) {
    $s = $s.Replace("$SENT$i$SENT", '<code>' + $codes[$i] + '</code>')
  }

  # Anything left over means markup we did not convert. Better a loud build
  # failure than a page with stray backticks or a raw [text](url) on it.
  if ($s.Contains('`'))  { Fail "$where`: unmatched backtick -- unsupported markdown." }
  if ($s.Contains('](')) { Fail "$where`: link syntax we could not convert." }
  if ($s.Contains('**')) { Fail "$where`: unmatched ** -- unsupported markdown." }
  return $s
}

# --- block markup --------------------------------------------------------
# Turns a run of README lines (no "##" headings among them) into HTML.
function Convert-Blocks([string[]]$lines, [hashtable]$slugs, [string]$where) {
  $out = New-Object System.Collections.ArrayList
  $i = 0
  while ($i -lt $lines.Count) {
    $line = $lines[$i]

    if ($line.Trim() -eq "") { $i++; continue }

    # Things we deliberately do not support. Fail rather than mangle.
    if ($line -match '^#{3,}\s')       { Fail "$where`: '###' headings are not supported (line: $line)" }
    if ($line -match '^\s*[\*\+]\s')   { Fail "$where`: use '-' for bullets (line: $line)" }
    if ($line -match '^\s*(```|~~~)')  { Fail "$where`: fenced code blocks are not supported (line: $line)" }
    if ($line -match '^\s*!\[')        { Fail "$where`: images are not supported (line: $line)" }
    if ($line -match '^\s*<')          { Fail "$where`: raw HTML is not supported (line: $line)" }

    # Table -- header row, separator, body rows.
    if ($line.TrimStart().StartsWith("|")) {
      $rows = @()
      while ($i -lt $lines.Count -and $lines[$i].TrimStart().StartsWith("|")) {
        $rows += $lines[$i]; $i++
      }
      if ($rows.Count -lt 3)                { Fail "$where`: table needs a header, a separator and at least one row." }
      if ($rows[1] -notmatch '^\s*\|[\s\|:-]+\|\s*$') { Fail "$where`: table is missing its |---| separator row." }
      function Split-Row([string]$r) { ($r.Trim().Trim('|') -split '\|') | ForEach-Object { $_.Trim() } }
      $head = Split-Row $rows[0]
      [void]$out.Add('<div class="tablewrap"><table>')
      [void]$out.Add('<thead><tr>' + (($head | ForEach-Object { '<th>' + (Convert-Inline $_ $slugs $where) + '</th>' }) -join '') + '</tr></thead>')
      [void]$out.Add('<tbody>')
      foreach ($r in $rows[2..($rows.Count - 1)]) {
        $cells = Split-Row $r
        if ($cells.Count -ne $head.Count) { Fail "$where`: table row has $($cells.Count) cells, header has $($head.Count): $r" }
        [void]$out.Add('<tr>' + (($cells | ForEach-Object { '<td>' + (Convert-Inline $_ $slugs $where) + '</td>' }) -join '') + '</tr>')
      }
      [void]$out.Add('</tbody></table></div>')
      continue
    }

    # Blockquote.
    if ($line.TrimStart().StartsWith(">")) {
      $buf = @()
      while ($i -lt $lines.Count -and $lines[$i].TrimStart().StartsWith(">")) {
        $buf += ($lines[$i].TrimStart().Substring(1).Trim()); $i++
      }
      [void]$out.Add('<blockquote><p>' + (Convert-Inline ($buf -join ' ') $slugs $where) + '</p></blockquote>')
      continue
    }

    # Bullet or numbered list. A wrapped item continues on an indented line.
    if ($line -match '^- ' -or $line -match '^\d+\.\s') {
      $ordered = $line -match '^\d+\.\s'
      $items = @()
      while ($i -lt $lines.Count) {
        $l = $lines[$i]
        if ($l.Trim() -eq "") { break }
        if ($l -match '^- ' -or $l -match '^\d+\.\s') {
          if (($l -match '^\d+\.\s') -ne $ordered) { Fail "$where`: bullet and numbered items in one list (line: $l)" }
          $items += ($l -replace '^(- |\d+\.\s+)', '')
        } elseif ($l -match '^\s+\S') {
          if ($items.Count -eq 0) { Fail "$where`: indented line with no list item above it (line: $l)" }
          $items[$items.Count - 1] += " " + $l.Trim()
        } else { break }
        $i++
      }
      $tag = if ($ordered) { "ol" } else { "ul" }
      [void]$out.Add("<$tag>")
      foreach ($it in $items) { [void]$out.Add('<li>' + (Convert-Inline $it $slugs $where) + '</li>') }
      [void]$out.Add("</$tag>")
      continue
    }

    # Paragraph: everything up to the next blank line or block starter.
    $buf = @()
    while ($i -lt $lines.Count) {
      $l = $lines[$i]
      if ($l.Trim() -eq "") { break }
      if ($l.TrimStart().StartsWith("|") -or $l.TrimStart().StartsWith(">") -or
          $l -match '^- ' -or $l -match '^\d+\.\s') { break }
      $buf += $l.Trim(); $i++
    }
    [void]$out.Add('<p>' + (Convert-Inline ($buf -join ' ') $slugs $where) + '</p>')
  }
  return ($out -join "`n")
}

# --- read and split the README ------------------------------------------
if (-not (Test-Path $SRC)) { Fail "cannot find $SRC" }
$text  = [System.IO.File]::ReadAllText($SRC)
$lines = $text -split "`r?`n"

$title = $null
$intro = @()
$secOrder = @()          # headings in README order
$sections = @{}          # heading -> string[] of body lines
$current = $null

foreach ($l in $lines) {
  if ($l -match '^#\s+(.+)$') {
    if ($title) { Fail "more than one '#' title in the README." }
    $title = $Matches[1].Trim()
    continue
  }
  if ($l -match '^##\s+(.+)$') {
    $current = $Matches[1].Trim()
    if ($sections.ContainsKey($current)) { Fail "duplicate heading '$current' in the README." }
    $sections[$current] = @()
    $secOrder += $current
    continue
  }
  if ($current) { $sections[$current] += $l } else { $intro += $l }
}

if (-not $title) { Fail "the README has no '# ' title line." }

# --- the safety check ----------------------------------------------------
foreach ($h in $secOrder) {
  if ($ORDER -notcontains $h) {
    Fail "the README heading '$h' is not in `$ORDER in build-help.ps1. Add it where it should be read, then re-run. Nothing was written."
  }
}
foreach ($h in $ORDER) {
  if ($secOrder -notcontains $h) {
    Fail "`$ORDER lists '$h' but the README has no such heading. Fix the name in one place or the other. Nothing was written."
  }
}

# Slugs for both the table of contents and any in-page link in the text.
$slugs = @{}
foreach ($h in $secOrder) { $slugs[(Get-Slug $h)] = $h }

# --- build the page ------------------------------------------------------
$version = ""
if (Test-Path $LUA) {
  $lua = [System.IO.File]::ReadAllText($LUA)
  if ($lua -match 'CO\.VERSION\s*=\s*"([0-9.]+)"') { $version = "v" + $Matches[1] }
}

$body = New-Object System.Collections.ArrayList
[void]$body.Add('<div class="intro">' + (Convert-Blocks $intro $slugs "intro") + '</div>')

[void]$body.Add('<nav class="toc"><h2>On this page</h2><ul>')
foreach ($h in $ORDER) {
  [void]$body.Add('<li><a href="#' + (Get-Slug $h) + '">' + (Convert-Inline $h $slugs "toc") + '</a></li>')
}
[void]$body.Add('</ul></nav>')

foreach ($h in $ORDER) {
  [void]$body.Add('<section>')
  [void]$body.Add('<h2 id="' + (Get-Slug $h) + '">' + (Convert-Inline $h $slugs "heading '$h'") + '</h2>')
  [void]$body.Add((Convert-Blocks $sections[$h] $slugs "section '$h'"))
  [void]$body.Add('</section>')
}

$esc = { param($s) $s -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' }

$html = @"
<!DOCTYPE html>
<!--
  GENERATED FILE - DO NOT EDIT.

  Every word on this page comes from gadget/EdgeBreaker/README.md. Edits made
  here are overwritten the next time the page is generated. Change the README,
  then run build-help.ps1 at the repo root (build-vgadget.ps1 runs it too).
-->
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$(& $esc $title) help</title>
<style>
/* Self-contained on purpose: this opens from a file: path on a shop PC with no
   internet. No external CSS, fonts, images or script. Unlike the gadget's own
   dialogs this renders in a real browser, so it is free to scroll and to use
   modern CSS -- but the palette is the dialogs' palette. */
:root {
  --ink: #1f2b36; --muted: #5a6b7a; --page: #f4f6f8; --card: #ffffff;
  --rule: #cbd5dd; --dark: #23303c; --orange: #f76707;
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--page); color: var(--ink);
       font-family: "Segoe UI", Arial, sans-serif; font-size: 19px;
       line-height: 1.6; }
header { background: linear-gradient(#2a3642, #1d2731); color: #fff;
         border-bottom: 4px solid var(--orange); padding: 22px 28px; }
header .name { font-size: 30px; letter-spacing: .5px; }
header .ver { color: #8fa0b0; font-size: 21px; margin-left: 12px; }
header .sub { color: #8fa0b0; font-size: 17px; margin-top: 4px; }
main { max-width: 46em; margin: 0 auto; padding: 32px 28px 96px; }
h2 { font-size: 27px; line-height: 1.25; margin: 48px 0 12px;
     padding-bottom: 8px; border-bottom: 2px solid var(--rule); }
p { margin: 0 0 16px; }
a { color: #1264a3; }
code { font-family: Consolas, "Courier New", monospace; font-size: .88em;
       background: #e8edf1; border: 1px solid #dbe3ea; border-radius: 4px;
       padding: 1px 5px; }
strong { font-weight: 600; }
ul, ol { margin: 0 0 16px; padding-left: 26px; }
li { margin-bottom: 10px; }
blockquote { margin: 0 0 20px; padding: 12px 18px; background: #fff7e0;
             border: 1px solid #d9ad3c; border-left: 5px solid #b8860b;
             border-radius: 8px; color: #6b4e05; }
blockquote p { margin: 0; }
.intro { font-size: 20px; }
.intro > p:first-child { font-size: 22px; color: #33434f; }
.toc { background: var(--card); border: 1px solid var(--rule); border-radius: 10px;
       padding: 16px 22px; margin-top: 32px; }
.toc h2 { font-size: 17px; text-transform: uppercase; letter-spacing: 1px;
          color: var(--muted); border: 0; margin: 0 0 8px; padding: 0; }
.toc ul { list-style: none; padding: 0; margin: 0; columns: 2; }
.toc li { margin-bottom: 6px; break-inside: avoid; }
/* Wide content scrolls in its own box so the page never scrolls sideways. */
.tablewrap { overflow-x: auto; margin: 0 0 20px; }
table { border-collapse: collapse; width: 100%; background: var(--card);
        border: 1px solid var(--rule); font-size: 17px; }
th, td { text-align: left; vertical-align: top; padding: 10px 14px;
         border-bottom: 1px solid var(--rule); }
th { background: var(--dark); color: #fff; font-weight: 600;
     border-bottom: 2px solid var(--orange); }
tbody tr:last-child td { border-bottom: 0; }
tbody tr:nth-child(even) { background: #fafcfd; }
@media (max-width: 700px) {
  body { font-size: 18px; }
  main { padding: 24px 18px 64px; }
  .toc ul { columns: 1; }
}
</style>
</head>
<body>
<header>
  <div class="name">$(& $esc $title)<span class="ver">$version</span></div>
  <div class="sub">Help &mdash; works offline</div>
</header>
<main>
$($body -join "`n")
</main>
</body>
</html>
"@

# CRLF throughout: git checks these files out with CRLF, so writing anything
# else would leave the generated page looking modified straight after a clone.
$html = [regex]::Replace($html, "`r?`n", "`r`n")

if ($Check) {
  # Compare the bytes we WOULD have written against the file on disk. Byte
  # comparison, not text: the encoding and the line endings are part of what
  # this script promises, so a page that differs only in those has still
  # drifted from what a regenerate would produce.
  $want = (New-Object System.Text.UTF8Encoding $false).GetBytes($html)
  if (-not (Test-Path $OUT)) {
    Write-Host "STALE: $OUT is missing. Run: powershell -File build-help.ps1"
    exit 1
  }
  $have = [System.IO.File]::ReadAllBytes($OUT)
  $same = $have.Length -eq $want.Length
  if ($same) {
    for ($i = 0; $i -lt $want.Length; $i++) {
      if ($have[$i] -ne $want[$i]) { $same = $false; break }
    }
  }
  if (-not $same) {
    # Name both inputs: the page also stamps CO.VERSION from the Lua, so a
    # version bump makes it stale with the README untouched -- which is exactly
    # what happened the first time this fired.
    Write-Host "STALE: EdgeBreaker-Help.htm no longer matches README.md / EdgeBreaker.lua."
    Write-Host "       Run: powershell -File build-help.ps1"
    exit 1
  }
  Write-Host "Help page is current ($($ORDER.Count) sections)"
  exit 0
}

[System.IO.File]::WriteAllText($OUT, $html, (New-Object System.Text.UTF8Encoding $false))
Write-Host "Built $OUT ($($ORDER.Count) sections)"
