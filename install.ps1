# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (C) 2026 Anturno
#
# Installs Anturno on Windows (x64, or arm64 through Windows' emulation):
#
#     irm https://download.anturno.cloud/install.ps1 | iex
#
# It downloads the newest release from github.com/anturno/anturno, checks it
# against the release's SHA256SUMS, unpacks it into
# %LOCALAPPDATA%\Programs\Anturno, for this user only (no administrator), and
# adds it to the Start menu. The app isn't signed; PowerShell doesn't mark what
# it downloads as from the internet, so SmartScreen doesn't stop its first
# open. Its updates download inside the app.
#
# Environment:
#   ANTURNO_RELEASES     where the files are (default: the newest release)
#   ANTURNO_INSTALL_DIR  the folder to install into
#   ANTURNO_NO_OPEN=1    don't open the app afterwards
#
# Published by .github/workflows/desktop-release.yml from apps/desktop/download.

& {
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  # Windows PowerShell 5.1 may not offer TLS 1.2, which GitHub requires.
  [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

  $releases = if ($env:ANTURNO_RELEASES) { $env:ANTURNO_RELEASES } else { 'https://github.com/anturno/anturno/releases/latest/download' }
  $dest = if ($env:ANTURNO_INSTALL_DIR) { $env:ANTURNO_INSTALL_DIR } else { Join-Path $env:LOCALAPPDATA 'Programs\Anturno' }
  $asset = 'Anturno-win-x64.zip'

  function Fail($message) { throw "Anturno: $message" }

  if (-not [Environment]::Is64BitOperatingSystem) { Fail 'needs 64-bit Windows.' }
  if ([Environment]::OSVersion.Version.Build -lt 17763) { Fail 'needs Windows 10 (1809) or later.' }

  # Only the copy this replaces needs to be closed.
  $exe = Join-Path $dest 'Anturno.exe'
  if (Get-Process -Name 'Anturno' -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe }) {
    Fail 'quit Anturno first, then run this again.'
  }

  $tmp = Join-Path ([IO.Path]::GetTempPath()) ("anturno-" + [Guid]::NewGuid())
  New-Item -ItemType Directory -Path $tmp | Out-Null
  try {
    $sumsFile = Join-Path $tmp 'SHA256SUMS'
    Invoke-WebRequest -UseBasicParsing -Uri "$releases/SHA256SUMS" -OutFile $sumsFile
    $sums = Get-Content -Raw $sumsFile
    $expected = ($sums -split "`n" | Where-Object { $_ -match "^([0-9a-f]{64})  $([regex]::Escape($asset))$" } | ForEach-Object { $Matches[1] }) | Select-Object -First 1
    if (-not $expected) { Fail "the release has no checksum for $asset." }

    Write-Host "Downloading $asset"
    $zip = Join-Path $tmp $asset
    Invoke-WebRequest -UseBasicParsing -Uri "$releases/$asset" -OutFile $zip
    if ((Get-FileHash -Algorithm SHA256 $zip).Hash.ToLower() -ne $expected) { Fail "$asset doesn't match its checksum. Nothing was installed." }

    $unpacked = Join-Path $tmp 'unpacked'
    Expand-Archive -Path $zip -DestinationPath $unpacked
    if (-not (Test-Path (Join-Path $unpacked 'Anturno.exe'))) { Fail 'the download holds no Anturno.exe.' }

    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path (Split-Path $dest) -Force | Out-Null
    Move-Item -LiteralPath $unpacked -Destination $dest

    $programs = [Environment]::GetFolderPath('Programs')
    $shell = New-Object -ComObject WScript.Shell
    $link = $shell.CreateShortcut((Join-Path $programs 'Anturno.lnk'))
    $link.TargetPath = $exe
    $link.WorkingDirectory = $dest
    $link.Save()

    Write-Host "Installed Anturno in $dest. Open it from the Start menu."
    if ($env:ANTURNO_NO_OPEN -ne '1') { Start-Process -FilePath $exe }
  } finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  }
}
