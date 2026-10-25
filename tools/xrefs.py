"""Find code that references given strings in a PE64 image (LEA reg,[rip+disp32]).

Usage: python3 -I xrefs.py <pe> "<string>" ["<string>" ...]
Prints, for each string: its RVA, then each referencing instruction RVA and the
containing function range from .pdata.
"""
import bisect
import re
import struct
import sys

import pefile


def main():
    path, wanted = sys.argv[1], sys.argv[2:]
    pe = pefile.PE(path, fast_load=False)
    base = pe.OPTIONAL_HEADER.ImageBase
    data = pe.__data__
    secs = {s.Name.rstrip(b"\0").decode(): s for s in pe.sections}
    text = secs[".text"]
    tbytes = text.get_data()
    trva = text.VirtualAddress

    # function table from .pdata
    funcs = []
    for e in getattr(pe, "DIRECTORY_ENTRY_EXCEPTION", []):
        funcs.append((e.struct.BeginAddress, e.struct.EndAddress))
    funcs.sort()
    starts = [f[0] for f in funcs]

    def func_of(rva):
        i = bisect.bisect_right(starts, rva) - 1
        if i >= 0 and funcs[i][0] <= rva < funcs[i][1]:
            return funcs[i]
        return None

    # locate strings (exact, NUL-terminated) in all non-code sections
    targets = {}
    for w in wanted:
        needle = w.encode() + b"\0"
        for s in pe.sections:
            if s is text:
                continue
            blob = s.get_data()
            for m in re.finditer(re.escape(needle), blob):
                # require a preceding NUL so we match the string start
                if m.start() == 0 or blob[m.start() - 1] == 0:
                    targets.setdefault(s.VirtualAddress + m.start(), w)

    if not targets:
        print("no strings found")
        return
    trs = set(targets)

    hits = {}
    # LEA r64, [rip+disp32]: REX.W(48/4C) 8D modrm(mod=00, rm=101)
    for m in re.finditer(rb"[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]", tbytes):
        i = m.start()
        disp = struct.unpack_from("<i", tbytes, i + 3)[0]
        tgt = trva + i + 7 + disp
        if tgt in trs:
            hits.setdefault(tgt, []).append(trva + i)

    for rva, w in sorted(targets.items(), key=lambda kv: kv[1]):
        print(f"\n== {w!r} @ rva {rva:#x}")
        for ref in hits.get(rva, []):
            f = func_of(ref)
            fs = f"func {f[0]:#x}-{f[1]:#x}" if f else "func ?"
            print(f"   ref {ref:#x}  {fs}")


if __name__ == "__main__":
    main()
