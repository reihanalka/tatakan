# Build Tatakan for Windows and package the installer.
#   .\windows\build.ps1                 build x64 + arm64, then the installer (needs Inno Setup 6)
#   .\windows\build.ps1 -NoInstaller    just the app builds in windows\dist\<arch>
#   .\windows\build.ps1 -Run            build for this PC and start it
param([switch]$NoInstaller, [switch]$Run)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$proj = Join-Path $root 'Tatakan\Tatakan.csproj'
$dist = Join-Path $root 'dist'
[xml]$csproj = Get-Content $proj
$version = $csproj.Project.PropertyGroup.Version | Where-Object { $_ } | Select-Object -First 1

if ($Run) {
  dotnet run --project $proj -c Debug
  exit $LASTEXITCODE
}

Remove-Item -Recurse -Force $dist -ErrorAction SilentlyContinue
foreach ($arch in 'x64', 'arm64') {
  Write-Host "==> Tatakan $version ($arch)"
  dotnet publish $proj -c Release -r "win-$arch" --self-contained false -p:DebugType=none -o (Join-Path $dist $arch)
  if ($LASTEXITCODE -ne 0) { throw "build failed ($arch)" }
}

if ($NoInstaller) { exit 0 }

$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "$env:ProgramFiles\Inno Setup 6\ISCC.exe", "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe") |
  Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "Inno Setup 6 not found. Install it (winget install JRSoftware.InnoSetup) or use -NoInstaller." }
& $iscc "/DAppVersion=$version" (Join-Path $root 'installer\Tatakan.iss')
if ($LASTEXITCODE -ne 0) { throw "installer failed" }
Get-ChildItem $dist -Filter *.exe | ForEach-Object { Write-Host "OK  $($_.FullName)  $([math]::Round($_.Length / 1MB, 1)) MB" }
