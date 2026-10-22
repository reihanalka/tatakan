# One-line installer for Tatakan on Windows:
#   irm https://raw.githubusercontent.com/reihanalka/tatakan/main/windows/install.ps1 | iex
# Downloads the newest Tatakan-Setup-*.exe from GitHub and runs it silently (installs .NET 8 if missing).
# Some releases are Mac only, so it looks for the newest release that has a Windows installer.
$ErrorActionPreference = 'Stop'
$repo = 'reihanalka/tatakan'

if ([Environment]::OSVersion.Version.Major -lt 10) { throw 'Tatakan needs Windows 10 or 11.' }

Write-Host 'Finding the latest Tatakan release...'
$releases = Invoke-RestMethod "https://api.github.com/repos/$repo/releases?per_page=30" -Headers @{ 'User-Agent' = 'tatakan-installer' }
$asset = $releases | Where-Object { -not $_.draft -and -not $_.prerelease } |
    ForEach-Object { $_.assets | Where-Object { $_.name -like 'Tatakan-Setup-*.exe' } } | Select-Object -First 1
if (-not $asset) { throw "No Windows installer found on github.com/$repo/releases." }

$file = Join-Path $env:TEMP $asset.name
Write-Host "Downloading $($asset.name)..."
$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest $asset.browser_download_url -OutFile $file -UseBasicParsing

Write-Host 'Installing...'
$p = Start-Process $file -ArgumentList '/SILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/TASKS=startup' -Wait -PassThru
Remove-Item $file -ErrorAction SilentlyContinue
if ($p.ExitCode -ne 0) { throw "Setup exited with code $($p.ExitCode)." }

$exe = Join-Path $env:LOCALAPPDATA 'Programs\Tatakan\Tatakan.exe'
if (-not (Test-Path $exe)) { $exe = Join-Path $env:ProgramFiles 'Tatakan\Tatakan.exe' }
if (Test-Path $exe) { Start-Process $exe }
Write-Host 'Done. Tatakan is in the notification area (bottom right, maybe under the ^ arrow).'
