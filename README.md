# NDICamera — iPhone как камера для OBS (NDI)

Приложение для iPhone (iOS 17+): передаёт видео + звук в OBS (Windows 11) по **Wi-Fi**
через плагин **DistroAV (NDI 6)**. Всё локально, без облака, без платных сервисов.

---

## Последние изменения (2026-11-21)

### Исправлено
- **Сборка (Codemagic)**:
  - `Logger.swift` — `signal()` принимает только C-функцию без захватов (глобальный
    `ndiSignalHandler` + pre-opened fd, убран `_exit`, чтобы сохранялись `.ips`);
  - `NDINative.mm` — присваивание параметру внутри блока (`__block`), регистр
    заголовка `<Processing.NDI.structs.h>`, явные `self->` в блоках;
  - `AudioCapturer.swift` — `channelData[ch]` не опционален (убран `if let`);
  - `CameraManager.swift` — `isVideoMirrored` (новый SDK), `case .unknown` в switch;
  - `TransportManager.swift` — у `NWPath.Status` нет `rawValue` (строковое описание).
- **Крэш SIGSEGV на потоке `ndis:async`** (проявлялся на задней камере):
  - **Причина**: NDI SDK читает кадр асинхронно и вправе держать указатель на
    `NDIlib_video_frame_v2_t` **до следующего send/destroy**. Мы строили структуру
    на стеке dispatch-блока — после возврата из блока эта память отдаётся системе
    и перезаписывается → SDK читал мусор → `KERN_INVALID_ADDRESS`.
  - **Решение**: структуры видео/аудио-кадров перенесены в ivar'ы объекта
    (`_videoFrame`, `_audioFrame` — живут всё время, как в примерах NewTek);
    буферы данных удерживаются **пулом сильных ссылок** (`_heldBuffers`, до 16
    последних), чтобы SDK успевал прочитать их при любой задержке.
  - Плюс: `NDIlib_initialize` один раз на процесс (убран `NDIlib_destroy()` при
    остановке); все операции с SDK сериализованы на одной очереди с перепроверкой
    состояния; `timecode`/fps берутся из настроек (а не 0/60000:1001).
- **NDI не виден в OBS** — в `Info.plist` добавлены `NSLocalNetworkUsageDescription`
  и `NSBonjourServices` (`_ndi._tcp/_udp`). Без этого iOS 14+ блокирует mDNS-
  discovery локальной сети (диалог «Локальная сеть» не появлялся).
- **VideoEncoder** — построчное копирование NV12 с учётом `bytesPerRow`
  (картинка не «перекашивается»), контроль формата 420f/420v.
- **AudioCapturer** — FLTP-пакеты отправляются без межблочного interleave.
- **CameraManager** — выбор формата по ближайшему разрешению (720p больше не
  превращается в 4K), полный реконфиг при смене камеры.
- **TransportManager/AppModel** — reconnect только при реальной смене сети
  (сигнатура интерфейсов); монитор сети удерживается в AppModel (раньше умирал
  сразу после `setup()`); статистика fps/битрейта из реальных счётчиков.
- **USB-трансляция** — `NetworkInterfaces.swift` (детект Wi-Fi/USB через
  `getifaddrs`); в настройках «Транспорт → Интерфейс» Picker вместо мёртвого
  поля «Локальный IP»; лог выбора интерфейса; индикатор сетевого пути
  «USB · ip / Wi-Fi · ip» на главном экране во время трансляции.
  Ограничение SDK: привязка сендера к интерфейсу невозможна — для гарантии
  USB трафик должен идти при выключенном Wi-Fi на iPhone (см. README → USB).

### Что нужно проверить / зафиксить
1. **Собрать новый IPA** (Codemagic, ветка `main`) и установить через AltStore.
2. **Задняя камера**: проверить START/STOP/START, переключение front↔back.
   Раньше — SIGSEGV в `ndis:async` (исправлено, нужна проверка).
3. **OBS/DistroAV**: при первом запуске iOS спросит доступ к «Локальная сеть» —
   разрешить; проверить появление источника в списке NDI.
4. **Tally**: проверить красную/зелёную рамку (OBS-источник должен получать
   обратный канал).
5. **Логи**: `Documents/log.txt` и `Documents/crash.log` лежат на iPhone в
   «Файлы» → «На моём iPhone» → «NDICamera» (включены UIFileSharingEnabled /
   LSSupportsOpeningDocumentsInPlace). При проблемах прислать их.
6. **Желательно**: собрать с dSYM (Debug) и символизировать `.ips` — сейчас
   адреса в крашах без имён функций.

---

## Честные ограничения (важно)

- Код нативный (SwiftUI + NDI SDK). **Сборка требует macOS + Xcode** — на Windows собрать нельзя.
- Бесплатная сборка: **Codemagic free** (macOS, 500 мин/мес) — `codemagic.yaml`.
  GitHub Actions на этом аккаунте не подходит: macOS-раннеры мгновенно отменяются.
- Подпись бесплатным Apple ID через **AltStore** действует **7 дней**, потом переустановка.
- **Full NDI (NV12) без сжатия**: SDK 6.3.2 для iOS не умеет HX/H.264.
  Полоса: 1080p60 ≈ 1.5–2 Гбит/с — Wi-Fi только 720p30.
