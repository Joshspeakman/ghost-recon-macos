/* Win32 functions Grand Theft Auto: San Andreas and the DLLs recompiled with it (msvcr71, msvcp71, eax.dll) call that
 * the earlier ports never did (generic; built for every edition). */
#include "w32.h"

/* WS2_32 by ordinal: the same functions as WSOCK32's (winsock.c, net_ole.c), except 10-12, whose numbers differ */
#define FWD(n, w) void imp_wsock32_##w(Ctx *c); IMPL(ws2_32, n) { imp_wsock32_##w(c); }
FWD(ord3, ord3)        /* closesocket */
FWD(ord4, ord4)        /* connect */
FWD(ord9, ord9)        /* htons */
FWD(ord11, ord10)      /* inet_addr (WSOCK32 #10) */
FWD(ord16, ord16)      /* recv */
FWD(ord19, ord19)      /* send */
FWD(ord23, ord23)      /* socket */
FWD(ord111, ord111)    /* WSAGetLastError */
FWD(ord115, ord115)    /* WSAStartup */
FWD(ord116, ord116)    /* WSACleanup */

/* GetModuleHandleExA(flags, name or address, HMODULE *): the module by name, or (FROM_ADDRESS, 4) the image holding
 * the address; no reference counting here */
void imp_kernel32_GetModuleHandleA(Ctx *c);
IMPL(kernel32, GetModuleHandleExA)
{
    uint32_t flags = ARG(0), what = ARG(1), out = ARG(2), m = 0;
    if (flags & 4) {
        extern const struct rt_image { const char *name; uint32_t base, imp_first, imp_count; } rt_images[]; extern const unsigned rt_images_n;
        for (unsigned k = 0; k < rt_images_n; k++) {
            uint32_t b = rt_images[k].base, size = rt_r32(G_MEM, b + rt_r32(G_MEM, b + 0x3c) + 0x50);
            if (what >= b && what - b < size) { m = b; break; }
        }
    } else {
        uint32_t esp0 = c->esp; c->esp -= 8; rt_w32(G_MEM, c->esp, 0); rt_w32(G_MEM, c->esp + 4, what);   /* GetModuleHandleA(name) */
        imp_kernel32_GetModuleHandleA(c); m = c->eax; c->esp = esp0;
    }
    if (out) rt_w32(G_MEM, out, m);
    if (!m) w32_set_last_error(c, 126);
    RET(m != 0, 3);
}
/* FindResourceW(module, name, type): as FindResourceA (resources.c), the names given as numbers or wide strings */
void imp_kernel32_FindResourceA(Ctx *c);
IMPL(kernel32, FindResourceW)
{
    uint32_t a[3] = {ARG(0), ARG(1), ARG(2)}, esp0 = c->esp;
    for (int k = 1; k <= 2; k++) if (a[k] >= 0x10000) {                     /* a string: narrowed into guest scratch */
        uint32_t s = (c->esp - 0x200 * (uint32_t)k) & ~3u, n = 0;
        for (uint16_t ch; (ch = rt_r16(G_MEM, a[k] + 2 * n)) && n < 0x1ff; n++) G_MEM[s + n] = ch < 0x80 ? (uint8_t)ch : '?';
        G_MEM[s + n] = 0; a[k] = s;
    }
    c->esp = (c->esp - 0x500) & ~3u; uint32_t sp = c->esp;
    rt_w32(G_MEM, sp, 0); rt_w32(G_MEM, sp + 4, a[0]); rt_w32(G_MEM, sp + 8, a[1]); rt_w32(G_MEM, sp + 12, a[2]);
    imp_kernel32_FindResourceA(c); uint32_t r = c->eax; c->esp = esp0;
    RET(r, 3);
}
/* RegCreateKeyA(key, subkey, HKEY *) and RegSetValueA(key, subkey, type, data, size): the Ex forms (registry.c) */
void imp_advapi32_RegCreateKeyExA(Ctx *c); void imp_advapi32_RegSetValueExA(Ctx *c); void imp_advapi32_RegCloseKey(Ctx *c);
static uint32_t call_api(Ctx *c, void (*fn)(Ctx *), int n, const uint32_t *args)
{
    uint32_t esp0 = c->esp; c->esp = (c->esp - 0x100) & ~3u;
    c->esp -= 4 * (uint32_t)n; for (int k = 0; k < n; k++) rt_w32(G_MEM, c->esp + 4 * (uint32_t)k, args[k]);
    c->esp -= 4; rt_w32(G_MEM, c->esp, 0);
    fn(c); uint32_t r = c->eax; c->esp = esp0; return r;
}
IMPL(advapi32, RegCreateKeyA)
{
    uint32_t a[9] = {ARG(0), ARG(1), 0, 0, 0, 0xf003f, 0, ARG(2), 0};
    RET(call_api(c, imp_advapi32_RegCreateKeyExA, 9, a), 3);
}
IMPL(advapi32, RegSetValueA)          /* the subkey's default value (a string) */
{
    uint32_t key = ARG(0), sub = ARG(1), data = ARG(3), size = ARG(4), k = key, r;
    uint32_t tmp = (c->esp - 0x300) & ~3u;
    if (sub && G_MEM[sub]) { uint32_t a[9] = {key, sub, 0, 0, 0, 0xf003f, 0, tmp, 0}; if ((r = call_api(c, imp_advapi32_RegCreateKeyExA, 9, a))) RET(r, 5); k = rt_r32(G_MEM, tmp); }
    uint32_t a[6] = {k, 0, 0, 1 /* REG_SZ */, data, size ? size : (uint32_t)strlen(GS(data)) + 1}; r = call_api(c, imp_advapi32_RegSetValueExA, 6, a);
    if (k != key) { uint32_t b[1] = {k}; call_api(c, imp_advapi32_RegCloseKey, 1, b); }
    RET(r, 5);
}
/* StringFromCLSID(clsid, LPOLESTR *): "{xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx}" in CoTaskMemAlloc memory */
IMPL(ole32, StringFromCLSID)
{
    const uint8_t *g = GP(ARG(0)); char s[40];
    snprintf(s, sizeof s, "{%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X}", rt_r32(G_MEM, ARG(0)), rt_r16(G_MEM, ARG(0) + 4), rt_r16(G_MEM, ARG(0) + 6),
             g[8], g[9], g[10], g[11], g[12], g[13], g[14], g[15]);
    extern uint32_t w32_process_heap; uint32_t heap_alloc(uint32_t heap, uint32_t flags, uint32_t size);
    uint32_t p = heap_alloc(w32_process_heap, 0, 80); if (!p) RET(0x8007000eu, 2);
    for (int k = 0; k <= 38; k++) rt_w16(G_MEM, p + 2 * (uint32_t)k, (uint16_t)s[k]);
    rt_w32(G_MEM, ARG(1), p); RET(0, 2);
}
/* msvcr71's console, heap-walk and file-lock entry points: present for its import table; the game never calls them */
IMPL(kernel32, Beep) { RET(1, 2); }
IMPL(kernel32, GetLogicalDrives) { RET(1u << 2, 0); }                    /* C: */
IMPL(kernel32, HeapCompact) { RET(0x100000, 2); }
IMPL(kernel32, HeapValidate) { RET(1, 3); }
IMPL(kernel32, HeapWalk) { w32_set_last_error(c, 259); RET(0, 2); }      /* ERROR_NO_MORE_ITEMS */
IMPL(kernel32, LockFile) { RET(1, 5); }
IMPL(kernel32, UnlockFile) { RET(1, 5); }
IMPL(kernel32, CreatePipe) { w32_set_last_error(c, 50); RET(0, 4); }     /* not supported */
IMPL(kernel32, GetNumberOfConsoleInputEvents) { if (ARG(1)) rt_w32(G_MEM, ARG(1), 0); RET(1, 2); }
IMPL(kernel32, PeekConsoleInputA) { if (ARG(3)) rt_w32(G_MEM, ARG(3), 0); RET(1, 4); }
IMPL(kernel32, ReadConsoleA) { if (ARG(3)) rt_w32(G_MEM, ARG(3), 0); RET(1, 5); }
IMPL(kernel32, SetLocalTime) { RET(1, 1); }
