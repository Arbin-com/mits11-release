param(
  [string]$Target
)

function Fail([string]$Message) {
  Write-Error $Message
  exit 1
}

function Test-Admin {
  $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Target -and ($Target -notmatch '^(stable|latest|alpha|[0-9]+\.[0-9]+\.[0-9]+([\-+][^\s]+)?)$')) {
  Fail "Usage: install.ps1 [stable|latest|alpha|VERSION]"
}

$baseUrl = "https://arbin-com.github.io/mits11-release"

function Get-Text([string]$Url) {
  try {
    return (Invoke-RestMethod -Uri $Url -UseBasicParsing)
  } catch {
    Fail "Failed to download $Url"
  }
}

function Get-Manifest([string]$Version) {
  $url = "$baseUrl/$Version/manifest.json"
  try {
    return Invoke-RestMethod -Uri $url -UseBasicParsing
  } catch {
    Fail "Manifest not found: $url"
  }
}

$target = if ($Target) { $Target } else { "stable" }
$version = ""

if ($target -eq "stable" -or $target -eq "latest") {
  $version = (Get-Text "$baseUrl/stable").Trim()
} elseif ($target -eq "alpha") {
  $version = (Get-Text "$baseUrl/alpha").Trim()
} else {
  $version = $target
}

if (-not $version) {
  Fail "Failed to resolve version for target: $target"
}

$manifest = Get-Manifest $version

$os = "win"
if (-not [Environment]::Is64BitOperatingSystem) {
  Fail "Unsupported architecture"
}
$platform = "$os-x64"

$entry = $manifest.platforms.$platform
if (-not $entry) {
  Fail "Platform $platform not found in manifest for version $version"
}

$url = $entry.url
$checksum = $entry.sha256

if (-not $url -or -not $checksum) {
  Fail "Manifest entry for $platform is incomplete"
}

if ($checksum -notmatch '^[a-f0-9]{64}$') {
  Fail "Invalid checksum in manifest for $platform"
}

$tmpDir = Join-Path $env:TEMP ("mits11-" + [guid]::NewGuid().ToString("N"))
$zipPath = Join-Path $tmpDir "mits11-$version-$platform.zip"
$extractRoot = Join-Path $tmpDir "extract"
$keepTemp = $env:MITS11_KEEP_TEMP -eq "1"

try {
  New-Item -ItemType Directory -Path $tmpDir | Out-Null

  Write-Host "Downloading MITS11 $version ($platform)..."
  try {
    Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
  } catch {
    Fail "Download failed"
  }

  $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
  if ($actual -ne $checksum.ToLower()) {
    Fail "Checksum verification failed"
  }

  New-Item -ItemType Directory -Path $extractRoot | Out-Null
  Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

  $installScript = Get-ChildItem -Path $extractRoot -Recurse -Filter "install-das.ps1" | Select-Object -First 1
  if (-not $installScript) {
    Fail "Installer not found in package"
  }

  Write-Host "Running installer..."
  if (-not (Test-Admin)) {
    $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { Join-Path $PSHOME "pwsh.exe" } else { Join-Path $PSHOME "powershell.exe" }
    $sentinelPath = Join-Path $tmpDir "install-das.exitcode"
    $cmd = "`"$psExe`" -NoProfile -ExecutionPolicy Bypass -File `"$($installScript.FullName)`""
    $cmd = "$cmd & echo %ERRORLEVEL% > `"$sentinelPath`" & pause"
    Start-Process -FilePath "cmd.exe" -Verb RunAs `
      -ArgumentList "/c", $cmd

    $timeoutSeconds = 7200
    $elapsedSeconds = 0
    $pollSeconds = 2
    while (-not (Test-Path $sentinelPath)) {
      Start-Sleep -Seconds $pollSeconds
      $elapsedSeconds += $pollSeconds
      if ($elapsedSeconds -ge $timeoutSeconds) {
        Fail "Installer did not complete within $timeoutSeconds seconds."
      }
    }

    $exitCode = Get-Content -Path $sentinelPath -ErrorAction SilentlyContinue | Select-Object -First 1
    $parsedExitCode = 0
    if ($null -ne $exitCode -and [int]::TryParse($exitCode, [ref]$parsedExitCode)) {
      if ($parsedExitCode -ne 0) {
        Fail "Installer failed with exit code $parsedExitCode."
      }
    }
  } else {
    & $installScript.FullName
  }

  Write-Host "Done."
} finally {
  if (-not $keepTemp -and (Test-Path $tmpDir)) {
    try {
      Remove-Item -Recurse -Force $tmpDir -ErrorAction Stop
    } catch {
      Write-Warning "Could not remove temp dir: $tmpDir. Try again after reboot."
    }
  }
}
