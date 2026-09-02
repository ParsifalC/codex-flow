$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding { return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false }
function Read-Utf8NoBom([string]$Path) { return [System.IO.File]::ReadAllText($Path, (New-Utf8NoBomEncoding)) }
function Write-Utf8NoBom([string]$Path, [string]$Value) { [System.IO.File]::WriteAllText($Path, $Value, (New-Utf8NoBomEncoding)) }

$RootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Policy = Join-Path $CodexHome 'codex-flow.toml'
$Hooks = Join-Path $CodexHome 'hooks.json'
$Defaults = Join-Path $RootDir 'policy/defaults.toml'
$Localization = Join-Path $RootDir 'scripts/localization.py'
$StateDir = Join-Path $CodexHome 'codex-flow'
$BinDirState = Join-Path $StateDir 'bin_dir'
$PersistedBinDir = if (Test-Path $BinDirState) { (Read-Utf8NoBom $BinDirState).Trim() } else { '' }
$PreviousBinDir = $PersistedBinDir
$BinDir = if ($env:CODEX_FLOW_BIN_DIR) { $env:CODEX_FLOW_BIN_DIR } elseif ($PersistedBinDir) { $PersistedBinDir } else { Join-Path $HOME '.local/bin' }
$BinDir = [System.IO.Path]::GetFullPath($BinDir)
$Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$Version = if (Test-Path (Join-Path $RootDir 'VERSION')) { (Read-Utf8NoBom (Join-Path $RootDir 'VERSION')).Trim() } else { 'dev' }

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
$defaultsText = Read-Utf8NoBom $Defaults
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
$TelemetryNotifications = if ($env:CODEX_FLOW_TELEMETRY_NOTIFICATIONS) { $env:CODEX_FLOW_TELEMETRY_NOTIFICATIONS } else { 'true' }
$TelemetryRetentionDays = if ($env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS) { $env:CODEX_FLOW_TELEMETRY_RETENTION_DAYS } else { '30' }
$UiLanguage = 'auto'
if (Test-Path $Policy) {
    try { $UiLanguage = (& python3 $Localization --policy $Policy --configured 2>$null | Out-String).Trim() } catch { $UiLanguage = 'auto' }
}
$UiLanguage = (& python3 $Localization --normalize $UiLanguage | Out-String).Trim()

if ($ParentMinEffort -notin @('high','xhigh','max')) { throw 'parent minimum effort must be high, xhigh, or max' }
if ($WorkerMinEffort -notin @('high','xhigh','max')) { throw 'worker minimum effort must be high, xhigh, or max' }
if ($TelemetryEnabled -notin @('true','false')) { throw 'CODEX_FLOW_TELEMETRY_ENABLED must be true or false' }
if ($TelemetryNotifications -notin @('true','false')) { throw 'CODEX_FLOW_TELEMETRY_NOTIFICATIONS must be true or false' }
if ($TelemetryRetentionDays -notmatch '^[1-9][0-9]*$') { throw 'CODEX_FLOW_TELEMETRY_RETENTION_DAYS must be a positive integer' }

New-Item -ItemType Directory -Force -Path (Join-Path $CodexHome 'agents'),(Join-Path $CodexHome 'skills/flow-pilot'),$StateDir,$BinDir | Out-Null
if (Test-Path $Config) { Copy-Item $Config "$Config.codex-flow.$Stamp.bak" } else { New-Item -ItemType File -Force -Path $Config | Out-Null }

$text = Read-Utf8NoBom $Config
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
Write-Utf8NoBom $Config $text

@"
schema_version = 3

[ui]
language = "$UiLanguage"

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
notifications = $TelemetryNotifications
retention_days = $TelemetryRetentionDays
source = "hooks+app-server"
"@ | ForEach-Object { Write-Utf8NoBom $Policy $_ }

Copy-Item (Join-Path $RootDir 'templates/agents/worker-explorer.toml') (Join-Path $CodexHome 'agents/worker-explorer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/agents/worker-implementer.toml') (Join-Path $CodexHome 'agents/worker-implementer.toml') -Force
Copy-Item (Join-Path $RootDir 'templates/skills/flow-pilot/SKILL.md') (Join-Path $CodexHome 'skills/flow-pilot/SKILL.md') -Force
Remove-Item (Join-Path $CodexHome 'agents/luna-explorer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-implementer.toml') -Force -ErrorAction SilentlyContinue

Write-Utf8NoBom (Join-Path $StateDir 'source') $RootDir
Write-Utf8NoBom (Join-Path $StateDir 'version') $Version
Write-Utf8NoBom $BinDirState $BinDir
foreach ($name in @('telemetry.py','manage-hooks.py','menu.py','localization.py','ui.py','doctor.py')) { Copy-Item (Join-Path $RootDir "scripts/$name") (Join-Path $StateDir $name) -Force }
Remove-Item (Join-Path $StateDir 'telemetry_core') -Recurse -Force -ErrorAction SilentlyContinue
Copy-Item (Join-Path $RootDir 'scripts/telemetry_core') (Join-Path $StateDir 'telemetry_core') -Recurse -Force
if ($TelemetryEnabled -eq 'true') { & python3 (Join-Path $StateDir 'manage-hooks.py') install --hooks $Hooks --script (Join-Path $StateDir 'telemetry.py') }
else { & python3 (Join-Path $StateDir 'manage-hooks.py') uninstall --hooks $Hooks }

