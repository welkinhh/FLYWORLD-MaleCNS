param(
    [Parameter(Mandatory = $true)][string]$GodotPath,
    [string]$PythonPath = ".venv/Scripts/python.exe"
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $PSScriptRoot
Push-Location $projectRoot
try {
    $godotExe = (Resolve-Path -LiteralPath $GodotPath).Path
    $pythonExe = (Resolve-Path -LiteralPath $PythonPath).Path
    $releaseDir = Join-Path $projectRoot "build/windows"
    New-Item -ItemType Directory -Force -Path $releaseDir | Out-Null
    & $godotExe --headless --path $projectRoot --export-release "Windows Desktop" "$releaseDir/FLYWORLD.exe"
    if ($LASTEXITCODE -ne 0) { throw "Godot export failed." }
    & $pythonExe -m PyInstaller --noconfirm --clean --onefile --windowed `
        --name brain_service --paths brain_service --collect-all flybrain `
        --add-data "brain_service/data/larva;data/larva" `
        --distpath $releaseDir --workpath build/pyinstaller --specpath build `
        brain_service/brain_service.py
    if ($LASTEXITCODE -ne 0) { throw "Brain-service packaging failed." }
    Copy-Item -LiteralPath LICENSE -Destination "$releaseDir/LICENSE.txt"
    Copy-Item -LiteralPath third_party/flybrain/LICENSE -Destination "$releaseDir/FLYBRAIN_LICENSE.txt"
    Copy-Item -LiteralPath docs/DATA_PROVENANCE.md -Destination $releaseDir
    Copy-Item -LiteralPath docs/PLAYING.md -Destination "$releaseDir/README.md"
    $releaseFiles = @("FLYWORLD.exe", "brain_service.exe", "LICENSE.txt", "FLYBRAIN_LICENSE.txt", "DATA_PROVENANCE.md", "README.md") | ForEach-Object { Join-Path $releaseDir $_ }
    Compress-Archive -LiteralPath $releaseFiles -DestinationPath build/FLYWORLD-windows.zip -Force
} finally {
    Pop-Location
}
