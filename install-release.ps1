$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$Repo = if ($env:CODEX_FLOW_REPO) { $env:CODEX_FLOW_REPO } else { 'ParsifalC/codex-flow' }
$Channel = if ($env:CODEX_FLOW_UPDATE_CHANNEL) { $env:CODEX_FLOW_UPDATE_CHANNEL } else { 'stable' }
$CodexHome = if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $HOME '.codex' }
$StateDir = Join-Path $CodexHome 'codex-flow'
$VersionsDir = Join-Path $StateDir 'versions'
$TempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('codex-flow-install-' + [Guid]::NewGuid().ToString('N'))

function Fail([string]$Message) { throw "codex-flow installer: $Message" }
function Say([string]$Message) { Write-Host $Message }

if ($Channel -ne 'stable') {
    Fail "first-install bootstrap currently supports the stable channel only; install stable first, then switch update.channel to $Channel"
}

# Windows PowerShell 5 can otherwise negotiate an obsolete TLS version on older systems.
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

$archName = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch -Regex ($archName) {
    '^(ARM64|arm64)$' { $Arch = 'arm64'; break }
    '^(AMD64|x86_64|amd64)$' { $Arch = 'x86_64'; break }
    default { Fail "unsupported CPU architecture: $archName" }
}
$Platform = "windows-$Arch"

New-Item -ItemType Directory -Force -Path $TempRoot,$VersionsDir | Out-Null
try {
    $ManifestPath = Join-Path $TempRoot 'codex-flow-update.json'
    $ManifestUrl = "https://github.com/$Repo/releases/latest/download/codex-flow-update.json"
    Say "-> Resolving latest codex-flow release for $Platform"
    try {
        Invoke-WebRequest -UseBasicParsing -Uri $ManifestUrl -OutFile $ManifestPath
    } catch {
        Fail 'no OTA-enabled stable release is available yet; publish a stable release containing codex-flow-update.json before using the release bootstrap'
    }

    $Manifest = Get-Content -Raw -Encoding UTF8 $ManifestPath | ConvertFrom-Json
    if ($Manifest.channel -ne 'stable') { Fail 'latest release manifest is not stable' }
    $Artifacts = $Manifest.artifacts
    if (-not $Artifacts) { Fail 'release manifest does not contain artifacts' }
    $ArtifactProperty = $Artifacts.PSObject.Properties[$Platform]
    $Artifact = if ($ArtifactProperty) { $ArtifactProperty.Value } else { $null }
    if (-not $Artifact) { Fail "release does not contain artifact for $Platform" }
    if (-not $Artifact.url -or -not $Artifact.sha256 -or -not $Artifact.format) { Fail 'release manifest contains an incomplete artifact entry' }
    if ($Artifact.format -ne 'zip') { Fail "unsupported Windows release archive format: $($Artifact.format)" }

    $Version = [string]$Manifest.version
    if (-not $Version) { Fail 'release manifest does not contain a version' }
    $Archive = Join-Path $TempRoot 'codex-flow.zip'
    Say "-> Downloading codex-flow v$Version"
    Invoke-WebRequest -UseBasicParsing -Uri ([string]$Artifact.url) -OutFile $Archive

    $ActualSha = (Get-FileHash -Algorithm SHA256 -Path $Archive).Hash.ToLowerInvariant()
    $ExpectedSha = ([string]$Artifact.sha256).Trim().ToLowerInvariant()
    if ($ActualSha -ne $ExpectedSha) { Fail 'SHA-256 mismatch for downloaded release' }
    Say 'OK SHA-256 verified'

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $ExtractDir = Join-Path $TempRoot 'package'
    New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
    $ExtractRoot = [System.IO.Path]::GetFullPath($ExtractDir + [System.IO.Path]::DirectorySeparatorChar)
    $Zip = [System.IO.Compression.ZipFile]::OpenRead($Archive)
    try {
        foreach ($Entry in $Zip.Entries) {
            $Target = [System.IO.Path]::GetFullPath((Join-Path $ExtractDir $Entry.FullName))
            if (-not $Target.StartsWith($ExtractRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
                Fail "unsafe archive member: $($Entry.FullName)"
            }
        }
    } finally {
        $Zip.Dispose()
    }
    [System.IO.Compression.ZipFile]::ExtractToDirectory($Archive, $ExtractDir)

    $PackageRoot = Join-Path $ExtractDir "codex-flow-$Version"
    $Installer = Join-Path $PackageRoot 'install.ps1'
    if (-not (Test-Path -LiteralPath $Installer -PathType Leaf)) { Fail 'release package does not contain install.ps1 at the expected root' }

    $VersionDir = Join-Path $VersionsDir $Version
    $StageDir = Join-Path $VersionsDir ('.install-' + $Version + '-' + [Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $PackageRoot -Destination $StageDir

    if (Test-Path -LiteralPath $VersionDir) {
        $ExistingSource = Join-Path $StateDir 'source'
        $CurrentSource = if (Test-Path $ExistingSource) { (Get-Content -Raw -Encoding UTF8 $ExistingSource).Trim() } else { '' }
        if ($CurrentSource -and ([System.IO.Path]::GetFullPath($CurrentSource) -eq [System.IO.Path]::GetFullPath($VersionDir))) {
            $BackupDir = Join-Path $VersionsDir ('.previous-install-' + $Version + '-' + [Guid]::NewGuid().ToString('N'))
            Move-Item -LiteralPath $VersionDir -Destination $BackupDir
            try {
                Move-Item -LiteralPath $StageDir -Destination $VersionDir
                Remove-Item -LiteralPath $BackupDir -Recurse -Force -ErrorAction SilentlyContinue
            } catch {
                if (-not (Test-Path $VersionDir) -and (Test-Path $BackupDir)) { Move-Item -LiteralPath $BackupDir -Destination $VersionDir }
                throw
            }
        } else {
            Remove-Item -LiteralPath $VersionDir -Recurse -Force
            Move-Item -LiteralPath $StageDir -Destination $VersionDir
        }
    } else {
        Move-Item -LiteralPath $StageDir -Destination $VersionDir
    }

    $PersistentInstaller = Join-Path $VersionDir 'install.ps1'
    Say "-> Installing codex-flow v$Version"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $PersistentInstaller
    if ($LASTEXITCODE -ne 0) { Fail "install.ps1 exited with code $LASTEXITCODE" }

    $Doctor = Join-Path $StateDir 'doctor.py'
    if (Test-Path $Doctor) {
        Say '-> Running doctor'
        & python3 $Doctor
        if ($LASTEXITCODE -ne 0) { Fail "doctor exited with code $LASTEXITCODE" }
    }

    Say ''
    Say "OK codex-flow v$Version installation complete"
    Say '   Fully restart Codex to activate the new Agent / Skill / Hook / policy snapshot.'
} finally {
    Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
}
