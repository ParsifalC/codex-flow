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
            Write-Host "  parent:    $(Get-PolicyValue parent model_policy) / min effort $(Get-PolicyValue parent min_reasoning_effort)"
            Write-Host "  worker:    $(Get-PolicyValue worker resolved_model) / $(Get-PolicyValue worker min_reasoning_effort)"
        }
    }
    'benchmark-corpus' {
        $src = Get-SourceDir
        $profile = if ($rest.Count -gt 0) { $rest[0] } else { 'quick' }
        if ($profile -notin @('quick','full')) { throw 'benchmark-corpus profile must be quick or full' }
        $outputRoot = if ($rest.Count -gt 1) { $rest[1] } else { Join-Path (Get-Location) '.codex-flow-benchmark' }
        New-Item -ItemType Directory -Force -Path $outputRoot | Out-Null
        & python3 (Join-Path $src 'scripts/materialize-corpus.py') `
            --corpus (Join-Path $src 'benchmark/corpus.json') `
            --profiles (Join-Path $src 'benchmark/profiles.json') `
            --profile $profile `
            --output-dir (Join-Path $outputRoot 'corpus') `
            --manifest (Join-Path $outputRoot 'manifest.json')
        exit $LASTEXITCODE
    }
    'benchmark' {
        & python3 (Join-Path (Get-SourceDir) 'scripts/run-benchmark.py') @rest
        exit $LASTEXITCODE
    }
    'benchmark-analyze' {
        & python3 (Join-Path (Get-SourceDir) 'scripts/analyze-benchmark.py') @rest
        exit $LASTEXITCODE
    }
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
  status              Show installed version and effective policy
  update              Pull the checkout, preserve explicit policy, refresh auto recommendations
  doctor              Verify installation and routing configuration
  benchmark-corpus    Materialize the built-in corpus without calling any model
  benchmark           Run a reproducible Codex benchmark manifest
  benchmark-analyze   Analyze benchmark JSONL with quality-first cost routing
  uninstall           Remove codex-flow-managed files

benchmark-corpus usage:
  codex-flow benchmark-corpus [quick|full] [output-directory]
'@
    }
}