Copy-Item (Join-Path $RootDir 'bin/codex-flow.ps1') (Join-Path $BinDir 'codex-flow.ps1') -Force
Copy-Item (Join-Path $RootDir 'bin/codex-flow.cmd') (Join-Path $BinDir 'codex-flow.cmd') -Force
if ($PreviousBinDir) {
    $previousFullPath = [System.IO.Path]::GetFullPath($PreviousBinDir); $currentFullPath = [System.IO.Path]::GetFullPath($BinDir)
    if (-not [string]::Equals($previousFullPath, $currentFullPath, [System.StringComparison]::OrdinalIgnoreCase)) {
        Remove-Item (Join-Path $PreviousBinDir 'codex-flow.ps1') -Force -ErrorAction SilentlyContinue
        Remove-Item (Join-Path $PreviousBinDir 'codex-flow.cmd') -Force -ErrorAction SilentlyContinue
    }
}

$UiLang = (& python3 $Localization --policy $Policy --resolved | Out-String).Trim()
function L([string]$English,[string]$Chinese) { if ($UiLang -eq 'zh') { return $Chinese } else { return $English } }
$dispPolicy = $Policy.Replace($HOME, '~'); $dispBin = (Join-Path $BinDir 'codex-flow.cmd').Replace($HOME, '~')

Write-Host ""
Write-Host (L "codex-flow v$Version installed successfully" "codex-flow v$Version 安装成功") -ForegroundColor Green
Write-Host ""
Write-Host (L '  +-- Summary ---------------------------------------------------------+' '  +-- 安装摘要 --------------------------------------------------------+') -ForegroundColor DarkGray
Write-Host "  |  * Policy:     $dispPolicy"
Write-Host "  |  * CLI:        $dispBin"
Write-Host "  |  * Skill:      FlowPilot (flow-pilot)"
Write-Host "  |  * Routing:    parent ($ParentModelPolicy) -> worker ($WorkerModel)"
Write-Host "  |  * Language:   $UiLanguage (effective: $UiLang)"
if ($TelemetryEnabled -eq 'true') { Write-Host "  |  * Telemetry:  [+] enabled (hooks + app-server; ${TelemetryRetentionDays}d retention)" } else { Write-Host '  |  * Telemetry:  [-] disabled' }
Write-Host '  +--------------------------------------------------------------------+' -ForegroundColor DarkGray
Write-Host ""

if ($UiLang -eq 'zh') {
    Write-Host '  +-- [!] 必须完成的后续步骤 ------------------------------------------+' -ForegroundColor Yellow
    Write-Host "  |  [1/3] CLI 可用性：确认 $BinDir 已加入用户 PATH"
    Write-Host '  |  [2/3] 完整重启 Codex：完全退出并重新启动，仅新建任务不够。'
    if ($TelemetryEnabled -eq 'true') { Write-Host '  |  [3/3] 授权 Hooks：在 Codex 中运行 /hooks 并批准 FlowPilot telemetry。' }
    else { Write-Host '  |  [3/3] Hooks：遥测已关闭，无需授权。' }
    Write-Host '  +--------------------------------------------------------------------+' -ForegroundColor Yellow
} else {
    Write-Host '  +-- [!] REQUIRED NEXT STEPS -----------------------------------------+' -ForegroundColor Yellow
    $userPath = [Environment]::GetEnvironmentVariable('Path','User')
    if (($userPath -split ';') -contains $BinDir) {
        Write-Host '  |  [1/3] CLI Availability'
        Write-Host '  |        Run: codex-flow status'
    } else {
        Write-Host '  |  [1/3] PATH Configuration'
        Write-Host "  |        Add $BinDir to your user PATH"
    }
    Write-Host '  |  [2/3] Complete Codex Restart'
    Write-Host '  |        Fully quit Codex and relaunch it. Starting a new task'
    Write-Host '  |        alone is NOT enough to load new hooks and snapshots.'
    if ($TelemetryEnabled -eq 'true') {
        Write-Host '  |  [3/3] Authorize Hooks'
        Write-Host '  |        Run /hooks in Codex and approve FlowPilot telemetry'
        Write-Host '  |        if it is pending approval.'
    } else {
        Write-Host '  |  [3/3] Hooks Status'
        Write-Host '  |        Telemetry is disabled: no hook authorization is required.'
    }
    Write-Host '  +--------------------------------------------------------------------+' -ForegroundColor Yellow
}
Write-Host ""
