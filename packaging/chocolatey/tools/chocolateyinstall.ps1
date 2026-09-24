$ErrorActionPreference = 'Stop'

$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$version  = $env:ChocolateyPackageVersion
$url64    = "https://github.com/markussagen/mediastacks/releases/download/v$version/mediastacks-windows-x86_64.zip"

# The checksum is filled in per release by packaging/chocolatey/update-package.ps1
# (or by hand) from the release's mediastacks-windows-x86_64.zip.sha256.
$packageArgs = @{
  PackageName   = 'mediastacks'
  UnzipLocation = $toolsDir
  Url64bit      = $url64
  Checksum64    = '51cac60d2b7a7e9a7201c5b30dad40023bc4ca26ce82376581b2b1f666d9fcae'
  ChecksumType64 = 'sha256'
}

Install-ChocolateyZipPackage @packageArgs
# Chocolatey auto-creates a shim for medias.exe found under $toolsDir.
