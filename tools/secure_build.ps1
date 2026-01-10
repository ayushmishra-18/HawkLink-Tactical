# Secure Build Script for HawkLink
# Builds both apps with code obfuscation and debug info splitting

$projectRoot = "d:\Hawklink Project"
$debugInfoDir = "$projectRoot\debug_info"

# Create debug info directory
if (!(Test-Path $debugInfoDir)) {
    New-Item -ItemType Directory -Path $debugInfoDir | Out-Null
}

Write-Host "--- BUILDING HAWKLINK SECURE RELEASE ---" -ForegroundColor Cyan

# 1. Build Commander Console (Windows)
Write-Host "Building Commander Console (Windows)..." -ForegroundColor Yellow
Set-Location "$projectRoot\commander_console"
flutter build windows --obfuscate --split-debug-info="$debugInfoDir\commander"
if ($LASTEXITCODE -ne 0) { Write-Error "Commander Build Failed"; exit 1 }

# 2. Build Soldier Uplink (Android apk)
Write-Host "Building Soldier Uplink (Android)..." -ForegroundColor Yellow
Set-Location "$projectRoot\hawklink_client"
flutter build apk --obfuscate --split-debug-info="$debugInfoDir\soldier"
if ($LASTEXITCODE -ne 0) { Write-Error "Soldier Build Failed"; exit 1 }

Write-Host "--- SECURE BUILD COMPLETE ---" -ForegroundColor Green
Write-Host "Artifacts are ready for deployment."
