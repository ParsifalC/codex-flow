$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('flow-turn-install-' + [guid]::NewGuid().ToString('N'))
$Names = @('CODEX_HOME', 'CODEX_FLOW_BIN_DIR', 'CODEX_FLOW_TEST_TELEMETRY_SCRIPT', 'PYTHONDONTWRITEBYTECODE', 'PYTHONIOENCODING')
$Saved = @{}
foreach ($Name in $Names) { $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name, 'Process') }
try {
    $env:CODEX_HOME = Join-Path $TestRoot 'home'
    $env:CODEX_FLOW_BIN_DIR = Join-Path $TestRoot 'bin'
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:PYTHONIOENCODING = 'utf-8'
    New-Item -ItemType Directory -Force -Path $env:CODEX_HOME | Out-Null
    $global:LASTEXITCODE = 0
    & (Join-Path $Root 'install.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Isolated installer failed' }
    foreach ($Module in @('turn_context', 'turn_result', 'publication')) {
        if (-not (Test-Path (Join-Path $env:CODEX_HOME "codex-flow/telemetry_core/$Module.py"))) {
            throw "Missing installed module: $Module"
        }
    }
    $env:CODEX_FLOW_TEST_TELEMETRY_SCRIPT = Join-Path $env:CODEX_HOME 'codex-flow/telemetry.py'
    & python3 (Join-Path $Root 'tests/test_turn_context_cli.py')
    if ($LASTEXITCODE -ne 0) { throw 'Installed UTF-8/context/disabled-write CLI checks failed' }
    Write-Output 'Turn context isolated Windows installation checks passed.'
} finally {
    foreach ($Name in $Names) { [Environment]::SetEnvironmentVariable($Name, $Saved[$Name], 'Process') }
    if (Test-Path $TestRoot) { Remove-Item -Recurse -Force $TestRoot }
}
