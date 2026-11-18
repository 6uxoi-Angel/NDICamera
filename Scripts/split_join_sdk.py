#!/usr/bin/env python3
"""NDI SDK split/join utility.

GitHub не принимает файлы > 100 МБ, поэтому libndi_ios.a (256 МБ)
хранится в git gzip-частями в NDISDK/iOS-parts/ (< 100 МБ каждая).

  python3 split_join_sdk.py --split   # разделить libndi_ios.a на gzip-части
  python3 split_join_sdk.py --join    # собрать libndi_ios.a из частей (в CI)
"""
import sys, pathlib, gzip

ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / "NDISDK" / "iOS" / "libndi_ios.a"
PARTS = ROOT / "NDISDK" / "iOS-parts"
PART_SIZE = 40 * 1024 * 1024  # ~40 МБ сырых данных до сжатия

def split():
    if not LIB.exists():
        sys.exit(f"нет файла {LIB}")
    PARTS.mkdir(exist_ok=True)
    for old in PARTS.glob("part*.gz"):
        old.unlink()
    data = LIB.read_bytes()
    n = 0
    for off in range(0, len(data), PART_SIZE):
        chunk = data[off:off + PART_SIZE]
        with gzip.open(PARTS / f"part{n:02d}.gz", "wb", compresslevel=6) as f:
            f.write(chunk)
        n += 1
    print(f"OK: {n} gzip-частей -> {PARTS}")

def join():
    if not PARTS.exists():
        sys.exit(f"нет папки частей {PARTS}")
    parts = sorted(PARTS.glob("part*.gz"))
    if not parts:
        sys.exit("части не найдены")
    out = b"".join(gzip.open(p, "rb").read() for p in parts)
    LIB.parent.mkdir(exist_ok=True)
    LIB.write_bytes(out)
    print(f"OK: {LIB} собран ({len(out)} байт, частей: {len(parts)})")

if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("использование: split_join_sdk.py --split | --join")
    (split if sys.argv[1] == "--split" else join)()
