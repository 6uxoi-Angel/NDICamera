# NDICamera — ТЗ и состояние проекта (для следующей сессии)

## Цель (ТЗ)
iOS-приложение «iPhone как камера для OBS»: передача видео + звук с iPhone
на Windows 11 в OBS (плагин DistroAV/NDI 6) по Wi-Fi или USB. Без облака,
без платных сервисов, без macOS у пользователя. Локально, с автопереподключением,
tally (красная/зелёная рамка), редактируемым именем источника.

## Жёсткие ограничения пользователя
- Нет local/аренды. Никаких платных сервисов.
- Только бесплатные пути: GitHub Actions (no macOS runners на этом аккаунте — проверено!)
  и Codemagic free (500 мин/мес, macOS) для сборки; AltStore для подписи/установки.
- Бесплатный Apple ID (без Team ID/программы разработчика).

## Решения
- Нативный SwiftUI + NDI SDK 6.3.2 (Apple pkg распакован, libndi_ios.a хранится
  gzip-частями в NDISDK/iOS-parts; собирается скриптом Scripts/split_join_sdk.py).
- **Full NDI (NV12)** — SDK iOS НЕ умеет отправку HX/H.264 (проверено по заголовкам).
  Полоса: 1080p60 ≈ 1.5-2 Гбит/с. USB — ок; Wi-Fi использовать 720p30.
- Сборка: XcodeGen (project.yml) → Codemagic (codemagic.yaml) → NDICamera-unsigned.ipa.
- Установка: AltStore (Windows) — подписывает бесплатным Apple ID, продлевает каждые 7 дней.
- Ключевые файлы: src/NDI/NDINative.mm (мост ObjC++ к SDK),
  src/NDI/NDIBridge.swift, src/Camera/VideoEncoder.swift (NV12), AudioCapturer.swift,
  CameraManager.swift, src/Common/AppModel.swift, UI/ContentView.swift, SettingsView.swift.

## Состояние (2026-11-18)
- Сборка на Codemagic ЗЕЛЁНАЯ: IPA собирается (1.2 МБ), Swift и .mm компилируются.
- Исправлены: TCC-крэш (usage descriptions в plist), installTap-исключение
  (родной формат + AVAudioSession active), экранирование NDI-отправок барьерами.
- ПРОБЛЕМА: на iPhone SE (2-е пок., iOS 26.6.1) при нажатии START — SIGSEGV
  в потоке ввода-вывода (AURemoteIO или camera queue). Точное место неизвестно
  (Release без dSYM). В следующей сессии: собрать с включённым логом этапов
  («[stage] ...» уже добавлены в AppModel.startStreaming); лог пишется в
  Documents/log.txt и доступен через Files-приложение (включены
  UIFileSharingEnabled/LSSupportsOpeningDocumentsInPlace).
- Гипотезы порядка проверки:
  1) аудио-tap (AVAudioEngine) на ис. — попробовать выключить «Передавать звук»
     (settings.audioEnabled=false) и повторить Start;
  2) гонка NDI: sender уничтожается при stop/start; барьеры добавлены, проверить;
  3) NV12-копия в VideoEncoder (плоскости) — проверить при пустом кадре/плоскостях;
  4) CameraManager: reconfigure при смене камеры (session.beginConfiguration/commit баланс).
- Ультраширик на SE отсутствует — уже отфильтрован (availableCameras).

## Полезные ссылки/данные
- Репозиторий: https://github.com/6uxoi-Angel/NDICamera (публичный).
- Codemagic: аккаунт 6uxoi Angel (neuzu02@gmail.com), приложение NDICamera,
  workflow «NDI Camera IPA (unsigned)».
- AltStore: altstore.io, AltServer на Windows, iOS-клиент.
- iPhone: iPhone SE 2 (iPhone12,8), iOS 26.6.1. Пользователь: Артём
  (artemrasputin3@gmail.com). GitHub: 6uxoi-Angel.
- OBS: плагин DistroAV установлен. Firewall UDP 5960-5963, 5353.

## Как продолжить
1. Пересобрать на Codemagic (main), установить через AltStore.
2. При крэше: прочитать с iPhone Файлы → NDICamera → log.txt (или .ips),
   прислать; сопоставить последний [stage] с местом падения.
3. Починить причину SIGSEGV (см. гипотезы), затем проверить OBS/NDI-приём.
