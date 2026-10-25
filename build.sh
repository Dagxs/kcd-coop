#!/bin/sh
# Cross-compiles loader/dinput8.dll for 64-bit Windows using zig (pip install ziglang).
set -e
cd "$(dirname "$0")"
python3 -I tools/embed_lua.py
cd loader
python3 -m ziglang cc -target x86_64-windows-gnu -shared -O2 -s -o dinput8.dll dinput8.c dinput8.def -lws2_32
sha256sum dinput8.dll
