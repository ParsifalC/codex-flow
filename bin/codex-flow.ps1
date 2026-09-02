$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding { return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false }
function Read-Utf8NoBom([string]$Path) { return [System.IO.File]::ReadAllText($Path, (New-Utf8NoBomEncoding)) }

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$StateDir = Join-Path $CodexHome 'codex-flow'
$SourceFile = Join-Path $StateDir 'source'
$Policy = Join-Path $CodexHome 'codex-flow.toml'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)

function Get-SourceDir {
    if (-not (Test-Path $SourceFile)) { throw 'missing source metadata; reinstall codex-flow' }
    $dir = (Read-Utf8NoBom $SourceFile).Trim()
    if (-not (Test-Path $dir)) { throw "source checkout no longer exists: $dir" }
    return $dir
}
function Get-ScriptPath([string]$Name) {
    $state = Join-Path $StateDir $Name
    if (Test-Path $state) { return $state }
    $repo = Join-Path (Join-Path $RepoRoot 'scripts') $Name
    if (Test-Path $repo) { return $repo }
    if (Test-Path $SourceFile) {
        $src = (Read-Utf8NoBom $SourceFile).Trim()
        $candidate = Join-Path (Join-Path $src 'scripts') $Name
        if (Test-Path $candidate) { return $candidate }
    }
    return $null
}
function Get-PolicyValue([string]$Section, [string]$Key) {
    if (-not (Test-Path $Policy)) { return '' }
    $text = Read-Utf8NoBom $Policy
    $m = [regex]::Match($text, '(?ms)^\[' + [regex]::Escape($Section) + '\]\s*(.*?)(?=^\[[^\r\n]+\]|\z)')
    if (-not $m.Success) { return '' }
    $k = [regex]::Match($m.Groups[1].Value, '(?m)^\s*' + [regex]::Escape($Key) + '\s*=\s*"?([^"\r\n]+)"?\s*$')
    if ($k.Success) { return $k.Groups[1].Value.Trim() }
    return ''
}

$Localization = Get-ScriptPath 'localization.py'
$UiLang = 'en'
if ($Localization -and (Get-Command python3 -ErrorAction SilentlyContinue)) {
    try { $UiLang = (& python3 $Localization --policy $Policy --resolved 2>$null | Out-String).Trim() } catch { $UiLang = 'en' }
}
function L([string]$English, [string]$Chinese) { if ($UiLang -eq 'zh') { return $Chinese } else { return $English } }

if ($args.Count -eq 0 -and [System.Environment]::UserInteractive) {
    $menuScript = Get-ScriptPath 'menu.py'
    if ($menuScript) { & python3 $menuScript; exit $LASTEXITCODE }
}

$cmd = if ($args.Count -gt 0) { [string]$args[0] } else { 'help' }
[string[]]$rest = if ($args.Count -gt 1) { $args[1..($args.Count - 1)] } else { @() }

