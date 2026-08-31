$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Policy = Join-Path $CodexHome 'codex-flow.toml'
$Hooks = Join-Path $CodexHome 'hooks.json'
$Defaults = Join-Path $RootDir 'policy/defaults.toml'
$StateDir = Join-Path $CodexHome 'codex-flow'
$BinDir = if ($env:CODEX_FLOW_BIN_DIR) { $env:CODEX_FLOW_BIN_DIR } else { Join-Path $HOME '.local/bin' }
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Version = if (Test-Path (Join-Path $RootDir 'VERSION')) { (Get-Content (Join-Path $RootDir 'VERSION') -Raw).Trim() } else { 'dev' }

function Get-TomlString([string]$Text, [string]$Section, [string]$Key) {
    $m = [regex]::Match($Text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*(.*?)(?=^\[[^\r\n]+\]|\z)')
    if (-not $m.Success) { return '' }
    $k = [regex]::Match($m.Groups[1].Value, '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*"([^"]+)"\s*$')
    if ($k.Success) { return $k.Groups[1].Value }
    return ''
}
function Get-TomlInt([string]$Text, [string]$Section, [string]$Key) {
    $m = [regex]::Match($Text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*(.*?)(?=^\[[^\r\n]+\]|\z)')
    if (-not $m.Success) { return '' }
    $k = [regex]::Match($m.Groups[1].Value, '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*(\d+)\s*$')
    if ($k.Success) { return $k.Groups[1].Value }
    return ''
}

if (-not (Get-Command python3 -ErrorAction SilentlyContinue)) { throw 'python3 is required' }
$defaultsText = Get-Content $Defaults -Raw
$DefaultWorkerModel = Get-TomlString $defaultsText 'models' 'worker_model'
$DefaultParentPolicy = Get-TomlString $defaultsText 'models' 'parent_policy'
$DefaultParentMinModel = Get-TomlString $defaultsText 'models' 'parent_min_model'
$DefaultMaxThreads = Get-TomlInt $defaultsText 'runtime' 'max_concurrent_threads'
$DefaultMaxRepairs = Get-TomlInt $defaultsText 'runtime' 'max_repair_cycles'

$ParentModelPolicy = if ($env:CODEX_FLOW_PARENT_MODEL_POLICY) { $env:CODEX_FLOW_PARENT_MODEL_POLICY } else { $DefaultParentPolicy }
$ParentMinModel = if ($env:CODEX_FLOW_PARENT_MIN_MODEL) { $env:CODEX_FLOW_PARENT_MIN_MODEL } else { $DefaultParentMinModel }
$ParentMinEffort = if ($env:CODEX_FLOW_PARENT_MIN_EFFORT) { $env:CODEX_FLOW_PARENT_MIN_EFFORT } else { 'high' }
$WorkerModelPolicy = if ($env:CODEX_FLOW_WORKER_MODEL_POLICY) { $env:CODEX_FLOW_WORKER_MODEL_POLICY } else { 'latest-efficient' }
$WorkerRequested = if ($env:CODEX_FLOW_WORKER_MODEL) { $env:CODEX_FLOW_WORKER_MODEL } else { 'auto' }
$WorkerModel = if ($WorkerRequested -eq 'auto') { $DefaultWorkerModel } else { $WorkerRequested }
$WorkerMinEffort = if ($env:CODEX_FLOW_WORKER_MIN_EFFORT) { $env:CODEX_FLOW_WORKER_MIN_EFFORT } else { 'high' }
$MaxThreads = if ($env:CODEX_FLOW_MAX_THREADS) { $env:CODEX_FLOW_MAX_THREADS } else { $DefaultMaxThreads }
$MaxRepairs = if ($env:CODEX_FLOW_MAX_REPAIR_CYCLES) { $env:CODEX_FLOW_MAX_REPAIR_CYCLES } else { $DefaultMaxRepairs }
$TelemetryEnabled = if ($env:CODEX_FLOW_TELEMETRY_ENABLED) { $env:CODEX_FLOW_TELEMETRY_ENABLED } else { 'true' }

if ($ParentMinEffort -notin @('high','xhigh','max')) { throw 'parent minimum effort must be high, xhigh, or max' }
if ($WorkerMinEffort -notin @('high','xhigh','max')) { throw 'worker minimum effort must be high, xhigh, or max' }
if ($TelemetryEnabled -notin @('true','false')) { throw 'CODEX_FLOW_TELEMETRY_ENABLED must be true or false' }

New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'skills/flow-pilot') | Out-Null
New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
if (Test-Path $Config) { Copy-Item $Config "$Config.codex-flow.$Stamp.bak" } else { New-Item -ItemType File -Force -Path $Config | Out-Null }

$text = Get-Content $Config -Raw
$managed = [ordered]@{
    enabled = 'true'
    max_concurrent_threads_per_session = $MaxThreads
    default_subagent_model = '"' + $WorkerModel + '"'
    default_subagent_reasoning_effort = '"' + $WorkerMinEffort + '"'
}
$pattern = '(?ms)^\[agents\]\s*\r?\n(.*?)(?=^\[[^\r\n]+\]\s*$|\z)'
$match = [regex]::Match($text, $pattern)
if ($match.Success) {
    $body = $match.Groups[1].Value
    foreach ($entry in $managed.GetEnumerator()) {
        $keyPattern = '(?m)^\s*' + [regex]::Escape($entry.Key) + '\s*=.*$'
        $line = "$($entry.Key) = $($entry.Value)"
        if ([regex]::IsMatch($body, $keyPattern)) { $body = [regex]::Replace($body, $keyPattern, $line) }
        else { if ($body.Length -gt 0 -and -not $body.EndsWith("`n")) { $body += "`n" }; $body += "$line`n" }
    }
    $text = $text.Substring(0, $match.Groups[1].Index) + $body + $text.Substring($match.Groups[1].Index + $match.Groups[1].Length)
} else {
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n")) { $text += "`n" }
    if ($text.Length -gt 0 -and -not $text.EndsWith("`n`n")) { $text += "`n" }
    $text += "[agents]`n"
    foreach ($entry in $managed.GetEnumerator()) { $text += "$($entry.Key) = $($entry.Value)`n" }
}
Set-Content -Path $Config -Value $text -NoNewline

@"
schema_version = 3

[parent]
model_policy = "$ParentModelPolicy"
min_model = "$ParentMinModel"
min_reasoning_effort = "$ParentMinEffort"
reasoning_policy = "adaptive"
routine_effort = "$ParentMinEffort"
complex_effort = "xhigh"
critical_effort = "max"

[worker]
model_policy = "$WorkerModelPolicy"
model = "$WorkerRequested"
resolved_model = "$WorkerModel"
min_reasoning_effort = "$WorkerMinEffort"
reasoning_policy = "adaptive"
routine_effort = "$WorkerMinEffort"
complex_effort = "xhigh"
critical_effort = "max"

[runtime]
max_concurrent_threads = $MaxThreads
max_repair_cycles = $MaxRepairs

[telemetry]
enabled = $TelemetryEnabled
summary = true
source = "hooks+app-server"
"@ | Set-Content -Path $Policy

Copy-Item (Join-Path $RootDir 'templates/agents/worker-explorer.toml') (Join-Path $CodexHome 'agents/worker-explorer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/agents/worker-implementer.toml') (Join-Path $CodexHome 'agents/worker-implementer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/skills/flow-pilot/SKILL.md') (Join-Path $CodexHome 'skills/flow-pilot/SKILL.md') -Force
Remove-Item (Join-Path $CodexHome 'skills/cost-aware-development') -Force -Recurse -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-explorer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-implementer.toml') -Force -ErrorAction SilentlyContinue

Set-Content -Path (Join-Path $StateDir 'source') -Value $RootDir -NoNewline
Set-Content -Path (Join-Path $StateDir 'version') -Value $Version -NoNewline
Copy-Item (Join-Path $RootDir 'scripts/telemetry.py') (Join-Path $StateDir 'telemetry.py') -Force
Copy-Item (Join-Path $RootDir 'scripts/manage-hooks.py') (Join-Path $StateDir 'manage-hooks.py') -Force
if ($TelemetryEnabled -eq 'true') {
    & python3 (Join-Path $StateDir 'manage-hooks.py') install --hooks $Hooks --script (Join-Path $StateDir 'telemetry.py')
} else {
    & python3 (Join-Path $StateDir 'manage-hooks.py') uninstall --hooks $Hooks
}

Copy-Item (Join-Path $RootDir 'bin/codex-flow.ps1') (Join-Path $BinDir 'codex-flow.ps1') -Force
Copy-Item (Join-Path $RootDir 'bin/codex-flow.cmd') (Join-Path $BinDir 'codex-flow.cmd') -Force

Write-Host "codex-flow $Version installed."
Write-Host "  config:    $Config"
Write-Host "  policy:    $Policy"
Write-Host "  cli:       $(Join-Path $BinDir 'codex-flow.cmd')"
Write-Host '  skill:     FlowPilot (flow-pilot)'
Write-Host "  parent:    $ParentModelPolicy / min=$ParentMinModel / reasoning >= $ParentMinEffort"
Write-Host "  worker:    $WorkerModelPolicy / requested=$WorkerRequested / resolved=$WorkerModel / reasoning >= $WorkerMinEffort"
Write-Host "  telemetry: $TelemetryEnabled (deterministic hooks + app-server; no model call)"
Write-Host '  adaptive effort: high -> xhigh -> max only when justified'
Write-Host ''
Write-Host 'Restart Codex, then use it normally.'
if ($TelemetryEnabled -eq 'true') { Write-Host 'Codex may ask once to trust the new command hooks. If prompted, review/approve them with /hooks.' }

$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if (($userPath -split ';') -contains $BinDir) { Write-Host 'Run: codex-flow status' } else { Write-Host "Add $BinDir to your user PATH to run: codex-flow status" }
