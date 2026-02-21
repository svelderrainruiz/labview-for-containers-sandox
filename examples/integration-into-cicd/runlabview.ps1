param(
    [string]$WorkspaceRoot = "C:\workspace",
    [string]$LabVIEWYear = "2020",
    [string]$LabVIEWPath = ""
)

if ([string]::IsNullOrWhiteSpace($LabVIEWPath)) {
    $LabVIEWPath = "C:\Program Files\National Instruments\LabVIEW $LabVIEWYear\LabVIEW.exe"
}

$MassCompileDir = Join-Path $WorkspaceRoot "examples\integration-into-cicd\Test-VIs"

# Verify that LabVIEWPath exists.
if (-not (Test-Path -Path $LabVIEWPath)) {
    Write-Host "Error: LabVIEW executable not found at $LabVIEWPath, exiting..." -ForegroundColor Red
    exit 1
}

$labviewCliCommand = Get-Command -Name LabVIEWCLI -ErrorAction SilentlyContinue
if (-not $labviewCliCommand) {
    Write-Host "Error: LabVIEWCLI is not available on PATH, exiting..." -ForegroundColor Red
    exit 1
}

Write-Host "Running LabVIEWCLI MassCompile with the following parameters:" -ForegroundColor Cyan
Write-Host "DirectoryToCompile: $MassCompileDir"
Write-Host "LabVIEWPath: $LabVIEWPath"

& LabVIEWCLI `
    -LogToConsole TRUE `
    -OperationName MassCompile `
    -DirectoryToCompile "$MassCompileDir" `
    -LabVIEWPath "$LabVIEWPath" `
    -Headless
$massCompileExitCode = $LASTEXITCODE

Write-Host ""; Write-Host "Done running MassCompile operation" -ForegroundColor Green
Write-Host "########################################################################################"
Write-Host ""

if ($massCompileExitCode -ne 0) {
    Write-Host "MassCompile failed with exit code $massCompileExitCode." -ForegroundColor Red
    Write-Host "########################################################################################"
    exit $massCompileExitCode
} else {
    Write-Host "MassCompile completed successfully." -ForegroundColor Green
    Write-Host "########################################################################################"
    exit 0
}
