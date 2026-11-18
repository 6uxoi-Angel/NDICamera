# NDICamera — iPhone как камера для OBS (NDI)

Приложение для iPhone (iOS 17+): передаёт видео + звук в OBS (Windows 11) по **Wi-Fi** или **USB-кабелю**
через плагин **DistroAV (NDI 6)**. Всё локально, без облака.

## Честные ограничения (важно)

- Код нативный (SwiftUI + NDI SDK). **Сборка требует macOS + Xcode** — на Windows собрать нельзя.
- **Бесплатный способ собрать** — GitHub Actions (macOS-раннеры бесплатны для публичных репозиториев) +
  твой бесплатный Apple ID (Personal Team). Подпись действует **7 дней**, потом переустановка.
- Если нужно «здесь и сейчас, бесплатно, без сборки» — используй готовые бесплатные приложения:
  - **NDI Camera** (NewTek, App Store) — связка NDI + DistroAV 1-в-1;
  - **Camera for OBS** — то же, NDI;
  - **Iriun Webcam** — бесплатно, работает по Wi-Fi и по USB.

## Структура проекта

```
project.yml                        # манифест XcodeGen
src/
  NDICameraApp.swift               # точка входа
  Common/AppModel.swift            # настройки + оркестрация
  Common/Logger.swift              # лог в память + файл
  Camera/CameraManager.swift       # AVCaptureSession, 3 камеры, зум, фокус, фонарик
  Camera/VideoEncoder.swift        # VideoToolbox H.264 (HX), SPS/PPS, статистика
  Camera/AudioCapturer.swift       # 48 кГц → Int16 PCM
  NDI/NDINative.h / .mm            # ObjC++ обёртка над NDI SDK (видео/аудио/tally)
  NDI/NDIBridge.swift              # фасад: отправка, reconnect, tally
  Network/TransportManager.swift   # мониторинг сети, авто-reconnect
  UI/ContentView.swift, SettingsView.swift, LivePreviewView.swift
Docs/WIN11_SETUP.md                # настройка Windows + DistroAV + USB
.github/workflows/build.yml        # бесплатная облачная сборка (macOS runner)
Scripts/bootstrap_ndisdk.sh        # проверка/руководство по установке NDI SDK
```

## Что нужно руками (бесплатно)

1. **NDI SDK** — скачать на https://ndi.video (регистрация бесплатная), раздел *NDI SDK → iOS*.
   Положить так:
   ```
   NDISDK/iOS/libndi_ios.a        (статическая библиотека)
   NDISDK/include/Processing.NDI.Lib.h, Processing.NDI.Structs.h, ...
   ```
2. **GitHub-аккаунт** (бесплатный) и репозиторий (публичный — иначе раннеры платные).
3. **Apple ID** (бесплатный) для подписи.
4. Собрать — см. ниже.

## Бесплатная сборка через GitHub Actions (без локального Xcode)

1. Залей проект (включая `NDISDK/`) в публичный репозиторий GitHub.
2. Workflow `.github/workflows/build.yml` соберёт `.ipa` на macOS-раннере.
3. В настройках репозитория добавь секреты для подписи (иначе получится несобранный IPA):
   - `APPLE_ID` — твой Apple ID
   - `APPLE_APP_SPECIFIC_PASSWORD` — пароль приложения (appleid.apple.com → «Пароли для приложений»)
   - `TEAM_ID` — «Team ID» из appleid.apple.com (Account → Membership)
4. Скачай артефакт `NDICamera.ipa` со страницы Actions.
5. Установи:
   - iPhone → провод → **Система → Управление VPN и устройствами** → доверяй разработчика;
   - открой файл .ipa любым способом (AirDrop/обмен/фильм) и установи.
6. **Раз в 7 дней** сборка истекает — повтори шаги 4–5 (workflow можно запускать вручную).

> Эмулятор/симулятор недоступен — только реальный iPhone. Это нормально для бесплатной подписи.

## Сборка на Mac (если появится)

```bash
brew install xcodegen
./Scripts/bootstrap_ndisdk.sh   # проверит SDK
xcodegen generate
open NDICamera.xcodeproj       # выбери TEAM (бесплатный Apple ID) в Signing & Capabilities
# Run → устройство
```

## ТЗ → реализация

| Требование | Где |
|---|---|
| NDI HX (H.264, ~4–25 Мбит/с) | `VideoEncoder.swift` + `NDINative.mm` (FOURCC_TYPE_H264) |
| 720p/1080p/4K, 30/60 fps | настройки, применяются при старте |
| Фронт/тыл/ультраширик | переключение на лету (`CameraManager`) |
| Tap-to-focus, блокировка экспозиции, фонарик, зум | жесты на превью |
| Авто-discovery mDNS + Discovery Server + ручной IP | `NDINative.mm`, режимы в настройках |
| Выбор интерфейса (Wi-Fi/USB) | поле «Локальный IP» |
| Аудио 48 кГц | `AudioCapturer.swift` |
| Tally (красная/зелёная рамка) | обратный канал `NDINative.mm` + `TallyBorder` |
| Экран не гаснет, корректная остановка | `keepAwake`, AppModel |
| Авто-reconnect | `TransportManager.swift` |
| Лог | `Logger.swift` + экран «Лог» |
| Имя источника редактируемое | настройки → Источник NDI |

## Известные места для отладки

- **Чёрный экран в OBS** → переключи «Формат H.264»: AVCC ↔ Annex-B.
- **OBS не видит источник** → проверь firewall (см. WIN11_SETUP), переключи транспорт mDNS → ручной IP.
- **Звук рассинхронизирован** → не меняй fps/битрейт во время трансляции, останови и запусти заново.
- **NDI SDK требует лицензию** → если в SDK есть `NDIlib_set_license`, вызови его перед `NDIlib_initialize()`
  (раскомментируй в `NDINative.mm`).
