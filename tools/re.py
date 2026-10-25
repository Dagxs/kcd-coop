"""Small PE64 helpers for targeted reverse engineering.

  python3 -I re.py <pe> callers <rva> [<rva> ...]   direct E8/E9 calls/jumps to each RVA
  python3 -I re.py <pe> dis <rva> [count]           disassemble the function containing RVA
  python3 -I re.py <pe> func <rva>                  print .pdata function range for RVA
"""
import bisect
import re
import struct
import sys

import capstone
import pefile

pe = pefile.PE(sys.argv[1], fast_load=False)
text = next(s for s in pe.sections if s.Name.startswith(b".text"))
tb = text.get_data()
trva = text.VirtualAddress
funcs = sorted((e.struct.BeginAddress, e.struct.EndAddress) for e in pe.DIRECTORY_ENTRY_EXCEPTION)
starts = [f[0] for f in funcs]


def func_of(rva):
    i = bisect.bisect_right(starts, rva) - 1
    return funcs[i] if i >= 0 and funcs[i][0] <= rva < funcs[i][1] else None


def string_at(rva):
    try:
        off = pe.get_offset_from_rva(rva)
    except Exception:
        return None
    end = pe.__data__.find(b"\0", off, off + 200)
    if end <= off:
        return None
    s = pe.__data__[off:end]
    if all(32 <= c < 127 for c in s) and len(s) >= 4:
        return s.decode()
    return None


cmd = sys.argv[2]
if cmd == "callers":
    tg = {int(a, 16) for a in sys.argv[3:]}
    for m in re.finditer(rb"[\xe8\xe9]", tb):
        i = m.start()
        if i + 5 > len(tb):
            break
        t = trva + i + 5 + struct.unpack_from("<i", tb, i + 1)[0]
        if t in tg:
            f = func_of(trva + i)
            kind = "call" if tb[i] == 0xE8 else "jmp"
            print(f"{t:#x} <- {kind} at {trva+i:#x}  in func {f[0]:#x}-{f[1]:#x}" if f else f"{t:#x} <- {kind} at {trva+i:#x}")
elif cmd == "func":
    r = int(sys.argv[3], 16)
    f = func_of(r)
    print(f"{f[0]:#x}-{f[1]:#x}" if f else "none")
elif cmd == "dis":
    r = int(sys.argv[3], 16)
    count = int(sys.argv[4]) if len(sys.argv) > 4 else 400
    f = func_of(r) or (r, r + 0x400)
    md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
    code = tb[f[0] - trva:f[1] - trva]
    for n, ins in enumerate(md.disasm(code, f[0])):
        if n >= count:
            break
        note = ""
        if "rip" in ins.op_str:
            mm = re.search(r"rip ([+-]) (0x[0-9a-f]+)", ins.op_str)
            if mm:
                d = int(mm.group(2), 16) * (1 if mm.group(1) == "+" else -1)
                tgt = ins.address + ins.size + d
                s = string_at(tgt)
                note = f"   ; {tgt:#x}" + (f' "{s}"' if s else "")
        print(f"{ins.address:#x}: {ins.mnemonic:7} {ins.op_str}{note}")
