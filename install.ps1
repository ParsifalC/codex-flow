$ErrorActionPreference = 'Stop'

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Policy = Join-Path $CodexHome 'codex-flow.toml'
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

$ParentModelPolicy = if ($env:CODEX_FLOW_PARENT_MODEL_POLICY) { $env:CODEX_FLOW_PARENT_MODEL_POLICY } else { 'latest-capable' }
$ParentMinModel = if ($env:CODEX_FLOW_PARENT_MIN_MODEL) { $env:CODEX_FLOW_PARENT_MIN_MODEL } else { 'auto' }
$ParentMinEffort = if ($env:CODEX_FLOW_PARENT_MIN_EFFORT) { $env:CODEX_FLOW_PARENT_MIN_EFFORT } else { 'high' }
$WorkerModelPolicy = if ($env:CODEX_FLOW_WORKER_MODEL_POLICY) { $env:CODEX_FLOW_WORKER_MODEL_POLICY } else { 'latest-efficient' }
$WorkerRequested = if ($env:CODEX_FLOW_WORKER_MODEL) { $env:CODEX_FLOW_WORKER_MODEL } else { 'auto' }
$WorkerModel = if ($WorkerRequested -eq 'auto') { 'gpt-5.6-luna' } else { $WorkerRequested }
$WorkerMinEffort = if ($env:CODEX_FLOW_WORKER_MIN_EFFORT) { $env:CODEX_FLOW_WORKER_MIN_EFFORT } else { 'high' }
$MaxThreads = if ($env:CODEX_FLOW_MAX_THREADS) { $env:CODEX_FLOW_MAX_THREADS } else { '4' }
$MaxRepairs = if ($env:CODEX_FLOW_MAX_REPAIR_CYCLES) { $env:CODEX_FLOW_MAX_REPAIR_CYCLES } else { '2' }

if ($ParentMinEffort -notin @('high','xhigh','max')) { throw 'parent minimum effort must be high, xhigh, or max' }
if ($WorkerMinEffort -notin @('high','xhigh','max')) { throw 'worker minimum effort must be high, xhigh, or max' }

New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'skills/cost-aware-development') | Out-Null
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
schema_version = 2

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
"@ | Set-Content -Path $Policy

Copy-Item (Join-Path $RootDir 'templates/agents/worker-explorer.toml') (Join-Path $CodexHome 'agents/worker-explorer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/agents/worker-implementer.toml') (Join-Path $CodexHome 'agents/worker-implementer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/skills/cost-aware-development/SKILL.md') (Join-Path $CodexHome 'skills/cost-aware-development/SKILL.md') -Force
Remove-Item (Join-Path $CodexHome 'agents/luna-explorer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-implementer.toml') -Force -ErrorAction SilentlyContinue

Write-Host 'codex-flow installed.'
Write-Host "  config: $Config"
Write-Host "  policy: $Policy"
Write-Host "  parent: $ParentModelPolicy / min=$ParentMinModel / reasoning >= $ParentMinEffort"
Write-Host "  worker: $WorkerModelPolicy / requested=$WorkerRequested / resolved=$WorkerModel / reasoning >= $WorkerMinEffort"
Write-Host '  adaptive effort: high -> xhigh -> max only when justified'
Write-Host ''
Write-Host 'Restart Codex, then use it normally.'
