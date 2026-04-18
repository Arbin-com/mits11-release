param(
  [string]$Target,
  [switch]$Silent,
  [ValidateSet('auto', 'app', 'pat')]
  [string]$Auth = 'auto',
  [switch]$NoBrowserOpen
)

function Fail([string]$Message) {
  Write-Error $Message
  exit 1
}

function Get-WebErrorDetail($ErrorRecord) {
  $response = $ErrorRecord.Exception.Response
  if (-not $response) {
    return $ErrorRecord.Exception.Message
  }

  $statusCode = $null
  $statusDescription = $null
  try { $statusCode = [int]$response.StatusCode } catch {}
  try { $statusDescription = [string]$response.StatusDescription } catch {}

  $body = $null
  try {
    if ($response.Content) {
      $body = $response.Content | Out-String
    } elseif ($response.GetResponseStream) {
      $stream = $response.GetResponseStream()
      if ($stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $body = $reader.ReadToEnd()
      }
    }
  } catch {
  }

  $message = if ($statusCode) { "HTTP $statusCode" } else { "Request failed" }
  if ($statusDescription) {
    $message += " $statusDescription"
  }
  if ($body) {
    $body = $body.Trim()
    if ($body) {
      $message += ": $body"
    }
  }
  return $message
}

function Test-Admin {
  $currentUser = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
  return $currentUser.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-UnixEpochFuture([object]$Epoch) {
  if (-not $Epoch) {
    return $false
  }
  return [int64]$Epoch -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

if (-not (Test-Admin)) {
  Fail "Administrator privileges required. Re-run this script from an elevated PowerShell (Run as Administrator)."
}

if ($Target -and ($Target -notmatch '^(stable|latest|alpha|nightly|[0-9]+\.[0-9]+\.[0-9]+([\-+][^\s]+)?)$')) {
  Fail "Usage: install.ps1 [stable|latest|alpha|nightly|VERSION] [-Auth auto|app|pat] [-Silent] [-NoBrowserOpen]"
}

$baseUrl = "https://arbin-com.github.io/mits11-release"
$script:GitHubAppClientId = "Iv23liqzeRmAZM7t6ZU1"
$script:GitHubToken = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { $null }
$script:AuthKind = $null
$script:ConfigDir = Join-Path $env:LOCALAPPDATA "MITS11"
$script:AppTokenFile = Join-Path $script:ConfigDir "github-app-auth.json"

function Get-Text([string]$Url) {
  try {
    return (Invoke-RestMethod -Uri $Url -UseBasicParsing)
  } catch {
    Fail "Failed to download $Url. $(Get-WebErrorDetail $_)"
  }
}

function Get-Manifest([string]$Version) {
  $url = "$baseUrl/$Version/manifest.json"
  try {
    return Invoke-RestMethod -Uri $url -UseBasicParsing
  } catch {
    Fail "Manifest not found: $url. $(Get-WebErrorDetail $_)"
  }
}

function Parse-GitHubReleaseUrl([string]$Url) {
  if ($Url -match '^https://github\.com/([^/]+)/([^/]+)/releases/download/([^/]+)/([^/]+)$') {
    return [pscustomobject]@{
      owner = $Matches[1]
      repo = $Matches[2]
      tag = $Matches[3]
      asset = $Matches[4]
    }
  }
  return $null
}

function Invoke-GitHubFormPost([string]$Url, [hashtable]$Form) {
  try {
    return Invoke-RestMethod -Method Post -Uri $Url -Body $Form -ContentType "application/x-www-form-urlencoded" -Headers @{ Accept = "application/json" } -UseBasicParsing
  } catch {
    Fail "GitHub authentication request failed: $Url. $(Get-WebErrorDetail $_)"
  }
}

function Invoke-GitHubApiGet([string]$Url) {
  $token = Resolve-GitHubToken
  $headers = @{
    Authorization = "Bearer $token"
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
  }

  try {
    return Invoke-RestMethod -Uri $Url -Headers $headers -UseBasicParsing
  } catch {
    Fail "GitHub API request failed: $Url. $(Get-WebErrorDetail $_)"
  }
}

function Resolve-GitHubAssetApiUrl([string]$Owner, [string]$Repo, [string]$Tag, [string]$AssetName) {
  $release = Invoke-GitHubApiGet -Url "https://api.github.com/repos/$Owner/$Repo/releases/tags/$Tag"
  $asset = $release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1
  if (-not $asset -or -not $asset.url) {
    Fail "Failed to resolve GitHub release asset URL for $Owner/$Repo tag $Tag asset $AssetName"
  }
  return [string]$asset.url
}

function Get-PatToken {
  if ($script:GitHubToken) {
    $script:AuthKind = "pat"
    return $script:GitHubToken
  }

  if ($Silent) {
    Fail "GH_TOKEN or GITHUB_TOKEN is required for authenticated downloads in silent mode."
  }

  try {
    $secureToken = Read-Host "GitHub personal access token" -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureToken)
    try {
      $script:GitHubToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    } finally {
      [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
  } catch {
    Fail "GH_TOKEN or GITHUB_TOKEN is required because an interactive token prompt is not available."
  }

  if (-not $script:GitHubToken) {
    Fail "A GitHub personal access token is required."
  }

  $script:AuthKind = "pat"
  return $script:GitHubToken
}

function Load-AppTokenCache {
  if (-not (Test-Path $script:AppTokenFile)) {
    return $null
  }

  try {
    return Get-Content -Raw -Path $script:AppTokenFile | ConvertFrom-Json
  } catch {
    return $null
  }
}

function Save-AppTokenCache([pscustomobject]$TokenResponse) {
  $now = [DateTimeOffset]::UtcNow
  $payload = [ordered]@{
    access_token = [string]$TokenResponse.access_token
    refresh_token = [string]$TokenResponse.refresh_token
    access_token_expires_at = $now.AddSeconds([int]$TokenResponse.expires_in - 60).ToUnixTimeSeconds()
    refresh_token_expires_at = $now.AddSeconds([int]$TokenResponse.refresh_token_expires_in - 300).ToUnixTimeSeconds()
  }

  New-Item -ItemType Directory -Path $script:ConfigDir -Force | Out-Null
  $payload | ConvertTo-Json | Set-Content -Path $script:AppTokenFile -Encoding utf8
}

function Refresh-AppAccessToken {
  $cache = Load-AppTokenCache
  if (-not $cache -or -not $cache.refresh_token -or -not (Test-UnixEpochFuture $cache.refresh_token_expires_at)) {
    return $null
  }

  $response = Invoke-GitHubFormPost -Url "https://github.com/login/oauth/access_token" -Form @{
    client_id = $script:GitHubAppClientId
    grant_type = "refresh_token"
    refresh_token = [string]$cache.refresh_token
  }

  if ($response.error -or -not $response.access_token -or -not $response.refresh_token) {
    return $null
  }

  Save-AppTokenCache -TokenResponse $response
  $script:GitHubToken = [string]$response.access_token
  $script:AuthKind = "app"
  return $script:GitHubToken
}

function Use-CachedAppToken {
  $cache = Load-AppTokenCache
  if ($cache -and $cache.access_token -and (Test-UnixEpochFuture $cache.access_token_expires_at)) {
    $script:GitHubToken = [string]$cache.access_token
    $script:AuthKind = "app"
    return $script:GitHubToken
  }

  return (Refresh-AppAccessToken)
}

function Open-VerificationUrl([string]$Url) {
  if ($NoBrowserOpen) {
    return
  }

  try {
    Start-Process $Url | Out-Null
  } catch {
  }
}

function Start-GitHubAppDeviceFlow {
  if ($Silent) {
    Fail "GitHub App authentication requires an interactive session unless a cached token is available."
  }

  $deviceResponse = Invoke-GitHubFormPost -Url "https://github.com/login/device/code" -Form @{
    client_id = $script:GitHubAppClientId
  }

  if (-not $deviceResponse.device_code -or -not $deviceResponse.user_code -or -not $deviceResponse.verification_uri) {
    Fail "Failed to start GitHub device flow."
  }

  Write-Host "Authenticate with GitHub to download private release assets."
  Write-Host "Open: $($deviceResponse.verification_uri)"
  Write-Host "Code: $($deviceResponse.user_code)"
  Open-VerificationUrl -Url $deviceResponse.verification_uri

  $interval = if ($deviceResponse.interval) { [int]$deviceResponse.interval } else { 5 }
  $expirySeconds = if ($deviceResponse.expires_in) { [int]$deviceResponse.expires_in } else { 900 }
  $deadline = [DateTimeOffset]::UtcNow.AddSeconds($expirySeconds)

  while ([DateTimeOffset]::UtcNow -lt $deadline) {
    $tokenResponse = Invoke-GitHubFormPost -Url "https://github.com/login/oauth/access_token" -Form @{
      client_id = $script:GitHubAppClientId
      device_code = [string]$deviceResponse.device_code
      grant_type = "urn:ietf:params:oauth:grant-type:device_code"
    }

    if ($tokenResponse.access_token -and $tokenResponse.refresh_token) {
      Save-AppTokenCache -TokenResponse $tokenResponse
      $script:GitHubToken = [string]$tokenResponse.access_token
      $script:AuthKind = "app"
      return $script:GitHubToken
    }

    switch ($tokenResponse.error) {
      "authorization_pending" {
        Start-Sleep -Seconds $interval
        continue
      }
      "slow_down" {
        $interval += 5
        Start-Sleep -Seconds $interval
        continue
      }
      "expired_token" { Fail "GitHub device flow code expired." }
      "access_denied" { Fail "GitHub device flow was denied." }
      default { Fail "GitHub device flow failed: $($tokenResponse.error)" }
    }
  }

  Fail "GitHub device flow timed out."
}

function Choose-AuthenticationMode {
  while ($true) {
    $choice = Read-Host "Authentication required. Choose 1 for GitHub browser login or 2 for personal access token"
    switch ($choice) {
      "1" { return "app" }
      "2" { return "pat" }
    }
  }
}

function Resolve-GitHubToken {
  switch ($Auth) {
    "pat" {
      return (Get-PatToken)
    }
    "app" {
      $cached = Use-CachedAppToken
      if ($cached) {
        return $cached
      }
      return (Start-GitHubAppDeviceFlow)
    }
    "auto" {
      if ($script:GitHubToken) {
        return (Get-PatToken)
      }

      $cached = Use-CachedAppToken
      if ($cached) {
        return $cached
      }

      if ($Silent) {
        Fail "Authentication required. Provide GH_TOKEN/GITHUB_TOKEN or use a cached GitHub App token."
      }

      $selected = Choose-AuthenticationMode
      if ($selected -eq "pat") {
        return (Get-PatToken)
      }
      return (Start-GitHubAppDeviceFlow)
    }
  }
}

function Download-GitHubAsset([string]$Url, [string]$OutFile) {
  $token = Resolve-GitHubToken
  $headers = @{
    Authorization = "Bearer $token"
    Accept = "application/octet-stream"
    "X-GitHub-Api-Version" = "2022-11-28"
  }

  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -Headers $headers -UseBasicParsing
  } catch {
    Fail "Authenticated asset download failed. Auth mode: $Auth. URL: $Url. $(Get-WebErrorDetail $_)"
  }
}

$target = if ($Target) { $Target } else { "stable" }
$version = ""

if ($target -eq "stable" -or $target -eq "latest") {
  $version = (Get-Text "$baseUrl/stable").Trim()
} elseif ($target -eq "alpha") {
  $version = (Get-Text "$baseUrl/alpha").Trim()
} elseif ($target -eq "nightly") {
  $version = (Get-Text "$baseUrl/nightly").Trim()
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
$githubAssetApiUrl = $entry.github_asset_api_url
$githubOwner = $entry.github_owner
$githubRepo = $entry.github_repo
$githubTag = $entry.github_tag
$githubAsset = $entry.github_asset
$checksum = $entry.sha256

if ((-not $githubAssetApiUrl) -and $url) {
  $parsedUrl = Parse-GitHubReleaseUrl -Url $url
  if ($parsedUrl) {
    $githubOwner = $parsedUrl.owner
    $githubRepo = $parsedUrl.repo
    $githubTag = $parsedUrl.tag
    $githubAsset = $parsedUrl.asset
  }
}

if ((-not $url -and -not $githubAssetApiUrl) -or -not $checksum) {
  Fail "Manifest entry for $platform is incomplete"
}

if ($checksum -notmatch '^[a-f0-9]{64}$') {
  Fail "Invalid checksum in manifest for $platform"
}

$tmpDir = Join-Path $env:TEMP ("mits11-" + [guid]::NewGuid().ToString("N"))
$cacheDir = if ($env:MITS11_CACHE_DIR) { $env:MITS11_CACHE_DIR } else { Join-Path $env:TEMP "mits11-cache" }
$zipPath = Join-Path $cacheDir "mits11-$version-$platform.zip"
$extractRoot = Join-Path $tmpDir "extract"
$keepTemp = $env:MITS11_KEEP_TEMP -eq "1"
$installSuccess = $false

try {
  New-Item -ItemType Directory -Path $tmpDir | Out-Null
  New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null

  if (Test-Path $zipPath) {
    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -eq $checksum.ToLower()) {
      Write-Host "Using cached package: $zipPath"
    } else {
      Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
    }
  }

  if (-not (Test-Path $zipPath)) {
    Write-Host "Downloading MITS11 $version ($platform)..."
    if ((-not $githubAssetApiUrl) -and $githubOwner -and $githubRepo -and $githubTag -and $githubAsset) {
      $githubAssetApiUrl = Resolve-GitHubAssetApiUrl -Owner $githubOwner -Repo $githubRepo -Tag $githubTag -AssetName $githubAsset
    }
    if ($githubAssetApiUrl) {
      Download-GitHubAsset -Url $githubAssetApiUrl -OutFile $zipPath
    } else {
      try {
        Invoke-WebRequest -Uri $url -OutFile $zipPath -UseBasicParsing
      } catch {
        Fail "Download failed for $url. $(Get-WebErrorDetail $_)"
      }
    }

    $actual = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    if ($actual -ne $checksum.ToLower()) {
      Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
      Fail "Checksum verification failed"
    }
  }

  New-Item -ItemType Directory -Path $extractRoot | Out-Null
  Expand-Archive -Path $zipPath -DestinationPath $extractRoot -Force

  Write-Host "Running installer..."
  if (-not (Test-Admin)) {
    Fail "Administrator privileges required. Re-run this script from an elevated PowerShell (Run as Administrator)."
  }

  $legacyInstallScript = Get-ChildItem -Path $extractRoot -Recurse -Filter "install-das.ps1" | Select-Object -First 1
  if ($legacyInstallScript) {
    if ($Silent) {
      & $legacyInstallScript.FullName -Silent
    } else {
      & $legacyInstallScript.FullName
    }
    $installExitCode = $LASTEXITCODE
  } else {
    $installerExe = Join-Path $extractRoot "installer.exe"
    if (-not (Test-Path $installerExe)) {
      Fail "Installer not found in package root: $installerExe"
    }

    $installerArgs = @()
    if ($Silent) {
      $installerArgs += "--silent"
    }

    & $installerExe @installerArgs
    $installExitCode = $LASTEXITCODE
  }

  if ($installExitCode -ne 0) {
    Fail "Installer failed with exit code $installExitCode"
  }

  $installSuccess = $true
  Write-Host "Done."
} finally {
  if (-not $keepTemp) {
    if (Test-Path $tmpDir) {
      try {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction Stop
      } catch {
        Write-Warning "Could not remove temp dir: $tmpDir. Try again after reboot."
      }
    }
    if ($installSuccess -and (Test-Path $zipPath)) {
      Remove-Item -Force $zipPath -ErrorAction SilentlyContinue
    }
  }
}
