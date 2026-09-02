$ErrorActionPreference = 'Stop'

function New-Utf8NoBomEncoding {
    return New-Object -TypeName System.Text.UTF8Encoding -ArgumentList $false
}
function Read-Utf8NoBom([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, (New-Utf8NoBomEncoding))
}
function Write-Utf8NoBom([string]$Path, [string]$Value) {
    [System.IO.File]::WriteAllText($Path, $Value, (New-Utf8NoBomEncoding))
}

$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$Config = Join-Path $CodexHome 'config.toml'
$Hooks = Join-Path $CodexHome 'hooks.json'
$StateDir = Join-Path $CodexHome 'codex-flow'
$BinDirState = Join-Path $StateDir 'bin_dir'
$PersistedBinDir = if (Test-Path $BinDirState) { (Read-Utf8NoBom $BinDirState).Trim() } else { '' }
$BinDir = if ($env:CODEX_FLOW_BIN_DIR) {
    $env:CODEX_FLOW_BIN_DIR
} elseif ($PersistedBinDir) {
    $PersistedBinDir
} else {
    Join-Path $HOME '.local/bin'
}

$hookManager = Join-Path $StateDir 'manage-hooks.py'
if ((Test-Path $hookManager) -and (Get-Command python3 -ErrorAction SilentlyContinue)) {
    & python3 $hookManager uninstall --hooks $Hooks
}

Remove-Item (Join-Path $CodexHome 'agents/worker-explorer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/worker-implementer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/worker-reviewer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-explorer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'agents/luna-implementer.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'codex-flow.toml') -Force -ErrorAction SilentlyContinue
Remove-Item (Join-Path $CodexHome 'skills/flow-pilot') -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item $StateDir -Recurse -Force -ErrorAction SilentlyContinue

# When invoked through codex-flow.cmd, deleting the active batch wrapper before
# it regains control makes cmd.exe report "The batch file cannot be found" and
# return 1 even though uninstall succeeded. Let the wrapper self-delete last.
if ($env:CODEX_FLOW_DEFER_WINDOWS_CLI_DELETE -ne '1') {
    Remove-Item (Join-Path $BinDir 'codex-flow.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item (Join-Path $BinDir 'codex-flow.cmd') -Force -ErrorAction SilentlyContinue
}

if (Test-Path $Config) {
    $text = Read-Utf8NoBom $Config
    $pattern = '(?ms)^\[agents\]\s*\r?\n(.*?)(?=^\[[^\r\n]+\]\s*$|\z)'
    $match = [regex]::Match($text, $pattern)
    if ($match.Success) {
        $keys = @('enabled','max_concurrent_threads_per_session','default_subagent_model','default_subagent_reasoning_effort')
        $lines = @()
        foreach ($line in ($match.Groups[1].Value -split "`r?`n")) {
            $key = if ($line -match '=') { ($line -split '=',2)[0].Trim() } else { '' }
            if ($key -notin $keys) { $lines += $line }
        }
        $body = (($lines -join "`n").Trim("`n"))
        if ($body.Trim()) {
            $body += "`n"
            $text = $text.Substring(0,$match.Groups[1].Index) + $body + $text.Substring($match.Groups[1].Index + $match.Groups[1].Length)
        } else {
            $text = $text.Substring(0,$match.Index) + $text.Substring($match.Index + $match.Length)
            $text = [regex]::Replace($text, "`n{3,}", "`n`n")
        }
        Write-Utf8NoBom $Config $text
    }
}

Write-Host ""
Write-Host "codex-flow uninstalled successfully" -ForegroundColor Green
Write-Host ""
Write-Host '  [+] ' -ForegroundColor Green -NoNewline; Write-Host 'FlowPilot skill and worker agents removed'
Write-Host '  [+] ' -ForegroundColor Green -NoNewline; Write-Host 'Telemetry hooks and shell integration removed'
Write-Host '  [+] ' -ForegroundColor Green -NoNewline; Write-Host "CLI binary ($(Join-Path $BinDir 'codex-flow.cmd')) removed"
Write-Host '  [+] ' -ForegroundColor Green -NoNewline; Write-Host 'Configuration cleaned up (existing backups preserved)'
Write-Host ""
