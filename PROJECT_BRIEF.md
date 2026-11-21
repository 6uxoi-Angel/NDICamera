# NDICamera — ТЗ и состояние проекта (для следующей сессии)

## Цель (ТЗ)
iOS-приложение «iPhone как камера для OBS»: передача видео + звук с iPhone
на Windows 11 в OBS (плагин DistroAV/NDI 6) по Wi-Fi. Без облака,
без платных сервисов, без macOS у пользователя. Локально, с автопереподключением,
tally (красная/зелёная рамка), редактируемым именем источника.

## Жёсткие ограничения пользователя
- Нет Mac/аренды. Никаких платных сервисов.
- Только бесплатные пути: Codemagic free (500 мин/мес, macOS) для сборки;
  AltStore для подписи/установки (7 дней, продление).
- Бесплатный Apple ID (без Team ID/программы разработчика).

## Решения
- Нативный SwiftUI + NDI SDK 6.3.2 (libndi_ios.a хранится gzip-частями
  в NDISDK/iOS-parts; собирается `Scripts/split_join_sdk.py`).
- **Full NDI (NV12)** — SDK iOS НЕ умеет отправку HX/H.264 (проверено по
  заголовкам). Полоса: 1080p60 ≈ 1.5–2 Гбит/с; Wi-Fi использовать 720p30.
- Сборка: XcodeGen (project.yml) → Codemagic (codemagic.yaml) → NDICamera-unsigned.ipa.
- Установка: AltStore (Windows) — подписывает бесплатным Apple ID.
- Ключевые файлы: src/NDI/NDINative.mm (мост ObjC++ к SDK),
  src/NDI/NDIBridge.swift, src/Camera/VideoEncoder.swift (NV12), AudioCapturer.swift,
  CameraManager.swift, src/Common/AppModel.swift, UI/ContentView.swift, SettingsView.swift.

## Состояние (2026-11-21, вечер)
- **Сборка на Codemagic: последняя успешная — Index 22, коммит `7eca8c3`,
  IPA `NDICamera-unsigned(5).ipa` (UUID бинарника `156fe777...`).**
- Диагностика через `pymobiledevice3` (работает на Windows): `crash ls/pull`
  достают системные `.ips`; `doctor` показал, что iPhone12,8 (iOS 26.6.1)
  спарен, Developer Mode включён. Контейнер приложения НЕ открывается
  (`apps pull` → InstallationLookupFailed) — приложения AltStore не дают
  house_arrest; логи `Documents/log.txt` и `Documents/crash.log` берутся
  вручную через «Файлы» на iPhone.
- **Крэш воспроизведён на НОВОМ билде** (UUID `156fe777` в крашах
  15:11 и 15:12 — совпадает с текущим IPA): SIGSEGV / KERN_INVALID_ADDRESS
  на потоке **`ndis:async`** (внутренний воркер NDI SDK).
- **Корневая причина (устранена в коммите после `7eca8c3`)**:
  структуры `NDIlib_video_frame_v2_t`/`NDIlib_audio_frame_v3_t` создавались
  на стеке dispatch-блока. SDK вправе держать указатель на структуру до
  следующего send/destroy; после выхода из блока стековая память отдаётся
  системе и перезаписывается → SDK читал мусор.
  Фикс: структуры перенесены в ivar'ы (`_videoFrame`/`_audioFrame`) +
  пул сильных ссылок на буферы (`_heldBuffers`, до 16).
- Дополнительно исправлено: `NDIlib_destroy()` убран (init один раз);
  сериализация всех операций SDK; timecode/fps из настроек; tally через
  `metadata_only` + парсинг XML; построчное копирование NV12 (stride);
  FLTP без interleave; выбор ближайшего формата камеры; reconnect по
  сигнатуре сети; **`NSLocalNetworkUsageDescription` + `NSBonjourServices`
  добавлены в Info.plist** (iOS 14+ блокировал mDNS-discovery → OBS не
  видел источник).

## Как продолжить
1. Пересобрать на Codemagic (main) — коммит после `7eca8c3` (пул буферов +
   plist). Установить через AltStore.
2. Проверить на устройстве:
   - задняя камера START/STOP/START и front↔back (раньше SIGSEGV);
   - OBS/DistroAV: после установки iOS спросит «Локальная сеть» — разрешить;
     источник должен появиться;
   - tally: красная/зелёная рамка.
3. Если краш повторится — забрать логи: «Файлы» → На моём iPhone → NDICamera →
   `log.txt`/`crash.log`; плюс Настройки → Конфиденциальность → Аналитика →
   Данные аналитики → `NDICamera-...ips`. Прислать оба.
4. Желательно: собирать с dSYM (или Debug) для символизации `.ips` —
   сейчас адреса в крашах без имён функций.

## Полезные ссылки/данные
- Репозиторий: https://github.com/6uxoi-Angel/NDICamera (публичный).
- Codemagic: аккаунт 6uxoi Angel (neuzu02@gmail.com), приложение NDICamera,
  workflow «NDI Camera IPA (unsigned)».
- AltStore: altstore.io, AltServer на Windows, iOS-клиент.
- iPhone: iPhone SE 2 (iPhone12,8), iOS 26.6.1. Пользователь: Артём
  (artemrasputin3@gmail.com). GitHub: 6uxoi-Angel.
- OBS: плагин DistroAV установлен. Firewall UDP 5960–5963, 5353.
- Диагностика с ПК: `python -m pip install pymobiledevice3` →
  `python -m pymobiledevice3 crash ls`, `crash pull NDICamera`, `doctor`.
