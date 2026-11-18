# Сборка Tutun для Windows в одну папку dist\Tutun: окно, служба, ядра и гео-базы.
# Запуск: powershell -ExecutionPolicy Bypass -File build.ps1 [-Release]
# -Release: ещё и архив выпуска dist\Tutun-Windows-x64.zip + .sha256 (файлы для GitHub, публикует только пользователь).
# Подпись не обязательна: если задан $env:TUTUN_WIN_SIGN_THUMBPRINT (сертификат в хранилище) и есть signtool,
# exe подписываются Authenticode. Без подписи контрольная сумма защищает от битого файла, но не от взлома аккаунта GitHub.
param([switch]$Release)
$ErrorActionPreference = "Stop"
$root = $PSScriptRoot
$dist = Join-Path $root "dist\Tutun"
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Force $dist | Out-Null

$common = @("-c", "Release", "-r", "win-x64", "--self-contained", "true", "-p:DebugType=none", "-o", $dist)
dotnet publish (Join-Path $root "src\Tutun.Service\Tutun.Service.csproj") @common
if ($LASTEXITCODE -ne 0) { throw "служба не собралась" }
dotnet publish (Join-Path $root "src\Tutun.App\Tutun.App.csproj") @common
if ($LASTEXITCODE -ne 0) { throw "окно не собралось" }

Copy-Item (Join-Path $root "licenses") (Join-Path $dist "licenses") -Recurse

$bin = Join-Path $dist "bin"
New-Item -ItemType Directory -Force $bin | Out-Null
foreach ($f in "xray.exe", "sing-box.exe", "libcronet.dll", "geoip.dat", "geosite.dat") {
    Copy-Item (Join-Path $root "vendor\bin\$f") $bin
}
# Переводы интерфейса (таблицы с мака): l10n\*.tsv → dist\Tutun\l10n
$l10n = Join-Path $root "l10n"
if (Test-Path $l10n) {
    New-Item -ItemType Directory -Force (Join-Path $dist "l10n") | Out-Null
    Copy-Item (Join-Path $l10n "*.tsv") (Join-Path $dist "l10n")
}
foreach ($f in "Tutun.exe", "Tutun.Service.exe", "bin\xray.exe", "bin\sing-box.exe") {
    if (-not (Test-Path (Join-Path $dist $f))) { throw "нет $f" }
}
if ($env:TUTUN_WIN_SIGN_THUMBPRINT) {
    $signtool = Get-ChildItem "${env:ProgramFiles(x86)}\Windows Kitsin" -Recurse -Filter signtool.exe -ErrorAction SilentlyContinue | Where-Object FullName -like "*x64*" | Select-Object -First 1
    if (-not $signtool) { throw "нет signtool.exe (Windows SDK)" }
    & $signtool.FullName sign /sha1 $env:TUTUN_WIN_SIGN_THUMBPRINT /fd SHA256 /tr http://timestamp.digicert.com /td SHA256 (Join-Path $dist "Tutun.exe") (Join-Path $dist "Tutun.Service.exe")
    if ($LASTEXITCODE -ne 0) { throw "подпись не удалась" }
}
Write-Output "Готово: $dist"
if ($Release) {
    $zip = Join-Path $root "dist\Tutun-Windows-x64.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    Compress-Archive -Path $dist -DestinationPath $zip -CompressionLevel Optimal
    $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText("$zip.sha256", "$hash  Tutun-Windows-x64.zip`n")
    Write-Output "Выпуск: $zip ($hash)"
}
