#!/usr/bin/env python3
import os
import struct
from pathlib import Path

counter = Path(os.environ["VFS491_TEST_SEQUENCE_FILE"])
try:
    count = int(counter.read_text())
except FileNotFoundError:
    count = 0
counter.write_text(str(count + 1))

if count == 0:
    raise SystemExit(11)

width, height = 200, 2
pixels = bytes([120]) * (width * height)
header = struct.pack("<IIIII", 0x31534656, 1, width, height, len(pixels))
os.write(1, header + pixels)
