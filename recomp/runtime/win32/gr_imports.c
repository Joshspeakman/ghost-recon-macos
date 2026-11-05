/* Win32 functions Ghost Recon calls that the earlier ports never did (generic; built for every edition). */
#include "w32.h"

IMPL(dsound, ord2) { void imp_dsound_DirectSoundEnumerateA(Ctx *); imp_dsound_DirectSoundEnumerateA(c); }   /* #2 */
IMPL(dbghelp, SymUnDName) { if (ARG(1) && ARG(2)) rt_w8(G_MEM, ARG(1), 0); RET(0, 3); }       /* (symbol, out, size): none */
/* GDI drawing on a window DC (the game's debug overlays): nothing to draw on */
IMPL(gdi32, GdiFlush) { RET(1, 0); }
IMPL(gdi32, Polygon) { RET(1, 3); }
IMPL(gdi32, Polyline) { RET(1, 3); }
IMPL(gdi32, TextOutA) { RET(1, 5); }
IMPL(user32, CloseWindow) { RET(1, 1); }                          /* minimise: the game window stays */
IMPL(user32, GetQueueStatus) { RET(0, 1); }                       /* nothing new in the queue (PeekMessage tells) */
IMPL(user32, LoadImageA) { RET(ARG(2) == 1 ? 0x31000 + (ARG(1) & 0xffff) : 0, 6); }   /* IMAGE_ICON: as LoadIconA */
IMPL(user32, PostThreadMessageA) { void w32_post(uint32_t, uint32_t, uint32_t, uint32_t, uint32_t);
                                   w32_post(ARG(0), 0, ARG(1), ARG(2), ARG(3)); RET(1, 4); }
