#!/usr/bin/env bash
# Проверка наличия NDI SDK в нужных местах + инструкция.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$ROOT/NDISDK/iOS/libndi_ios.a"
INC="$ROOT/NDISDK/include/Processing.NDI.Lib.h"

echo "== Проверка NDI SDK =="
if [[ -f "$LIB" && -f "$INC" ]]; then
  echo "OK: SDK найден в NDISDK/"
  echo "  $(basename "$LIB") ($(du -h "$LIB" | cut -f1))"
  echo "  Processing.NDI.Lib.h"
else
  echo "НЕТ SDK. Сделай вручную (бесплатно):"
  echo "  1) https://ndi.video → регистрация (бесплатно) → скачать NDI SDK → iOS"
  echo "  2) Положить:"
  echo "     $LIB"
  echo "     $INC  (+ остальные заголовки из SDK/include)"
  echo "  3) Повторить этот скрипт."
  exit 1
fi