switch ($cmd) {
    'status' {
        $ui = Get-ScriptPath 'ui.py'
        if (-not $ui) { throw (L 'localized UI helper is missing; reinstall codex-flow' '本地化 UI 组件缺失，请重新安装 codex-flow') }
        & python3 $ui status
        exit $LASTEXITCODE
    }
    'language' {
        $ui = Get-ScriptPath 'ui.py'
        if (-not $ui) { throw (L 'localized UI helper is missing; reinstall codex-flow' '本地化 UI 组件缺失，请重新安装 codex-flow') }
        & python3 $ui language @rest
        exit $LASTEXITCODE
    }
    'strategy' {
        $strategy = Get-ScriptPath 'strategy_runtime.py'
        if (-not $strategy) { throw (L 'strategy runtime is missing; reinstall codex-flow' '策略运行时缺失，请重新安装 codex-flow') }
        & python3 $strategy --policy $Policy @rest
        exit $LASTEXITCODE
    }
    'usage' {
        $telemetry = Get-ScriptPath 'telemetry.py'
        if (-not $telemetry) { throw (L 'telemetry collector not installed; reinstall codex-flow' '遥测组件未安装，请重新安装 codex-flow') }
        [string[]]$usageArgs = if ($rest.Count -eq 0) { @('last') } else { $rest }
        & python3 $telemetry @usageArgs
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
    'doctor' {
        $doctor = Get-ScriptPath 'doctor.py'
        if (-not $doctor) { throw (L 'doctor helper is missing; reinstall codex-flow' '诊断组件缺失，请重新安装 codex-flow') }
        & python3 $doctor
        exit $LASTEXITCODE
    }
    'uninstall' {
        & (Join-Path (Get-SourceDir) 'scripts/uninstall.ps1')
        if (-not $?) { exit 1 }
        exit 0
    }
    'update' {
        $src = Get-SourceDir
        if (-not (Test-Path (Join-Path $src '.git'))) { throw (L 'update requires the original git checkout' '更新需要原始 Git checkout') }
        if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw (L 'git is required for update' '更新需要 git') }
        if (-not (Test-Path $Policy)) { throw (L 'missing policy; reinstall codex-flow' '策略文件缺失，请重新安装 codex-flow') }

        $strategyProfile = Get-PolicyValue strategy profile
        if (-not $strategyProfile) { $strategyProfile = 'efficient' }
        $routingMode = Get-PolicyValue routing mode
        if (-not $routingMode) { $routingMode = 'adaptive' }
        $reviewModifier = Get-PolicyValue modifiers review
        if (-not $reviewModifier) { $reviewModifier = 'auto' }
        $fanoutModifier = Get-PolicyValue modifiers fanout
        if (-not $fanoutModifier) { $fanoutModifier = 'auto' }
        $env:CODEX_FLOW_STRATEGY = $strategyProfile
        $env:CODEX_FLOW_ROUTING_MODE = $routingMode
        $env:CODEX_FLOW_REVIEW_MODIFIER = $reviewModifier
        $env:CODEX_FLOW_FANOUT_MODIFIER = $fanoutModifier
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
        $telemetryNotifications = Get-PolicyValue telemetry notifications
        $env:CODEX_FLOW_TELEMETRY_NOTIFICATIONS = if ($telemetryNotifications) { $telemetryNotifications } else { 'true' }
        $telemetryRetentionDays = Get-PolicyValue telemetry retention_days
        $env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS = if ($telemetryRetentionDays) { $telemetryRetentionDays } else { '30' }

        $before = if (Test-Path (Join-Path $src 'VERSION')) { (Read-Utf8NoBom (Join-Path $src 'VERSION')).Trim() } else { 'unknown' }
        $currBranch = (git -C $src rev-parse --abbrev-ref HEAD 2>$null)
        $currRemote = (git -C $src config --get "branch.$currBranch.remote" 2>$null)
        if (-not $currRemote) { $currRemote = 'origin' }
        if ($currBranch -and $currBranch -ne 'HEAD') { git -C $src pull --ff-only $currRemote $currBranch } else { git -C $src pull --ff-only }
        if ($LASTEXITCODE -ne 0) { throw 'git pull failed' }
        $after = if (Test-Path (Join-Path $src 'VERSION')) { (Read-Utf8NoBom (Join-Path $src 'VERSION')).Trim() } else { 'unknown' }
        & (Join-Path $src 'install.ps1')
        if (-not $?) { exit 1 }
        Write-Host ""
        Write-Host (L "Updated codex-flow $before -> $after" "codex-flow 已更新 $before -> $after") -ForegroundColor Green
        & python3 (Join-Path $src 'scripts/doctor.py')
        exit $LASTEXITCODE
    }
    'overlay' {
        $src = Get-SourceDir
        $overlayBin = Join-Path $StateDir 'bin/FlowPilot'
        if (-not (Test-Path $overlayBin)) { $overlayBin = Join-Path $StateDir 'bin/codex-flow-overlay' }
        if (-not (Test-Path $overlayBin)) { $overlayBin = Join-Path $src 'apps/macos-overlay/bin/FlowPilot' }
        if (-not (Test-Path $overlayBin)) { throw (L 'FlowPilot native overlay is not built.' 'FlowPilot 原生悬浮窗尚未编译。') }
        $sub = if ($rest.Count -gt 0) { $rest[0] } else { 'toggle' }
        if ($sub -in @('start','restart')) {
            try { & $overlayBin stop 2>$null | Out-Null } catch { }
            Start-Process -FilePath $overlayBin -ArgumentList 'start' -WindowStyle Hidden
            Write-Host (L 'FlowPilot launched in background.' 'FlowPilot 已在后台启动。')
        } else {
            & $overlayBin @rest
            exit $LASTEXITCODE
        }
    }
    'help' {
        $ui = Get-ScriptPath 'ui.py'
        if (-not $ui) { throw 'localized UI helper is missing; reinstall codex-flow' }
        & python3 $ui help
        exit $LASTEXITCODE
    }
    '-h' {
        $ui = Get-ScriptPath 'ui.py'; & python3 $ui help; exit $LASTEXITCODE
    }
    '--help' {
        $ui = Get-ScriptPath 'ui.py'; & python3 $ui help; exit $LASTEXITCODE
    }
    default {
        throw (L "unknown command: $cmd" "未知命令：$cmd")
    }
}
