"""List MSVC x64 RTTI classes matching a pattern and their vtables (RVA), with selected slot targets.

Usage: python3 -I rtti.py <pe> <regex> [slot_offset_hex ...]
"""
import re
import struct
import sys

import pefile

pe = pefile.PE(sys.argv[1], fast_load=True)
pat = re.compile(sys.argv[2])
slots = [int(x, 16) for x in sys.argv[3:]]
data = pe.__data__
base = pe.OPTIONAL_HEADER.ImageBase
secs = [(s.VirtualAddress, s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData), s) for s in pe.sections]


def rva_to_off(r):
    for a, b, s in secs:
        if a <= r < b:
            return s.PointerToRawData + (r - a)
    return None


def off_to_rva(o):
    for a, b, s in secs:
        if s.PointerToRawData <= o < s.PointerToRawData + s.SizeOfRawData:
            return a + (o - s.PointerToRawData)
    return None


# TypeDescriptor: { vftable ptr (8), spare (8), name ".?AV...@@" }
tds = {}
for m in re.finditer(rb"\.\?A[VU][^\x00]{1,200}?@@\x00", data):
    name = m.group(0)[:-1].decode("latin1")
    if pat.search(name):
        td_off = m.start() - 16
        tds[off_to_rva(td_off)] = name
# CompleteObjectLocator x64: signature(1) offset cdOffset pTypeDescriptor(rva) pClassDescriptor(rva) pSelf(rva)
cols = {}
for td_rva, name in tds.items():
    needle = struct.pack("<I", td_rva)
    for m in re.finditer(re.escape(needle), data):
        col_off = m.start() - 12
        if col_off < 0:
            continue
        sig, off, cd, td, chd, selfr = struct.unpack_from("<IIIIII", data, col_off)
        if sig == 1 and td == td_rva and selfr == off_to_rva(col_off):
            cols[selfr] = f"{name} (subobject +{off:#x})"
# vtable: the qword right before it is the absolute address of the COL
for col_rva, name in cols.items():
    needle = struct.pack("<Q", base + col_rva)
    for m in re.finditer(re.escape(needle), data):
        vt_rva = off_to_rva(m.start() + 8)
        line = f"{name}  vtable rva {vt_rva:#x}"
        for so in slots:
            o = rva_to_off(vt_rva + so)
            if o is not None:
                t = struct.unpack_from("<Q", data, o)[0] - base
                line += f"  [+{so:#x}]={t:#x}"
        print(line)
