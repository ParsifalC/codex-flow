$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
}
function Read-Utf8NoBom([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, (New-Utf8NoBomEncoding))
}

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$StateDir = Join-Path $CodexHome 'codex-flow'
$SourceFile = Join-Path $StateDir 'source'
$Policy = Join-Path $CodexHome 'codex-flow.toml'

function Get-SourceDir {
    if (-not (Test-Path $SourceFile)) { throw 'missing source metadata; reinstall codex-flow' }
    $dir = (Read-Utf8NoBom $SourceFile).Trim()
    if (-not (Test-Path $dir)) { throw "source checkout no longer exists: $dir" }
    return $dir
}
function Get-PolicyValue([string]$Section, [string]$Key) {
    $text = Read-Utf8NoBom $Policy
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
        $installed = if (Test-Path (Join-Path $StateDir 'version')) { (Read-Utf8NoBom (Join-Path $StateDir 'version')).Trim() } else { 'unknown' }
        $available = if (Test-Path (Join-Path $src 'VERSION')) { (Read-Utf8NoBom (Join-Path $src 'VERSION')).Trim() } else { 'unknown' }
        $dispSrc = $src.Replace($HOME, '~')

        function Write-StatusLine($content) {
            $width = 68
            $pad = [Math]::Max(0, $width - $content.Length)
            Write-Host '  │  ' -ForegroundColor DarkGray -NoNewline
            Write-Host $content -NoNewline
            Write-Host (' ' * $pad) -NoNewline
            Write-Host ' │' -ForegroundColor DarkGray
        }

        Write-Host ""
        Write-Host "📦 codex-flow status" -ForegroundColor Cyan
        Write-Host ""
        Write-Host '  ╭─ Version & Paths ─────────────────────────────────────────────────╮' -ForegroundColor DarkGray
        Write-StatusLine "• Installed:   v$installed"
        Write-StatusLine "• Checkout:    $dispSrc (v$available)"
        Write-StatusLine "• Skill:       FlowPilot (flow-pilot)"
        if (Test-Path $Policy) {
            $pPolicy = Get-PolicyValue parent model_policy
            $pEffort = Get-PolicyValue parent min_reasoning_effort
            $wModel = Get-PolicyValue worker resolved_model
            $wEffort = Get-PolicyValue worker min_reasoning_effort
            $tEnabled = Get-PolicyValue telemetry enabled

            Write-Host '  ├─ Model Routing ───────────────────────────────────────────────────┤' -ForegroundColor DarkGray
            Write-StatusLine "• Parent:      $pPolicy (min effort: $pEffort)"
            Write-StatusLine "• Worker:      $wModel (min effort: $wEffort)"
            if ($tEnabled -eq 'true') {
                Write-StatusLine "• Telemetry:   ● enabled"
            } else {
                Write-StatusLine "• Telemetry:   ○ disabled"
            }
        }
        Write-Host '  ╰───────────────────────────────────────────────────────────────────╯' -ForegroundColor DarkGray
        Write-Host ""
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
    'doctor' { & (Join-Path (Get-SourceDir) 'scripts/doctor.ps1'); if (-not $?) { exit 1 }; exit 0 }
    'uninstall' {
        & (Join-Path (Get-SourceDir) 'scripts/uninstall.ps1')
        if (-not $?) { exit 1 }
        # Do not propagate a stale native-process exit code from helpers used by
        # uninstall.ps1. Successful PowerShell completion is the contract here.
        exit 0
    }
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

        $before = if (Test-Path (Join-Path $src 'VERSION')) { (Read-Utf8NoBom (Join-Path $src 'VERSION')).Trim() } else { 'unknown' }
        git -C $src pull --ff-only
        if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }
        $after = if (Test-Path (Join-Path $src 'VERSION')) { (Read-Utf8NoBom (Join-Path $src 'VERSION')).Trim() } else { 'unknown' }
        & (Join-Path $src 'install.ps1')
        Write-Host ""
        Write-Host "✨ Updated codex-flow $before -> $after" -ForegroundColor Green
        & (Join-Path $src 'scripts/doctor.ps1')
    }
    default {
        Write-Host @'

Usage: codex-flow <command> [options]

  Core Commands
    status              Show installed version and effective FlowPilot policy
    update              Pull checkout, preserve policy, refresh recommendations
    doctor              Verify installation, routing, and telemetry wiring
    usage last          Show the last task telemetry summary (--json for raw)

  Benchmark Commands
    benchmark-local     Run built-in benchmark via local Codex session
    benchmark-corpus    Materialize corpus without calling any model
    benchmark           Run a reproducible Codex benchmark manifest
    benchmark-analyze   Analyze benchmark JSONL with quality-first routing

  Maintenance
    uninstall           Remove codex-flow-managed files and hooks

  💡 Quick Start:
    Run `codex-flow benchmark-local quick` for your first validation run.

'@
    }
}
