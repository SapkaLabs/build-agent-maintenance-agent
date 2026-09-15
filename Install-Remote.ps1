[CmdletBinding()]
param(
    [Parameter()]
    [ValidatePattern('^[A-Za-z0-9._-]+$')]
    [string] $SshHost = 'inphizs-mac-mini'
)

$ErrorActionPreference = 'Stop'
$repositoryRoot = $PSScriptRoot
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "build-agent-maintenance-$([Guid]::NewGuid().ToString('N'))"
$archivePath = "$temporaryRoot.tar.gz"
$remoteArchive = "/tmp/build-agent-maintenance-$([Guid]::NewGuid().ToString('N')).tar.gz"
$remoteDirectory = $remoteArchive -replace '\.tar\.gz$', ''
$systemTemporaryRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
$resolvedTemporaryRoot = [System.IO.Path]::GetFullPath($temporaryRoot)

if (-not $resolvedTemporaryRoot.StartsWith($systemTemporaryRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing temporary directory outside the system temporary root: $resolvedTemporaryRoot"
}
if ($remoteDirectory -notmatch '^/tmp/build-agent-maintenance-[a-f0-9]{32}$') {
    throw "Refusing unexpected remote temporary directory: $remoteDirectory"
}

try {
    New-Item -ItemType Directory -Path $temporaryRoot | Out-Null
    Copy-Item -Recurse -LiteralPath (Join-Path $repositoryRoot 'scripts') -Destination $temporaryRoot
    Copy-Item -LiteralPath (Join-Path $repositoryRoot 'README.md') -Destination $temporaryRoot

    & tar -czf $archivePath -C $temporaryRoot .
    if ($LASTEXITCODE -ne 0) { throw "tar failed with exit code $LASTEXITCODE" }

    & scp -- $archivePath "${SshHost}:$remoteArchive"
    if ($LASTEXITCODE -ne 0) { throw "scp failed with exit code $LASTEXITCODE" }

    $installCommand = "mkdir -p '$remoteDirectory' && tar -xzf '$remoteArchive' -C '$remoteDirectory' && /bin/bash '$remoteDirectory/scripts/install.sh'; result=`$?; rm -f '$remoteArchive'; rm -rf '$remoteDirectory'; exit `$result"
    & ssh -- $SshHost $installCommand
    if ($LASTEXITCODE -ne 0) { throw "Remote installer failed with exit code $LASTEXITCODE" }
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -Recurse -Force -LiteralPath $temporaryRoot
    }
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -Force -LiteralPath $archivePath
    }
}
