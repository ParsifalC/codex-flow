$ErrorActionPreference = 'Stop'

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$StateDir = Join-Path $CodexHome 'codex-flow'
$SourceFile = Join-Path $StateDir 'source'
$Policy = Join-Path $CodexHome 'codex-flow.toml'

function Get-SourceDir {
    if (-not (Test-Path $SourceFile)) { throw 'missing source metadata; reinstall codex-flow' }
    $dir = (Get-Content $SourceFile -Raw).Trim()
    if (-not (Test-Path $dir)) { throw "source checkout no longer exists: $dir" }
    return $dir
}
function Get-PolicyValue([string]$Section, [string]$Key) {
    $text = Get-Content $Policy -Raw
    $m = [regex]::Match($text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*(.*?)(?=^\[[^\r\n]+\]|\z)')
    if (-not $m.Success) { return '' }
    $k = [regex]::Match($m.Groups[1].Value, '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*"?([^"\r\n]+)"?\s*$')
    if ($k.Success) { return $k.Groups[1].Value.Trim() }
    return ''
}

$cmd = if ($args.Count -gt 0) { $args[0] } else { 'help' }
$rest = if ($args.Count -gt 1) { @($args[1..($args.Count - 1)]) } else { @() }
switch ($cmd) {
    'status' {
        $src = Get-SourceDir
        $installed = if (Test-Path (Join-Path $StateDir 'version')) { (Get-Content (Join-Path $StateDir 'version') -Raw).Trim() } else { 'unknown' }
        $available = if (Test-Path (Join-Path $src 'VERSION')) { (Get-Content (Join-Path $src 'VERSION') -Raw).Trim() } else { 'unknown' }
        Write-Host 'codex-flow'
        Write-Host "  installed: $installed"
        Write-Host "  checkout:  $src"
        Write-Host "  checkout version: $available"
        if (Test-Path $Policy) {
            Write-Host '  skill:     FlowPilot'
            Write-Host "  parent:    $(Get-PolicyValue parent model_policy) / min effort $(Get-PolicyValue parent min_reasoning_effort)"
            Write-Host "  worker:    $(Get-PolicyValue worker resolved_model) / $(Get-PolicyValue worker min_reasoning_effort)"
            Write-Host "  telemetry: $(Get-PolicyValue telemetry enabled)"
        }
    }
    'usage' {
        $telemetry = Join-Path $StateDir 'telemetry.py'
        if (-not (Test-Path $telemetry)) { throw 'telemetry collector not installed; reinstall codex-flow' }
        $usageMode = if ($rest.Count -gt 0) { $rest[0] } else { 'last' }
        if ($usageMode -ne 'last') { throw 'usage supports: last [--json]' }
        $usageRest = if ($rest.Count -gt 1) { @($rest[1..($rest.Count - 1)]) } else { @() }
        & python3 $telemetry last @usageRest
        exit $LASTEXITCODE
    }
    'benchmark-local' { & python3 (Join-Path (Get-SourceDir) 'scripts/benchmark-local.py') @rest; exit $LASTEXITCODE }
    'benchmark-corpus' {
        $src = Get-SourceDir
        $profile = if ($rest.Count -gt 0) { $rest[0] } else { 'quick' }
        if ($profile -notin @('quick','full')) { throw 'benchmark-corpus profile must be quick or full' }
        $outputRoot = if ($rest.Count -gt 1) { $rest[1] } else { Join-Path (Get-Location) '.codex-flow-benchmark' }
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        & python3 (Join-Path $src 'scripts/materialize-corpus.py') --corpus (Join-Path $src 'benchmark/corpus.json') --profiles (Join-Path $src 'benchmark/profiles.json') --profile $profile --output-dir (Join-Path $outputRoot 'corpus') --manifest (Join-Path $outputRoot 'manifest.json')
        exit $LASTEXITCODE
    }
    'benchmark' { & python3 (Join-Path (Get-SourceDir) 'scripts/run-benchmark.py') @rest; exit $LASTEXITCODE }
    'benchmark-analyze' { & python3 (Join-Path (Get-SourceDir) 'scripts/analyze-benchmark.py') @rest; exit $LASTEXITCODE }
    'doctor' { & (Join-Path (Get-SourceDir) 'scripts/doctor.ps1'); exit $LASTEXITCODE }
    'uninstall' { & (Join-Path (Get-SourceDir) 'scripts/uninstall.ps1'); exit $LASTEXITCODE }
    'update' {
        $src = Get-SourceDir
        if (-not (Test-Path (Join-Path $src '.git'))) { throw 'update requires the original git checkout' }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw 'git is required for update' }
        if (-not (Test-Path $Policy)) { throw 'missing policy; reinstall codex-flow' }

        $env:CODEX_FLOW_PARENT_MODEL_POLICY = Get-PolicyValue parent model_policy
        $env:CODEX_FLOW_PARENT_MIN_MODEL = Get-PolicyValue parent min_model
        $env:CODEX_FLOW_PARENT_MIN_EFFORT = Get-PolicyValue parent min_reasoning_effort
        $env:CODEX_FLOW_WORKER_MODEL_POLICY = Get-PolicyValue worker model_policy
        $env:CODEX_FLOW_WORKER_MODEL = Get-PolicyValue worker model
        $env:CODEX_FLOW_WORKER_MIN_EFFORT = Get-PolicyValue worker min_reasoning_effort
        $env:CODEX_FLOW_MAX_THREADS = Get-PolicyValue runtime max_concurrent_threads
        $env:CODEX_FLOW_MAX_REPAIR_CYCLES = Get-PolicyValue runtime max_repair_cycles
        $telemetryEnabled = Get-PolicyValue telemetry enabled
        $env:CODEX_FLOW_TELEMETRY_ENABLED = if ($telemetryEnabled) { $telemetryEnabled } else { 'true' }

        $before = if (Test-Path (Join-Path $src 'VERSION')) { (Get-Content (Join-Path $src 'VERSION') -Raw).Trim() } else { 'unknown' }
        git -C $src pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }
        $after = if (Test-Path (Join-Path $src 'VERSION')) { (Get-Content (Join-Path $src 'VERSION') -Raw).Trim() } else { 'unknown' }
        & (Join-Path $src 'install.ps1')
        Write-Host "updated $before -> $after"
    }
    default {
        Write-Host @'
codex-flow <command>

Commands:
  status              Show installed version and effective FlowPilot policy
  update              Pull checkout, preserve policy, refresh auto recommendations
  doctor              Verify installation, routing, and telemetry wiring
  usage last          Show the last deterministic task summary
  usage last --json   Show raw telemetry for the last completed task
  benchmark-local     Run built-in benchmark through the local Codex login session
  benchmark-corpus    Materialize the built-in corpus without calling any model
  benchmark           Run a reproducible Codex benchmark manifest
  benchmark-analyze   Analyze benchmark JSONL with quality-first routing
  uninstall           Remove codex-flow-managed files
'@
    }
}
