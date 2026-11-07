# Builds Focus in release mode and installs it to $BinDir (default C:\Users\bins).
# Config, projects and themes live in %APPDATA%\focus-editor, so the bin folder doesn't need to be writable by Focus.
param([string]$BinDir = 'C:\Users\bins')
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
Set-Location $repo

if (-not (Get-Command jai -ErrorAction SilentlyContinue)) {
    Write-Error 'Jai compiler not found on PATH.'
    exit 1
}

$started = Get-Date
& jai first.jai - release
if ($LASTEXITCODE -ne 0) { Write-Error "Build failed (exit code $LASTEXITCODE)."; exit 1 }

$exe = Join-Path $repo 'build_release\focus.exe'
if (-not (Test-Path $exe) -or (Get-Item $exe).LastWriteTime -lt $started) {
    Write-Error 'The build did not produce a fresh release executable.'
    exit 1
}

$target = Join-Path $BinDir 'focus.exe'

# A running exe can't be overwritten on Windows, but it can be renamed out of the way.
$copy = @"
`$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force '$BinDir' | Out-Null
if (Test-Path '$target') {
    Remove-Item '$target.old' -Force -ErrorAction SilentlyContinue
    Rename-Item '$target' 'focus.exe.old'
}
Copy-Item '$exe' '$target'
Remove-Item '$target.old' -Force -ErrorAction SilentlyContinue
"@

$writable = $true
try {
    New-Item -ItemType Directory -Force $BinDir | Out-Null
    $probe = Join-Path $BinDir '.focus-write-test'
    [IO.File]::WriteAllText($probe, '')
    Remove-Item $probe
} catch { $writable = $false }

if ($writable) {
    Invoke-Expression $copy
} else {
    Write-Host "$BinDir needs admin rights; approve the UAC prompt to copy focus.exe."
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($copy))
    $p = Start-Process powershell -Verb RunAs -Wait -PassThru -ArgumentList '-NoProfile', '-EncodedCommand', $encoded
    if ($p.ExitCode -ne 0) { Write-Error "Copying to $BinDir failed."; exit 1 }
}

# Install the custom themes, backing up any locally modified copies.
$themes = Join-Path $env:APPDATA 'focus-editor\themes'
$backup = Join-Path $themes ("backups\" + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $themes | Out-Null
Copy-Item (Join-Path $repo 'fonts\liberation-mono.ttf') (Split-Path -Parent $themes) -Force
foreach ($name in 'handmade-hero', 'jblowtorch', 'jblow-nostalgia') {
    $src = Join-Path $repo "config\themes\$name.focus-theme"
    $dst = Join-Path $themes "$name.focus-theme"
    if ((Test-Path $dst) -and ((Get-FileHash $src).Hash -ne (Get-FileHash $dst).Hash)) {
        New-Item -ItemType Directory -Force $backup | Out-Null
        Copy-Item $dst $backup
    }
    Copy-Item $src $dst -Force
}

# Put the bin folder on the user PATH so `focus` works from any terminal.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (($userPath -split ';') -contains $BinDir)) {
    [Environment]::SetEnvironmentVariable('Path', ($userPath.TrimEnd(';') + ";$BinDir"), 'User')
    Write-Host "Added $BinDir to your user PATH (open a new terminal to pick it up)."
}

Write-Host "Installed Focus to $target"
Write-Host "Config and projects: $(Join-Path $env:APPDATA 'focus-editor')"
