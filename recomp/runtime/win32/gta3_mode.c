/* GTA III: the launch window's Resolution. psSelectDevice (0x582970) takes the video mode saved in gta3.set (the menu's
 * m_nPrefsVideoMode, 0x906c10) when it is a usable one, else looks for 640x480. GTA_MODE=WxH (host/gta3_launcher.m)
 * puts RenderWare's index of that 32-bit full-screen mode there first (tools/lift.py GTA3_HOOKS), so the game opens
 * at it and its Display Setup shows it; without the variable the saved choice stands ("As Set in Game"). */
#include "w32.h"

#ifdef GTA3_EDITION
enum { PICK_MODE = 0x005829f8u,             /* psSelectDevice: just before the saved mode is read */
       RW_NUM_MODES = 0x005a2460u,          /* RwEngineGetNumVideoModes(void) */
       RW_MODE_INFO = 0x005a24d0u,          /* RwEngineGetVideoModeInfo(RwVideoMode *, index): width, height, depth, flags */
       PREFS_MODE = 0x00906c10u };

/* a cdecl guest call from a hook: arguments, a return address the callee's ret pops, the registers kept */
static uint32_t guest_call(Ctx *c, uint32_t fn, int n, const uint32_t *args)
{
    uint32_t r[8] = {c->eax, c->ecx, c->edx, c->ebx, c->esp, c->ebp, c->esi, c->edi};
    for (int k = n - 1; k >= 0; k--) { c->esp -= 4; rt_w32(G_MEM, c->esp, args[k]); }
    c->esp -= 4; rt_w32(G_MEM, c->esp, 0);
    rt_call(c, fn);
    uint32_t v = c->eax;
    c->eax = r[0]; c->ecx = r[1]; c->edx = r[2]; c->ebx = r[3]; c->esp = r[4]; c->ebp = r[5]; c->esi = r[6]; c->edi = r[7];
    return v;
}

static void pick_mode(Ctx *c)
{
    static int done; const char *e = getenv("GTA_MODE"); unsigned w, h;
    if (done || !e || sscanf(e, "%ux%u", &w, &h) != 2) return;
    done = 1;
    uint32_t buf = (c->esp - 0x400) & ~15u, n = guest_call(c, RW_NUM_MODES, 0, 0);   /* scratch well below the frame */
    for (uint32_t i = 1; i < n && i < 512; i++) {
        uint32_t a[2] = {buf, i}; guest_call(c, RW_MODE_INFO, 2, a);
        if (rt_r32(G_MEM, buf) == w && rt_r32(G_MEM, buf + 4) == h && rt_r32(G_MEM, buf + 8) == 32 && (rt_r32(G_MEM, buf + 12) & 1)) {
            fprintf(stderr, "gta3: video mode %ux%u (RenderWare mode %u, was %u)\n", w, h, i, rt_r32(G_MEM, PREFS_MODE));
            rt_w32(G_MEM, PREFS_MODE, i); return;
        }
    }
    fprintf(stderr, "gta3: no %ux%u video mode: the game's own choice\n", w, h);
}

int gta3_hook(Ctx *c, uint32_t addr)
{
    if (addr == PICK_MODE) { pick_mode(c); return 1; }
    return 0;
}
#endif
