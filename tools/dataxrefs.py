"""Find RIP-relative references to data RVAs anywhere in .text, then decode each with capstone.

Usage: python3 -I dataxrefs.py <pe> <rva> [<rva> ...]
"""
import bisect
import sys

import capstone
import numpy as np
import pefile

pe = pefile.PE(sys.argv[1], fast_load=False)
text = next(s for s in pe.sections if s.Name.startswith(b".text"))
tb = text.get_data()
trva = text.VirtualAddress
funcs = sorted((e.struct.BeginAddress, e.struct.EndAddress) for e in pe.DIRECTORY_ENTRY_EXCEPTION)
starts = [f[0] for f in funcs]
targets = [int(a, 16) for a in sys.argv[2:]]

arr = np.frombuffer(tb[: len(tb) - (len(tb) % 1)], dtype=np.uint8)
n = len(arr) - 4
# little-endian int32 at every offset
disp = (arr[0:n].astype(np.int64) | (arr[1:n+1].astype(np.int64) << 8) |
        (arr[2:n+2].astype(np.int64) << 16) | (arr[3:n+3].astype(np.int64) << 24))
disp = np.where(disp >= 2**31, disp - 2**32, disp)
pos = np.arange(n, dtype=np.int64) + trva
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)

seen = set()
for t in targets:
    for tail in (0, 1, 2, 4):  # bytes of immediate after the disp32
        idx = np.nonzero(pos + 4 + tail + disp == t)[0]
        for j in idx:
            # try instruction starts 2..4 bytes before the disp
            for back in (2, 3, 4):
                s = int(j) - back
                if s < 0:
                    continue
                ins = next(md.disasm(tb[s:s + 15], trva + s), None)
                if ins and ins.size == back + 4 + tail and "rip" in ins.op_str:
                    key = ins.address
                    if key in seen:
                        continue
                    seen.add(key)
                    i = bisect.bisect_right(starts, ins.address) - 1
                    f = funcs[i] if i >= 0 and funcs[i][0] <= ins.address < funcs[i][1] else None
                    fs = f"{f[0]:#x}" if f else "?"
                    print(f"{t:#x}  {ins.address:#x}: {ins.mnemonic} {ins.op_str}   (func {fs})")
