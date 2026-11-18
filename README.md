# Tutun

VPN-клиент для macOS (Apple Silicon), Windows x64 и Android ARM. Готовые установщики и обновления доступны в [GitHub Releases](https://github.com/r4babit/Tutun/releases/latest).

На всех трёх платформах выпуск можно проверить в настройках «О Tutun». На Android установка APK требует системного подтверждения. Переход с локальной debug-версии Android требует экспорта профилей и отдельной установки релизного приложения из-за разных сертификатов.

## Сборка

В архиве Tutun-build-inputs.zip из выпуска находятся внешние бинарные зависимости с путями относительно корня проекта. Распакуйте его в корень исходников. Файлы зависимостей и готовых пакетов перечислены в SHA256SUMS.

* macOS — Swift Package Manager, команда `scripts/build.sh`. Персональная сборка подписывается ad-hoc. Ключ подписи обновлений хранится у автора.
* Windows — .NET SDK 9 и Inno Setup 6. В каталоге `platforms/windows` запустите `installer/build-installer.ps1`.
* Android — JDK 21 и Android SDK 36. Запустите `scripts/android.sh assembleDebug`. Для сборки с собственным постоянным сертификатом используйте `scripts/android-release.sh`.

Условия лицензий сторонних компонентов находятся в каталоге licenses. Ядра используют [Xray-core](https://github.com/XTLS/Xray-core), [sing-box](https://github.com/SagerNet/sing-box) и [AndroidLibXrayLite](https://github.com/2dust/AndroidLibXrayLite). Источник геобаз — [russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat). Для Android-сборки sing-box см. scripts/build-singbox-android.sh. Сведения об обработке данных находятся в docs/PRIVACY.md.
