NDI SDK 6.3.2 (iOS) УЖЕ в этом репозитории — в сжатом виде:
  NDISDK\iOS-parts\part00.gz ... part06.gz
Заголовки: NDISDK\include\ (17 файлов, в репозитории).

Workflow собирает libndi_ios.a из частей автоматически (Scripts\split_join_sdk.py).

Если понадобится заменить SDK на другую версию:
  1) положи новый libndi_ios.a в NDISDK\iOS\
  2) запусти:  python Scripts\split_join_sdk.py --split
  3) закоммить и запуши.
