#!/usr/bin/env python3
"""steamstub20.py <in.exe> <out.exe>

Undo the oldest Steam wrapper (SteamStub variant 2.0, x86: Ghost Recon's 2008 Steam build) on the player's own Steam
copy at build time, so the recompiler can read the code. The stub's start function copies its header out of `.bind`
(`mov esi, <header>` / `mov ecx, <dwords>` / `rep movsd`) and undoes the header's XOR chain (the first dword is the
seed). Header fields used: +0x18 flags (4 = code section encrypted), +0x2c original entry point, +0x30/+0x34 the code
section (VA, size), +0x38 its key, +0x3c the Steam app id. The code section is the same XOR chain: each plain dword is
the encrypted one XOR the previous encrypted one, seeded with the key. The output is the same PE with the plain code
section and the original entry point. Nothing written here leaves the build folder (recomp/work is never committed).
"""
import struct, sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
from pe import PE
from steamstub21 import steam_xor, u32

def unwrap(src, dst):
    pe = PE(src); d = pe.data; eo = pe.off(pe.entry)
    hva = hn = None
    for ins in Cs(CS_ARCH_X86, CS_MODE_32).disasm(d[eo:eo + 64], pe.entry):
        if ins.mnemonic == 'mov' and ins.op_str.startswith('esi, 0x'): hva = int(ins.op_str[5:], 16)
        elif ins.mnemonic == 'mov' and ins.op_str.startswith('ecx, 0x'): hn = int(ins.op_str[5:], 16)
        elif ins.mnemonic == 'rep movsd': break
    if not hva or not hn or pe.off(hva) is None: raise SystemExit(f'{src}: no SteamStub 2.0 header copy at the entry point')
    o = pe.off(hva); h, _ = steam_xor(d[o:o + 4 * hn], 0)
    flags, oep, code_va, code_size, key, appid = (u32(h, k) for k in (0x18, 0x2c, 0x30, 0x34, 0x38, 0x3c))
    if not (pe.base <= oep < code_va + code_size and code_va >= pe.base): raise SystemExit(f'{src}: unexpected SteamStub 2.0 header')
    out = bytearray(d)
    if flags & 4:
        ra = pe.off(code_va); plain, _ = steam_xor(d[ra:ra + code_size], key); out[ra:ra + code_size] = plain
    peo = u32(out, 0x3c)
    struct.pack_into('<I', out, peo + 24 + 16, oep - pe.base)    # AddressOfEntryPoint
    struct.pack_into('<I', out, peo + 24 + 64, 0)                # CheckSum
    open(dst, 'wb').write(out)
    return dict(appid=appid, oep=oep, code_va=code_va, code_size=code_size if flags & 4 else 0, flags=flags)

if __name__ == '__main__':
    h = unwrap(sys.argv[1], sys.argv[2])
    print(f'steamstub 2.0: app {h["appid"]}, entry point 0x{h["oep"]:x}, flags 0x{h["flags"]:x}, '
          f'code 0x{h["code_va"]:x} +0x{h["code_size"]:x}')
