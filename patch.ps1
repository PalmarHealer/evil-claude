<#
  Evil Claude spinner patcher  (Windows PowerShell 5.1+ / PowerShell 7+)

  Usage:
    .\patch.ps1                  patch the Claude Code binary with the word lists
    .\patch.ps1 -Theme <name>    use themes\<name>.txt instead of words.txt
    .\patch.ps1 -Bin <path>      patch a specific binary
    .\patch.ps1 -Restore         put the original binary back from the backup
    .\patch.ps1 -Force           proceed even if the binary looks unfamiliar

  Cloud install (nothing to download - run straight from the repo):
    irm https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.ps1 | iex
  ...with options, e.g. to undo:
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/PalmarHealer/evil-claude/main/patch.ps1))) -Restore
  (in cloud mode the word lists are fetched from the repo too.)

  Notes:
    - Close every running Claude Code session first - Windows won't let you
      overwrite a running .exe.
    - Re-run this after each Claude Code update; updates ship a fresh,
      unpatched binary.
    - The original is saved next to the binary as  claude.exe.evil-backup
#>
[CmdletBinding()]
param(
    [string]$Bin,
    [string]$Theme,
    [switch]$Restore,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Where to fetch the word lists from when run without a checkout (irm ... | iex).
$RawBase = 'https://raw.githubusercontent.com/PalmarHealer/evil-claude/main'

# GitHub requires TLS 1.2; older Windows PowerShell defaults to less.
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

# Directory this script lives in - $null when piped from the web (no file).
$ScriptDir = $null
if ($PSScriptRoot) {
    $ScriptDir = $PSScriptRoot
} elseif ($MyInvocation.MyCommand.Path) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# The two array literals we patch, identified by an ASCII prefix and suffix.
$SPIN_START = '["Accomplishing","Actioning"'
$SPIN_END   = '"Zigzagging"]'
$DONE_START = '["Baked","Brewed","Churned","Cogitated","Cooked","Crunched",'
$DONE_END   = '"Worked"]'

$U8 = New-Object System.Text.UTF8Encoding($false)   # no BOM

function Resolve-ClaudeBin {
    if ($Bin) {
        if (-not (Test-Path -LiteralPath $Bin)) { throw "No such file: $Bin" }
        return (Resolve-Path -LiteralPath $Bin).Path
    }
    $cands = @()
    if ($env:USERPROFILE) { $cands += (Join-Path $env:USERPROFILE '.local\bin\claude.exe') }
    if ($env:HOME)        { $cands += (Join-Path $env:HOME '.local/bin/claude') }
    $gc = Get-Command claude -CommandType Application -ErrorAction SilentlyContinue
    if ($gc) { $cands += $gc.Source }
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    throw "Couldn't find the Claude Code binary. Pass it explicitly with  -Bin <path>"
}

function Read-WordFile([string]$path) {
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($raw in [System.IO.File]::ReadAllLines($path)) {
        $t = $raw.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        $t = ($t -replace '["\\]', '').Trim()
        if ($t -ne '') { $out.Add($t) }
    }
    return ,$out.ToArray()
}

# Returns a local path to one of the repo's text files - the copy next to this
# script, or a freshly-downloaded temp file when running without a checkout.
function Get-ListFile {
    param([string]$RelName)   # e.g. 'words.txt' or 'themes/spooky.txt'
    if ($ScriptDir) {
        $local = Join-Path $ScriptDir ($RelName -replace '/', '\')
        if (Test-Path -LiteralPath $local) { return (Resolve-Path -LiteralPath $local).Path }
    }
    $url = "$RawBase/$RelName"
    $tmp = [System.IO.Path]::GetTempFileName()
    try {
        Invoke-WebRequest -Uri $url -OutFile $tmp -UseBasicParsing
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw "Couldn't read '$RelName' from a checkout or download it from ${url}: $_"
    }
    return $tmp
}

function Get-Lists {
    if ($Theme) {
        $spName = "themes/$Theme.txt";       $sp = Get-ListFile $spName
        $dnName = "themes/$Theme-done.txt"
        try   { $dn = Get-ListFile $dnName }
        catch { $dnName = 'words-done.txt';  $dn = Get-ListFile $dnName }
    } else {
        $spName = 'words.txt';       $sp = Get-ListFile $spName
        $dnName = 'words-done.txt';  $dn = Get-ListFile $dnName
    }
    [pscustomobject]@{
        SpinnerPath = $sp;  SpinnerName = $spName;  Spinner = Read-WordFile $sp
        DonePath    = $dn;  DoneName    = $dnName;  Done    = Read-WordFile $dn
    }
}

function IndexOfBytes([byte[]]$hay, [byte[]]$needle, [int]$from) {
    if ($from -lt 0) { $from = 0 }
    $last = $hay.Length - $needle.Length
    for ($i = $from; $i -le $last; $i++) {
        $match = $true
        for ($j = 0; $j -lt $needle.Length; $j++) {
            if ($hay[$i + $j] -ne $needle[$j]) { $match = $false; break }
        }
        if ($match) { return $i }
    }
    return -1
}

function Make-Literal([string[]]$words) {
    '[' + (($words | ForEach-Object { '"' + $_ + '"' }) -join ',') + ']'
}

# Splices the new array literal in-place (length-preserving, so no extra copy of
# the whole binary). Returns $true on success, $false if the markers weren't found.
function Patch-Region {
    param([byte[]]$Data, [string]$Name, [string]$Start, [string]$End, [string[]]$Words)

    $sb = $U8.GetBytes($Start)
    $eb = $U8.GetBytes($End)
    $s  = IndexOfBytes $Data $sb 0
    if ($s -lt 0) { return $false }
    if ($s -gt 0 -and $Data[$s - 1] -eq 0x5B) { $s = $s - 1 }   # include leading '['
    $e = IndexOfBytes $Data $eb ($s + $sb.Length)
    if ($e -lt 0) { return $false }
    $e = $e + $eb.Length
    $oldLen = $e - $s

    $lit = Make-Literal $Words
    $lb  = $U8.GetBytes($lit)
    if ($lb.Length -gt $oldLen) {
        throw "$Name list needs $($lb.Length) bytes but only $oldLen are available in the binary. Trim the list or use shorter entries."
    }
    if ($lb.Length -lt $oldLen) {
        $lit = $lit.Substring(0, $lit.Length - 1) + (' ' * ($oldLen - $lb.Length)) + ']'
        $lb  = $U8.GetBytes($lit)
    }
    [Array]::Copy($lb, 0, $Data, $s, $lb.Length)   # same byte count - overwrite in place

    $plural = if ($Words.Count -eq 1) { 'y' } else { 'ies' }
    Write-Host ("  {0,-14} {1} entr{2}  ({3}/{4} bytes)" -f $Name, $Words.Count, $plural, $lb.Length, $oldLen)
    return $true
}

# ---------------------------------------------------------------- restore ---
if ($Restore) {
    $target = Resolve-ClaudeBin
    $backup = "$target.evil-backup"
    if (-not (Test-Path -LiteralPath $backup)) { throw "No backup found at $backup" }
    try { Copy-Item -LiteralPath $backup -Destination $target -Force }
    catch { throw "Couldn't restore - is Claude Code still running? Close it and retry. ($_)" }
    Write-Host "Restored the original binary from $backup" -ForegroundColor Green
    return
}

# ------------------------------------------------------------------ patch ---
$target = Resolve-ClaudeBin
$backup = "$target.evil-backup"
$lists  = Get-Lists

Write-Host "Claude binary : $target"
Write-Host ("Word lists    : {0}  ({1} phrases),  {2}  ({3} done-words)" -f `
    $lists.SpinnerName, $lists.Spinner.Count, $lists.DoneName, $lists.Done.Count)
if ($lists.Spinner.Count -eq 0) { throw "$($lists.SpinnerName) has no usable phrases." }
if ($lists.Done.Count    -eq 0) { throw "$($lists.DoneName) has no usable words." }

if (-not [Environment]::Is64BitProcess) {
    Write-Warning "Running in 32-bit PowerShell - patching a large binary here can run out of memory. If it fails, retry from 64-bit PowerShell: $env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
}

$data    = [System.IO.File]::ReadAllBytes($target)
$pristine = (IndexOfBytes $data ($U8.GetBytes($SPIN_START)) 0) -ge 0

if (-not $pristine) {
    if (Test-Path -LiteralPath $backup) {
        Write-Host "Binary already patched (or replaced) - starting from the backup."
        $data     = [System.IO.File]::ReadAllBytes($backup)
        $pristine = (IndexOfBytes $data ($U8.GetBytes($SPIN_START)) 0) -ge 0
        if (-not $pristine -and -not $Force) {
            throw "The backup doesn't contain the expected spinner array either. Re-run with -Force to try anyway."
        }
    } elseif (-not $Force) {
        throw "This binary doesn't contain the spinner array we expect and there's no backup - refusing to touch it. (Claude Code's internals may have changed; re-run with -Force only if you know what you're doing.)"
    }
}

# Refresh the backup from the current pristine bytes (handles Claude updates).
[System.IO.File]::WriteAllBytes($backup, $data)
Write-Host "Backup        : $backup"

Write-Host "Patching..."
if (-not (Patch-Region -Data $data -Name 'spinner' -Start $SPIN_START -End $SPIN_END -Words $lists.Spinner)) {
    throw "Couldn't locate the spinner word array - binary not modified. (Restore with: .\patch.ps1 -Restore)"
}
if (-not (Patch-Region -Data $data -Name 'done-words' -Start $DONE_START -End $DONE_END -Words $lists.Done)) {
    Write-Warning "  done-words array not found - left it alone (the spinner words still got patched)."
}

$tmpFile = "$target.evil-tmp"
[System.IO.File]::WriteAllBytes($tmpFile, $data)
try {
    Move-Item -LiteralPath $tmpFile -Destination $target -Force
} catch {
    Remove-Item -LiteralPath $tmpFile -Force -ErrorAction SilentlyContinue
    throw "Couldn't replace the binary - is a Claude Code session still open? Close them all and re-run. ($_)"
}

Write-Host ""
Write-Host "Evil Claude installed." -ForegroundColor Green
Write-Host "Open a new Claude Code session to see it. Re-run this after Claude updates."
Write-Host "Undo any time:  .\patch.ps1 -Restore"