- **USB-кабель** убирает проблемы Wi-Fi (роутер, занятость эфира, VLAN), но скорость
  кабеля — тоже лимит: iPhone SE 2 (Lightning) — это USB 2.0 ≈ 300–350 Мбит/с
  реальных, т.е. **по-прежнему только 720p30** (1080p30 ≈ 750 Мбит/с не влезает).
  1080p по USB возможен только на iPhone с USB 3 (iPhone 15+) — либо с HX-сжатием,
  которого в бесплатном iOS-SDK нет.

## Трансляция по USB (кабель)

Важно: NDI SDK для iOS (6.3.2) **не умеет привязываться к конкретному интерфейсу**
(в `NDIlib_send_create_t` нет поля IP). Поэтому «USB-режим» достигается так:

1. Подключи iPhone к ПК кабелем.
2. На iPhone: **Настройки → Personal Hotspot → включить** (режим USB; Wi-Fi можно не включать).
3. В приложении: **Настройки → Транспорт → Интерфейс** → выбери **USB/провод (IP)**.
4. **Выключи Wi-Fi на iPhone** — иначе NDI выберет Wi-Fi-маршрут (SDK сам решает, куда
   слать, по таблице маршрутизации; при двух активных интерфейсах можно попасть в Wi-Fi).
5. Windows: в `ipconfig /all` появится адаптер «Remote NDIS…» с IP (обычно
   `192.168.137.x`). Телефон и ПК должны быть в одном диапазоне сети.
6. OBS → DistroAV → источник «NDI» — должен появиться (как и по Wi-Fi). Firewall:
   разрешить входящий UDP 5960–5963 и 5353 для этого адаптера.
7. Разрешение держи **720p30** — это потолок для USB 2.0. Если интересно 1080p —
   только iPhone 15+ (USB 3) или переход на другое решение со сжатием.

Отличия от Wi-Fi: нет потерь от роутера/эфира, ниже задержка, стабильнее битрейт.
Но сам пользовательский опыт тот же (NDI-источник в OBS).

## Структура проекта

```
project.yml                        # манифест XcodeGen
codemagic.yaml                     # сборка IPA (unsigned) на Codemagic
Scripts/split_join_sdk.py          # NDI SDK: gzip-части ↔ libndi_ios.a
Scripts/bootstrap_ndisdk.sh        # проверка/установка NDI SDK
src/
  NDICameraApp.swift               # точка входа
  Common/AppModel.swift            # настройки + оркестрация + статистика
  Common/NetworkInterfaces.swift   # детект Wi-Fi/USB-интерфейсов (getifaddrs)
  Common/Logger.swift              # лог в память + файл + crash-хендлеры
  Camera/CameraManager.swift       # AVCaptureSession, 3 камеры, зум, фокус, фонарик
  Camera/VideoEncoder.swift        # NV12 (Full NDI) + статистика
  Camera/AudioCapturer.swift       # 48 кГц → float32 планарный (FLTP)
  NDI/NDINative.h / .mm            # ObjC++ обёртка над NDI SDK (видео/аудио/tally)
  NDI/NDIBridge.swift              # фасад: отправка, reconnect, tally
  Network/TransportManager.swift   # мониторинг сети, авто-reconnect
  UI/ContentView.swift, SettingsView.swift, LivePreviewView.swift
```

## Сборка на Codemagic (бесплатно)

1. Пуш в `main` репозитория https://github.com/6uxoi-Angel/NDICamera.
2. https://codemagic.io/apps → NDICamera → **Start new build** (ветка main).
3. Подождать ~5–7 мин → письмо на artemrasputin3@gmail.com с
   `NDICamera-unsigned.ipa`.
4. Установка: AltStore (AltServer на Windows) → добавить IPA → iPhone.
   (или Xcode: выбрать Team, Run на устройстве)

## ТЗ → реализация

| Требование | Где |
|---|---|
| Full NDI (NV12), 720p/1080p/4K, 30/60 fps | `VideoEncoder.swift` + `NDINative.mm` |
| Фронт/тыл/ультраширик | переключение на лету (`CameraManager`) |
| Tap-to-focus, блокировка экспозиции, фонарик, зум | жесты на превью |
| Авто-discovery mDNS + Discovery Server + ручной IP | `NDINative.mm`, режимы в настройках |
| Выбор интерфейса (Wi-Fi/USB) | `NetworkInterfaces.swift` + настройки → «Интерфейс» |
| Аудио 48 кГц (FLTP) | `AudioCapturer.swift` |
| Tally (красная/зелёная рамка) | обратный канал `NDINative.mm` + `TallyBorder` |
| Экран не гаснет, корректная остановка | `keepAwake`, AppModel |
| Авто-reconnect | `TransportManager.swift` |
| Лог + crash-отчёты | `Logger.swift` + экран «Лог» + `Documents/crash.log` |
| Имя источника редактируемое | настройки → Источник NDI |

## Известные места для отладки

- **OBS не видит источник** → проверить: iOS диалог «Локальная сеть» разрешён;
  телефон и ПК в одной сети/VLAN (без клиентской изоляции); firewall UDP 5960–5963,
  5353; транспорт mDNS → ручной IP.
- **Крэш при START** → прислать `crash.log` + `log.txt` (Файлы на iPhone) и
  последний `.ips` (Настройки → Конфиденциальность и безопасность → Аналитика
  и улучшения → Данные аналитики → NDICamera-...).
- **Звук рассинхронизирован** → не меняй fps/битрейт во время трансляции,
  останови и запусти заново.
- **NDI SDK требует лицензию** → если в SDK есть `NDIlib_set_license`, вызови его
  перед `NDIlib_initialize()` (раскомментируй в `NDINative.mm`).
