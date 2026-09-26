$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

# Set FLYWORLD_GODOT when Godot is not on PATH or installed in a custom folder.
$godotPath = $env:FLYWORLD_GODOT
if (-not $godotPath) {
    $godotCommand = Get-Command godot.exe -ErrorAction SilentlyContinue
    if (-not $godotCommand) {
        $godotCommand = Get-Command "Godot_v4.7*.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
    }
    if ($godotCommand) {
        $godotPath = $godotCommand.Source
    }
}
if (-not $godotPath) {
    $godotCandidates = @(
        (Join-Path $PSScriptRoot "Godot.exe"),
        (Join-Path $env:ProgramFiles "Godot\Godot.exe"),
        "C:\Program Files\Godot\Godot.exe"
    )
    $godotPath = $godotCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if (-not $godotPath -or -not (Test-Path -LiteralPath $godotPath)) {
    throw "Godot 4.7 is required to run from source. Players should download the Windows release and launch FLYWORLD.exe beside brain_service.exe: https://github.com/welkinhh/FLYWORLD-MaleCNS/releases/latest"
}

# The ecology runs without Python; Python is only needed for the optional
# MaleCNS neural service when no packaged brain_service.exe is present.
& $godotPath --path $projectRoot
