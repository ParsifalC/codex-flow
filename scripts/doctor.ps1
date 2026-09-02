$ErrorActionPreference = 'Stop'
& python3 (Join-Path $PSScriptRoot 'doctor.py') @args
exit $LASTEXITCODE
