# Установщик в один файл: dist\Tutun-Setup-<версия>.exe
# Запуск: powershell -ExecutionPolicy Bypass -File installer\build-installer.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
& powershell -ExecutionPolicy Bypass -File (Join-Path $root "build.ps1")
if ($LASTEXITCODE -ne 0) { throw "сборка не удалась" }
$ver = (Get-Content (Join-Path $root "VERSION") -Raw).Trim()
$iscc = @("$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe", "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe") | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw "нет Inno Setup 6 (winget install JRSoftware.InnoSetup)" }
& $iscc "/DAppVer=$ver" (Join-Path $PSScriptRoot "Tutun.iss")
if ($LASTEXITCODE -ne 0) { throw "Inno Setup не собрал установщик" }
$exe = Join-Path $root "dist\Tutun-Setup-$ver.exe"
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLowerInvariant()
Write-Output "Установщик: $exe ($([math]::Round((Get-Item $exe).Length / 1MB)) МБ, SHA-256 $hash)"
