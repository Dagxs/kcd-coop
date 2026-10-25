"""Make KingdomCome2.exe from YOUR OWN KingdomCome.exe so two copies can run on one PC (testing).

The launcher refuses to start twice because of a named mutex "WhKcdGameMutex". This writes a copy
with the name changed to "WhKcdGameMutx2". The original file is not modified.

Usage: python make_second_launcher.py "<game dir>\\Bin\\Win64\\KingdomCome.exe"
"""
import hashlib
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
data = bytearray(src.read_bytes())
old, new = b"WhKcdGameMutex\x00", b"WhKcdGameMutx2\x00"
if data.count(old) != 1:
    sys.exit("mutex name not found exactly once: different game build?")
i = data.find(old)
data[i:i + len(old)] = new
dst = src.with_name("KingdomCome2.exe")
dst.write_bytes(data)
print(f"wrote {dst} (sha256 {hashlib.sha256(data).hexdigest()})")
