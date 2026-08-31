$ErrorActionPreference = 'Stop'
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Policy = Join-Path $CodexHome 'codex-flow.toml'
$Hooks = Join-Path $CodexHome 'hooks.json'
$StateDir = Join-Path $CodexHome 'codex-flow'
$Failed = $false
$CodexAvailable = $true
function Ok($m) { Write-Host "[OK] $m" }
function Warn($m) { Write-Warning $m }
function Fail($m) { Write-Host "[FAIL] $m"; $script:Failed = $true }
function Get-PolicyValue([string]$Section, [string]$Key) {
    $text = Get-Content $Policy -Raw
    $m = [regex]::Match($text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*(.*?)(?=^\[[^\r\n]+\]|\z)')
    if (-not $m.Success) { return '' }
    $k = [regex]::Match($m.Groups[1].Value, '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*"?([^"\r\n]+)"?\s*$')
    if ($k.Success) { return $k.Groups[1].Value.Trim() }
    return ''
}

Write-Host 'codex-flow doctor'
if (Get-Command codex -ErrorAction SilentlyContinue) { Ok "Codex CLI found: $(& codex --version 2>$null)" } else { $CodexAvailable = $false; Warn 'Codex CLI not found in PATH; telemetry quota reads and real benchmarks are unavailable' }
if (Test-Path $Config) { Ok 'config.toml found' } else { Fail "missing $Config" }
if (Test-Path $Policy) { Ok 'codex-flow policy found' } else { Fail "missing $Policy" }
foreach ($p in @('agents/worker-explorer.toml','agents/worker-implementer.toml','skills/flow-pilot/SKILL.md')) {
    if (Test-Path (Join-Path $CodexHome $p)) { Ok "$p installed" } else { Fail "$p missing" }
}
if (-not (Test-Path (Join-Path $CodexHome 'skills/cost-aware-development'))) { Ok 'legacy cost-aware-development skill removed' } else { Warn 'legacy cost-aware-development skill still exists; reinstall recommended' }
if (Test-Path $Policy) {
    $schema = [regex]::Match((Get-Content $Policy -Raw), '(?m)^schema_version\s*=\s*(\d+)').Groups[1].Value
    if ($schema -eq '3') { Ok 'policy schema v3' } else { Fail "unsupported policy schema: $schema" }
    $parentEffort = Get-PolicyValue parent min_reasoning_effort
    $workerEffort = Get-PolicyValue worker min_reasoning_effort
    if ($parentEffort -in @('high','xhigh','max')) { Ok "parent minimum reasoning: $parentEffort" } else { Fail "invalid parent effort: $parentEffort" }
    if ($workerEffort -in @('high','xhigh','max')) { Ok "worker minimum reasoning: $workerEffort" } else { Fail "invalid worker effort: $workerEffort" }
    $worker = Get-PolicyValue worker resolved_model
    if ($worker) { Ok "resolved worker: $worker" } else { Fail 'resolved worker is empty' }
    $telemetryEnabled = Get-PolicyValue telemetry enabled
    if ($telemetryEnabled -eq 'true') {
        $collector = Join-Path $StateDir 'telemetry.py'
        $manager = Join-Path $StateDir 'manage-hooks.py'
        if (Test-Path $collector) { Ok 'FlowPilot telemetry collector installed' } else { Fail 'FlowPilot telemetry collector missing' }
        if (Test-Path $manager) {
            & python3 $manager check --hooks $Hooks 2>$null
            if ($LASTEXITCODE -eq 0) { Ok 'FlowPilot lifecycle hooks installed'; Warn 'command hooks may require one-time trust approval in Codex; use /hooks if pending' } else { Fail 'FlowPilot lifecycle hooks missing' }
        } else { Fail 'FlowPilot hook manager missing' }
    } else { Ok 'FlowPilot telemetry disabled by policy' }
    if (Test-Path $Config) {
        $cfg = Get-Content $Config -Raw
        if ($cfg -match ('default_subagent_model\s*=\s*"' + [regex]::Escape($worker) + '"')) { Ok 'Codex worker model matches policy' } else { Fail 'Codex worker model does not match policy' }
        if ($cfg -match ('default_subagent_reasoning_effort\s*=\s*"' + [regex]::Escape($workerEffort) + '"')) { Ok 'Codex worker effort matches policy' } else { Fail 'Codex worker effort does not match policy' }
    }
}
if ($Failed) { exit 1 }
if ($CodexAvailable) { Write-Host 'Ready. FlowPilot routing and deterministic telemetry are installed.' } else { Write-Host 'Ready. Core FlowPilot routing is installed; Codex CLI-dependent telemetry quota reads are unavailable.' }
