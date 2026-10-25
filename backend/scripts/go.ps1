$GoArguments = $args
$ErrorActionPreference = 'Stop'
$projectRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$toolsPath = Join-Path $projectRoot '.tools'
$portableGo = Join-Path $toolsPath 'go/bin/go.exe'
if (Test-Path -LiteralPath $portableGo) {
    $goExecutable = $portableGo
} else {
    $goExecutable = (Get-Command go -ErrorAction Stop).Source
}
$env:GOPATH = Join-Path $toolsPath 'gopath'
$env:GOCACHE = Join-Path $toolsPath 'go-cache'
& $goExecutable @GoArguments
exit $LASTEXITCODE
