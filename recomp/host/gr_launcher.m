/* Ghost Recon launch window: one app for the natively recompiled Tom Clancy's Ghost Recon and its expansions Desert
 * Siege and Island Thunder. A screenshot of the chosen campaign under its title, a card per campaign, a row of tiles
 * (Graphics Options, Saves, Game Files, Updates) and Quit / Play. Every card runs the same program (GhostRecon.exe 1.4
 * plays all three); an expansion whose mod folder (Mods/Mp1, Mods/Mp2) isn't in the game folder is dimmed.
 *
 * This file is built two ways:
 *  - the app's own executable (install.sh: clang -DGR_LAUNCHER_APP, Contents/MacOS/GhostReconLauncher): Play opens a
 *    fresh instance of the app that execv()s Contents/MacOS/GhostRecon at once, so the app in the Dock is the game and
 *    macOS keeps Game Mode on. Resources/launch.plist (install.sh; main.m bundle_launch reads it too) names the game
 *    folder, the data folder, the executable and the commit and branch the app was built from.
 *  - inside the game (tools/build_app.sh links it into GhostRecon): main.m calls ds_launcher_run(game, data). With
 *    DS_NO_LAUNCHER set (the app's Play, or a terminal) the saved choices go into the environment unless already set and
 *    the game starts; otherwise the same window is shown and Play returns 1 (main.m then starts the game afresh).
 * The game is told the choices in its environment:
 *   GR_CAMPAIGN=gr|ds|it                   which campaign (the runtime makes it the game's active mods)
 *   DS_NO_LAUNCHER=1                       the window is not shown again
 *   DS_DISPLAY=window|fullscreen, DS_NOTCH=around|below   main.m (the game's window)
 *   GTA_MODE=WxH                           the video mode (runtime/win32/gta3_mode.c, d3d9.c); "" = as set in the game
 *   DSR_VSYNC=1|0                          main.m (the Metal layer)
 *   DS_LOG_FILE=<data>/GhostRecon.log      the game's log (stderr; over 5 MB it moves to GhostRecon.old.log)
 * The choices are kept in <data>/launcher.plist (~/Games/GhostReconNative/launcher.plist). Art: Resources/art/<gr|ds|it>/
 * or <data>/art/<id>/ (hero.jpg, shot1.jpg: tools/gr_art.py, fetched at install time); without it, plain colours.
 *
 * Development (the app's executable, or GhostRecon with DS_LAUNCHER_* in place of GR_LAUNCHER_*):
 *   GR_LAUNCHER_SHOT=<png>      render the window to an image and exit (no window, works on a locked screen)
 *   GR_LAUNCHER_CAMPAIGN=0|1|2  the chosen card (also without a shot); GR_LAUNCHER_OPEN=1 the Graphics Options panel
 *   GR_LAUNCHER_HOVER=<code>    an item lit (100 Play, 101 Quit, 200+i card i, 300+10k+1 tile k, 400+10k+n panel row k)
 *   GR_LAUNCHER_FOCUS=<k>       tile k keyboard-focused
 *   GR_LAUNCHER_GAME_DIR=<dir>  the game folder (e.g. one without Mods/Mp2, to see a dimmed card)
 *   GR_LAUNCHER_DATA_DIR=<dir>  the data folder (launcher.plist, art/)
 *   GR_LAUNCHER_PLAY=1          press Play at once; GR_LAUNCHER_DRY=1 prints what Play would run instead of running it */
#import <Cocoa/Cocoa.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#include <errno.h>
#include <math.h>
#include <fcntl.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* olive drab, khaki and field green: the colours of the game's own menus, kept quiet */
static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
static NSColor *accent(void) { return rgb(0.76, 0.77, 0.55); }        /* khaki */
static NSColor *accent_hi(void) { return rgb(0.87, 0.88, 0.68); }
static NSColor *accent_dim(void) { return rgb(0.36, 0.39, 0.25); }    /* olive drab */
static NSColor *text_c(void) { return rgb(0.92, 0.93, 0.88); }
static NSColor *dim(void) { return rgb(0.58, 0.61, 0.54); }
static NSColor *ink(void) { return rgb(0.043, 0.051, 0.040); }        /* green-black */
static NSColor *panel_c(void) { return rgb(0.075, 0.085, 0.068); }
static NSColor *ready_c(void) { return rgb(0.58, 0.82, 0.42); }        /* the green of a ready unit */
static NSColor *signal_c(void) { return rgb(0.42, 0.86, 0.48); }       /* the crosshair's green, from the logo */
static NSFont *heavy(CGFloat size) { return [NSFont fontWithName:@"DINCondensed-Bold" size:size] ?: [NSFont systemFontOfSize:size weight:NSFontWeightBold]; }
static NSFont *body(CGFloat size, BOOL bold)
{ return [NSFont fontWithName:bold ? @"AvenirNext-DemiBold" : @"AvenirNext-Medium" size:size] ?: [NSFont systemFontOfSize:size weight:bold ? NSFontWeightSemibold : NSFontWeightRegular]; }
static void on_main(dispatch_block_t b) { CFRunLoopPerformBlock(CFRunLoopGetMain(), kCFRunLoopCommonModes, b); CFRunLoopWakeUp(CFRunLoopGetMain()); }
static const char *dev_env(const char *name)   /* GR_LAUNCHER_<name>, or DS_LAUNCHER_<name> (main.m's name for the shot) */
{
    char k[64]; snprintf(k, sizeof k, "GR_LAUNCHER_%s", name); const char *v = getenv(k);
    if (!v) { snprintf(k, sizeof k, "DS_LAUNCHER_%s", name); v = getenv(k); }
    return v;
}

// ---------------------------------------------------------------- the campaigns
static BOOL gr_dropin;   /* the downloaded app (setup/): its hints name no install.sh */
typedef struct {
    const char *id, *title, *sub, *theatre, *mods, *depot;   /* sub: the expansion's name under GHOST RECON */
    CGFloat heroX, heroY; CGFloat r, g, b;                  /* where the hero's crop sits; a colour when there is no art */
    const char *year, *blurb, *op;                         /* the credit line; the campaign in a sentence; the caption */
} CampaignDef;
static const CampaignDef CAMPAIGNS[3] = {
    {"gr", "Ghost Recon", NULL, "RUSSIA · 2008", "Origmiss", "15300 15301", 0.75, 0.45, 0.22, 0.26, 0.17, "2001",
     "2008. Ultranationalists take Moscow and roll into Georgia and the Baltics. Six Green Berets go in first, unseen.", "THE GHOSTS · 1ST BATTALION, 5TH SFG"},
    {"ds", "Desert Siege", "DESERT SIEGE", "ETHIOPIA · 2009", "Mp1", "13620 13621", 0.72, 0.45, 0.40, 0.34, 0.21, "2002",
     "2009. Ethiopia's army pours across the border into Eritrea. The Ghosts deploy to the Horn of Africa to break it.", "OPERATION · HORN OF AFRICA"},
    {"it", "Island Thunder", "ISLAND THUNDER", "CUBA · 2010", "Mp2", "13630 13631", 0.80, 0.40, 0.12, 0.25, 0.18, "2002",
     "2010. Cuba's first free election draws a guerrilla army out of the hills. The Ghosts land to keep the vote alive.", "OPERATION · ISLAND THUNDER"},
};
enum { NCAMP = 3 };

@interface GRCampaign : NSObject
@property const CampaignDef *def; @property BOOL installed;
@property NSImage *hero, *card, *portrait; @property NSArray<NSImage *> *scenes;   /* scenes: the backdrop's slides */
@property CGFloat coverZ, coverFx, coverFy;                                        /* the portrait's crop */
@end
@implementation GRCampaign @end

// ---------------------------------------------------------------- settings tiles
@interface GRTile : NSObject
@property NSString *title; @property NSArray<NSDictionary *> *choices; @property NSInteger index;
@property (copy) void (^activate)(void);            /* a tile that runs something instead of cycling */
@property (copy) NSString *(^summary)(void);        /* a tile showing others' values (Graphics Options) */
@property (copy) NSDictionary *(^current)(void);    /* a tile whose label and note follow the chosen campaign */
@property BOOL wide;
@end
@implementation GRTile @end

// ---------------------------------------------------------------- the view
enum { HIT_NONE = -1, HIT_PLAY = 100, HIT_QUIT = 101, HIT_BACK = 102, HIT_CARD = 200, HIT_TILE = 300, HIT_ROW = 400 };   /* tiles, rows: + 10*k + 0 left / 1 value / 2 right */
enum { W = 960, H = 700 };

@interface GRLaunchView : NSView
@property NSArray<GRCampaign *> *campaigns; @property NSInteger campaign;
@property NSArray<GRTile *> *tiles; @property NSInteger hover, pressed, focus;   /* focus: -1 the cards, else a tile */
@property NSArray<GRTile *> *rows; @property BOOL open; @property NSInteger rowFocus;   /* the Graphics Options panel */
@property NSString *hint; @property NSImage *logo;
@property double t, switchT; @property NSInteger prevCampaign; @property NSMutableDictionary *cache;   /* the animation's clock; pictures drawn once */
@property (copy) void (^onPlay)(void); @property (copy) void (^onQuit)(void); @property (copy) void (^onChange)(void);
@end

@implementation GRLaunchView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return YES; }
- (GRCampaign *)chosen { return self.campaigns[self.campaign]; }
- (NSRect)cardRect:(NSInteger)i { CGFloat gap = 14, w = (532 - 2 * gap) / 3; return NSMakeRect(48 + i * (w + gap), 318, w, 160); }
- (NSRect)tileRect:(NSInteger)k   /* the tiles in a row (a wide one counts twice) */
{
    NSInteger units = 0, at = 0, n = (NSInteger)self.tiles.count;
    for (NSInteger j = 0; j < n; j++) { if (j == k) at = units; units += self.tiles[j].wide ? 2 : 1; }
    CGFloat u = (864 - 16 * (units - 1)) / (CGFloat)units;
    return NSMakeRect(48 + at * (u + 16), 522, self.tiles[k].wide ? 2 * u + 16 : u, 70);
}
- (NSRect)playRect { return NSMakeRect(W - 48 - 230, H - 70, 230, 52); }
- (NSRect)quitRect { return NSMakeRect(W - 48 - 230 - 16 - 150, H - 70, 150, 52); }
- (NSRect)panelRect { CGFloat h = 86 + 60 * (CGFloat)self.rows.count; return NSMakeRect(130, MAX(40, 486 - h), 700, h); }
- (NSRect)rowRect:(NSInteger)k { NSRect p = self.panelRect; return NSMakeRect(p.origin.x + 30, p.origin.y + 72 + 60 * k, p.size.width - 60, 52); }
- (NSRect)rowArrow:(NSInteger)k right:(BOOL)right { NSRect r = [self rowRect:k]; return NSMakeRect(right ? NSMaxX(r) - 34 : NSMaxX(r) - 330, r.origin.y + 3, 30, 30); }
- (NSRect)rowValue:(NSInteger)k { NSRect r = [self rowRect:k]; return NSMakeRect(NSMaxX(r) - 300, r.origin.y + 4, 262, 28); }
- (void)openPanel { self.open = YES; self.rowFocus = 0; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)closePanel { self.open = NO; self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)choose:(NSInteger)c { if (c == self.campaign) return; self.prevCampaign = self.campaign; self.switchT = self.t; self.campaign = c; self.needsDisplay = YES; if (self.onChange) self.onChange(); }
- (NSInteger)hit:(NSPoint)p
{
    if (NSPointInRect(p, self.playRect)) return HIT_PLAY;
    if (NSPointInRect(p, self.quitRect)) return self.open ? HIT_BACK : HIT_QUIT;
    if (self.open) {
        for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
            if (NSPointInRect(p, [self rowArrow:k right:NO])) return HIT_ROW + 10 * k;
            if (NSPointInRect(p, [self rowArrow:k right:YES])) return HIT_ROW + 10 * k + 2;
            if (NSPointInRect(p, [self rowRect:k])) return HIT_ROW + 10 * k + 1;
        }
        return NSPointInRect(p, self.panelRect) ? HIT_NONE : HIT_BACK;    /* a click outside the panel closes it */
    }
    for (NSInteger i = 0; i < NCAMP; i++) if (NSPointInRect(p, [self cardRect:i])) return HIT_CARD + i;
    for (NSInteger k = 0; k < (NSInteger)self.tiles.count; k++) if (NSPointInRect(p, [self tileRect:k])) return HIT_TILE + 10 * k + 1;
    return HIT_NONE;
}
- (void)updateTrackingAreas
{
    for (NSTrackingArea *t in self.trackingAreas) [self removeTrackingArea:t];
    [self addTrackingArea:[[NSTrackingArea alloc] initWithRect:self.bounds options:NSTrackingMouseMoved | NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect owner:self userInfo:nil]];
}
- (void)mouseMoved:(NSEvent *)e { NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]]; if (h != self.hover) { self.hover = h; self.needsDisplay = YES; } }
- (void)mouseExited:(NSEvent *)e { self.hover = HIT_NONE; self.needsDisplay = YES; }
- (void)mouseDown:(NSEvent *)e
{
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]];
    if (h >= HIT_CARD && h < HIT_CARD + NCAMP && e.clickCount == 2) { [self choose:h - HIT_CARD]; self.pressed = HIT_NONE; if (self.onPlay) self.onPlay(); return; }   /* double-click: play it */
    self.pressed = h; self.needsDisplay = YES;
}
- (void)mouseUp:(NSEvent *)e
{
    NSInteger h = [self hit:[self convertPoint:e.locationInWindow fromView:nil]], p = self.pressed; self.pressed = HIT_NONE; self.needsDisplay = YES;
    if (h != p || h == HIT_NONE) return;
    if (h == HIT_PLAY) { if (self.onPlay) self.onPlay(); return; }
    if (h == HIT_QUIT) { if (self.onQuit) self.onQuit(); return; }
    if (h == HIT_BACK) { [self closePanel]; return; }
    if (h >= HIT_ROW) { NSInteger k = (h - HIT_ROW) / 10; self.rowFocus = k; [self stepRow:k by:(h - HIT_ROW) % 10 == 0 ? -1 : 1]; return; }
    if (h >= HIT_TILE) { NSInteger k = (h - HIT_TILE) / 10; self.focus = k; [self activate:k]; return; }
    if (h >= HIT_CARD) { self.focus = -1; [self choose:h - HIT_CARD]; }
}
- (void)activate:(NSInteger)k
{
    if (k < 0 || k >= (NSInteger)self.tiles.count) return;
    GRTile *t = self.tiles[k]; if (t.activate) t.activate(); self.needsDisplay = YES;
}
- (void)stepRow:(NSInteger)k by:(NSInteger)dir
{
    GRTile *t = self.rows[k]; NSInteger n = (NSInteger)t.choices.count; t.index = (t.index + dir + n) % n;
    self.needsDisplay = YES; if (self.onChange) self.onChange();
}
- (void)keyDown:(NSEvent *)e
{
    if (self.open) {
        NSInteger rn = (NSInteger)self.rows.count;
        switch (e.keyCode) {
        case 0x24: case 0x4c: case 0x35: [self closePanel]; return;                          /* Return, Escape: back */
        case 0x7b: [self stepRow:self.rowFocus by:-1]; return;
        case 0x7c: [self stepRow:self.rowFocus by:1]; return;
        case 0x7e: self.rowFocus = (self.rowFocus + rn - 1) % rn; self.needsDisplay = YES; return;
        case 0x7d: case 0x30: self.rowFocus = (self.rowFocus + 1) % rn; self.needsDisplay = YES; return;
        }
        [super keyDown:e]; return;
    }
    NSInteger n = (NSInteger)self.tiles.count;
    switch (e.keyCode) {
    case 0x24: case 0x4c: if (self.focus >= 0) { [self activate:self.focus]; return; }        /* Return: the tile, else Play */
                          if (self.onPlay) self.onPlay(); return;
    case 0x35: if (self.onQuit) self.onQuit(); return;                                       /* Escape */
    case 0x7b: [self choose:(self.campaign + NCAMP - 1) % NCAMP]; return;                   /* left / right: the campaigns */
    case 0x7c: [self choose:(self.campaign + 1) % NCAMP]; return;
    case 0x7e: self.focus = self.focus < 0 ? n - 1 : self.focus - 1; self.needsDisplay = YES; return;   /* up / down: the cards, then each tile */
    case 0x7d: case 0x30: self.focus = self.focus + 1 >= n ? -1 : self.focus + 1; self.needsDisplay = YES; return;   /* also Tab */
    }
    [super keyDown:e];
}

static void draw_text(NSString *s, NSFont *f, NSColor *c, NSRect r, NSTextAlignment al, NSShadow *sh, CGFloat kern)
{
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = al; ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSMutableDictionary *a = [@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps, NSKernAttributeName: @(kern)} mutableCopy];
    if (sh) a[NSShadowAttributeName] = sh;
    [s drawInRect:r withAttributes:a];
}
static void fill_over(NSRect r) { NSRectFillUsingOperation(r, NSCompositingOperationSourceOver); }
/* an image filling a rectangle, aspect kept (cropped), focusX/focusY: where the crop sits (0 left/top .. 1 right/bottom) */
static void draw_cover(NSImage *img, NSRect r, CGFloat fraction, CGFloat focusX, CGFloat focusY)
{
    NSSize is = img.size;
    CGFloat sc = MAX(r.size.width / is.width, r.size.height / is.height), w = r.size.width / sc, h = r.size.height / sc;
    NSRect from = NSMakeRect((is.width - w) * focusX, (is.height - h) * (1 - focusY), w, h);   /* NSImage rows: bottom-up */
    [img drawInRect:r fromRect:from operation:NSCompositingOperationSourceOver fraction:fraction respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
}
/* a screenshot brought into the window's palette: partly desaturated, an olive cast over it */
static void grade(NSRect r, CGFloat desat, CGFloat tint)
{
    [[NSColor colorWithWhite:0.5 alpha:desat] setFill]; NSRectFillUsingOperation(r, NSCompositingOperationSaturation);
    [[accent_dim() colorWithAlphaComponent:tint] setFill]; NSRectFillUsingOperation(r, NSCompositingOperationColor);
}
static void stroke_rect(NSRect r, NSColor *c, CGFloat w) { [c setStroke]; NSBezierPath *b = [NSBezierPath bezierPathWithRect:NSInsetRect(r, w / 2, w / 2)]; b.lineWidth = w; [b stroke]; }
static void corners(NSRect r, CGFloat len, CGFloat w, NSColor *c)   /* a sight's brackets at the four corners */
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = NSMinX(r), x1 = NSMaxX(r), y0 = NSMinY(r), y1 = NSMaxY(r);
    [p moveToPoint:NSMakePoint(x0, y0 + len)]; [p lineToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x0 + len, y0)];
    [p moveToPoint:NSMakePoint(x1 - len, y0)]; [p lineToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x1, y0 + len)];
    [p moveToPoint:NSMakePoint(x1, y1 - len)]; [p lineToPoint:NSMakePoint(x1, y1)]; [p lineToPoint:NSMakePoint(x1 - len, y1)];
    [p moveToPoint:NSMakePoint(x0 + len, y1)]; [p lineToPoint:NSMakePoint(x0, y1)]; [p lineToPoint:NSMakePoint(x0, y1 - len)];
    p.lineWidth = w; p.lineCapStyle = NSLineCapStyleSquare; p.lineJoinStyle = NSLineJoinStyleMiter; [c setStroke]; [p stroke];
}
static void reticle(NSPoint c, CGFloat rad, CGFloat w, NSColor *col)   /* the crosshair in the game's logo */
{
    NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - rad, c.y - rad, 2 * rad, 2 * rad)];
    CGFloat in = rad * 0.45, out = rad * 1.35;
    [p moveToPoint:NSMakePoint(c.x - out, c.y)]; [p lineToPoint:NSMakePoint(c.x - in, c.y)];
    [p moveToPoint:NSMakePoint(c.x + in, c.y)]; [p lineToPoint:NSMakePoint(c.x + out, c.y)];
    [p moveToPoint:NSMakePoint(c.x, c.y - out)]; [p lineToPoint:NSMakePoint(c.x, c.y - in)];
    [p moveToPoint:NSMakePoint(c.x, c.y + in)]; [p lineToPoint:NSMakePoint(c.x, c.y + out)];
    p.lineWidth = w; [col setStroke]; [p stroke];
}
/* a field plate: olive-black, a khaki hairline and an inner one, a sight's brackets at the corners; lit: khaki warmth */
static void plate(NSRect r, CGFloat lit, NSColor *edge)
{
    NSGradient *g = [[NSGradient alloc] initWithColorsAndLocations:[rgb(0.085, 0.095, 0.072) colorWithAlphaComponent:0.90], 0.0, [rgb(0.035, 0.042, 0.032) colorWithAlphaComponent:0.94], 1.0, nil];
    [g drawInRect:r angle:-90];
    if (lit > 0) [[[NSGradient alloc] initWithColorsAndLocations:[accent() colorWithAlphaComponent:0.20 * lit], 0.0, [accent_dim() colorWithAlphaComponent:0.05 * lit], 1.0, nil] drawInRect:r angle:-90];
    [[NSColor colorWithWhite:1 alpha:0.05] setFill]; NSRectFillUsingOperation(NSMakeRect(r.origin.x + 1, r.origin.y + 1, r.size.width - 2, 1), NSCompositingOperationSourceOver);
    stroke_rect(r, edge ?: [accent() colorWithAlphaComponent:0.34], edge ? 1.5 : 1);
    stroke_rect(NSInsetRect(r, 3, 3), [accent() colorWithAlphaComponent:0.10], 1);
    corners(NSInsetRect(r, 3, 3), 7, 1.5, edge ?: [accent() colorWithAlphaComponent:0.7]);
}
/* a khaki rule fading out at both ends, a small crosshair in its middle */
static void rule_x(CGFloat x0, CGFloat x1, CGFloat y, CGFloat alpha)
{
    CGFloat m = (x0 + x1) / 2;
    [[[NSGradient alloc] initWithColors:@[[accent() colorWithAlphaComponent:0], [accent() colorWithAlphaComponent:alpha]]] drawInRect:NSMakeRect(x0, y - 0.5, m - 14 - x0, 1) angle:0];
    [[[NSGradient alloc] initWithColors:@[[accent() colorWithAlphaComponent:alpha], [accent() colorWithAlphaComponent:0]]] drawInRect:NSMakeRect(m + 14, y - 0.5, x1 - m - 14, 1) angle:0];
    reticle(NSMakePoint(m, y), 6, 1.2, [accent() colorWithAlphaComponent:alpha]);
}
- (void)drawButton:(NSRect)r title:(NSString *)title code:(NSInteger)code primary:(BOOL)primary enabled:(BOOL)enabled
{
    BOOL hot = self.hover == code && enabled, down = self.pressed == code && enabled;
    if (primary) {                 /* khaki, brushed, a crosshair before the word; dim when the campaign isn't installed */
        [NSGraphicsContext saveGraphicsState];
        if (enabled) { NSShadow *gl = [NSShadow new]; gl.shadowColor = [accent_hi() colorWithAlphaComponent:hot ? 0.55 : 0.30]; gl.shadowBlurRadius = 16; [gl set]; }
        NSGradient *pg = [[NSGradient alloc] initWithColorsAndLocations:
                          enabled ? (down ? accent_dim() : hot ? accent_hi() : rgb(0.80, 0.81, 0.60)) : rgb(0.22, 0.24, 0.17), 0.0,
                          enabled ? rgb(0.62, 0.63, 0.43) : rgb(0.16, 0.17, 0.12), 0.65,
                          enabled ? rgb(0.46, 0.48, 0.30) : rgb(0.12, 0.13, 0.09), 1.0, nil];
        [pg drawInRect:r angle:-90];
        [NSGraphicsContext restoreGraphicsState];
        [[NSColor colorWithWhite:1 alpha:enabled ? 0.28 : 0.06] setFill]; fill_over(NSMakeRect(r.origin.x + 2, r.origin.y + 2, r.size.width - 4, 1));
        [[NSColor colorWithWhite:0 alpha:0.18] setFill];                  /* (brushed metal) */
        for (CGFloat x = r.origin.x + 3; x < NSMaxX(r) - 3; x += 3) fill_over(NSMakeRect(x, r.origin.y + 4, 1, r.size.height - 8));
        stroke_rect(r, enabled ? ink() : [ink() colorWithAlphaComponent:0.6], 1.5);
        stroke_rect(NSInsetRect(r, 4, 4), [ink() colorWithAlphaComponent:enabled ? 0.35 : 0.2], 1);
        NSColor *tc = enabled ? ink() : [text_c() colorWithAlphaComponent:0.35];
        NSAttributedString *a = [[NSAttributedString alloc] initWithString:title attributes:@{NSFontAttributeName: heavy(30), NSKernAttributeName: @6}];
        CGFloat tw = a.size.width - 6, gx = NSMidX(r) - (tw + 34) / 2;
        reticle(NSMakePoint(gx + 11, NSMidY(r) - 1), 10, 2, tc);
        draw_text(title, heavy(30), tc, NSMakeRect(gx + 34, NSMidY(r) - 13, tw + 12, 32), NSTextAlignmentLeft, nil, 6);
    } else {
        plate(r, down ? 0.9 : hot ? 0.6 : 0, hot ? accent() : nil);
        draw_text(title, heavy(22), hot ? accent_hi() : text_c(), NSMakeRect(r.origin.x, NSMidY(r) - 11, r.size.width, 26), NSTextAlignmentCenter, nil, 5);
    }
}
- (void)drawArrow:(NSRect)r right:(BOOL)right lit:(BOOL)lit
{
    NSBezierPath *p = [NSBezierPath bezierPath]; CGFloat x0 = NSMidX(r) - 4, x1 = NSMidX(r) + 4, y0 = NSMidY(r) - 7, y1 = NSMidY(r) + 7, ym = NSMidY(r);
    if (right) { [p moveToPoint:NSMakePoint(x0, y0)]; [p lineToPoint:NSMakePoint(x1, ym)]; [p lineToPoint:NSMakePoint(x0, y1)]; }
    else { [p moveToPoint:NSMakePoint(x1, y0)]; [p lineToPoint:NSMakePoint(x0, ym)]; [p lineToPoint:NSMakePoint(x1, y1)]; }
    p.lineWidth = 2; p.lineCapStyle = NSLineCapStyleSquare; p.lineJoinStyle = NSLineJoinStyleMiter;
    [(lit ? accent_hi() : accent()) setStroke]; [p stroke];
}
- (void)drawCard:(NSInteger)i shadow:(NSShadow *)sh
{
    GRCampaign *c = self.campaigns[i]; NSRect r = [self cardRect:i];
    BOOL sel = self.campaign == i, hot = self.hover == HIT_CARD + i, foc = sel && self.focus == -1;
    if (sel) {                                                           /* the chosen one, lit from under */
        [NSGraphicsContext saveGraphicsState]; NSShadow *gl = [NSShadow new]; gl.shadowColor = [accent() colorWithAlphaComponent:0.45]; gl.shadowBlurRadius = 14; [gl set];
        [ink() setFill]; NSRectFill(r); [NSGraphicsContext restoreGraphicsState];
    }
    plate(r, sel ? 0.55 : hot ? 0.35 : 0, foc ? accent_hi() : sel ? accent() : hot ? [accent() colorWithAlphaComponent:0.75] : nil);
    NSRect ir = NSMakeRect(r.origin.x + 7, r.origin.y + 7, r.size.width - 14, 88);
    [NSGraphicsContext saveGraphicsState]; NSRectClip(ir);
    [ink() setFill]; NSRectFill(ir);
    if (c.card) { draw_cover(c.card, ir, 1, 0.5, 0.45); grade(ir, 0.2, 0.18); }
    else { [rgb(c.def->r, c.def->g, c.def->b) setFill]; NSRectFill(ir); }
    if (!c.installed) { [[NSColor colorWithWhite:0.5 alpha:1] setFill]; NSRectFillUsingOperation(ir, NSCompositingOperationSaturation); }
    if (!sel) { [[ink() colorWithAlphaComponent:hot ? 0.15 : 0.38] setFill]; fill_over(ir); }
    [[NSColor colorWithWhite:0 alpha:0.10] setFill]; for (CGFloat ly = ir.origin.y; ly < NSMaxY(ir); ly += 3) fill_over(NSMakeRect(ir.origin.x, ly, ir.size.width, 1));
    draw_text(@(c.def->theatre), heavy(11), sel ? accent_hi() : [text_c() colorWithAlphaComponent:0.75], NSMakeRect(ir.origin.x + 14, ir.origin.y + 8, ir.size.width - 28, 14), NSTextAlignmentLeft, sh, 2.5);
    [NSGraphicsContext restoreGraphicsState];
    stroke_rect(NSInsetRect(ir, -1, -1), [accent() colorWithAlphaComponent:sel ? 0.65 : 0.25], 1);
    if (sel) corners(NSInsetRect(ir, 5, 5), 10, 1.5, [accent_hi() colorWithAlphaComponent:0.9]);
    NSColor *tc = c.installed ? (sel || hot ? text_c() : [text_c() colorWithAlphaComponent:0.82]) : dim();
    draw_text(@(c.def->title).uppercaseString, heavy(20), tc, NSMakeRect(r.origin.x + 6, NSMaxY(ir) + 12, r.size.width - 12, 24), NSTextAlignmentCenter, sh, 2.5);
    NSString *st = c.installed ? @"READY" : @"NOT INSTALLED"; NSColor *sc = c.installed ? ready_c() : dim();
    NSAttributedString *at = [[NSAttributedString alloc] initWithString:st attributes:@{NSFontAttributeName: heavy(12), NSKernAttributeName: @3}];
    CGFloat x = NSMidX(r) - (at.size.width + (c.installed ? 12 : 0)) / 2, y = NSMaxY(r) - 25;
    if (c.installed) { [sc setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x, y + 4, 6, 6)] fill]; x += 12; }
    draw_text(st, heavy(12), sc, NSMakeRect(x, y, at.size.width + 6, 15), NSTextAlignmentLeft, nil, 3);
}
- (void)drawTile:(NSInteger)k shadow:(NSShadow *)sh
{
    GRTile *t = self.tiles[k]; NSRect r = [self tileRect:k]; NSDictionary *c = t.current ? t.current() : t.choices[t.index];
    BOOL hot = self.hover == HIT_TILE + 10 * k + 1, foc = self.focus == k, special = [c[@"accent"] boolValue], off = [c[@"off"] boolValue];
    plate(r, hot || foc ? 0.8 : 0, foc ? accent_hi() : hot ? accent() : nil);
    draw_text(t.title.uppercaseString, heavy(14), (hot || foc) ? accent_hi() : accent(), NSMakeRect(r.origin.x + 16, r.origin.y + 10, r.size.width - 30, 16), NSTextAlignmentLeft, nil, 3);
    NSColor *vc = off ? dim() : special ? accent_hi() : hot ? NSColor.whiteColor : text_c();
    draw_text(t.summary ? t.summary() : c[@"label"], body(t.summary ? 15 : 17, YES), vc, NSMakeRect(r.origin.x + 16, r.origin.y + 28, r.size.width - 28, 22), NSTextAlignmentLeft, sh, 0.2);
    NSString *note = t.summary ? (t.choices.firstObject[@"note"] ?: @"") : (c[@"note"] ?: @"");
    draw_text(note, body(10.5, NO), dim(), NSMakeRect(r.origin.x + 16, r.origin.y + 50, r.size.width - 26, 14), NSTextAlignmentLeft, nil, 0);
    if (!t.summary && !t.activate && t.choices.count > 1) for (NSUInteger q = 0; q < t.choices.count; q++) {   /* which choice of how many */
        NSRect d = NSMakeRect(NSMaxX(r) - 18 - 9 * (CGFloat)(t.choices.count - 1 - q), r.origin.y + 13, 5, 5);
        [(q == (NSUInteger)t.index ? accent_hi() : [accent() colorWithAlphaComponent:0.3]) setFill]; NSRectFill(d);
    }
}
- (void)drawPanel:(NSShadow *)sh                        /* Graphics Options: a panel over the window, a row per setting */
{
    [[ink() colorWithAlphaComponent:0.72] setFill]; fill_over(NSMakeRect(0, 0, W, H - 90));
    NSRect p = self.panelRect;
    NSShadow *glow = [NSShadow new]; glow.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; glow.shadowBlurRadius = 30; glow.shadowOffset = NSMakeSize(0, -8);
    [NSGraphicsContext saveGraphicsState]; [glow set]; [panel_c() setFill]; NSRectFill(p); [NSGraphicsContext restoreGraphicsState];
    stroke_rect(p, [accent() colorWithAlphaComponent:0.35], 1);
    corners(NSInsetRect(p, -7, -7), 18, 1.5, accent());
    [accent() setFill]; NSRectFill(NSMakeRect(p.origin.x, p.origin.y, p.size.width, 3));
    reticle(NSMakePoint(p.origin.x + 44, p.origin.y + 31), 9, 1.5, accent());
    draw_text(@"GRAPHICS OPTIONS", heavy(30), text_c(), NSMakeRect(p.origin.x + 68, p.origin.y + 18, 400, 34), NSTextAlignmentLeft, nil, 4);
    draw_text(@"FOR EVERY CAMPAIGN", heavy(14), dim(), NSMakeRect(NSMaxX(p) - 330, p.origin.y + 27, 300, 18), NSTextAlignmentRight, nil, 3);
    [[accent() colorWithAlphaComponent:0.25] setFill]; fill_over(NSMakeRect(p.origin.x + 30, p.origin.y + 58, p.size.width - 60, 1));
    for (NSInteger k = 0; k < (NSInteger)self.rows.count; k++) {
        GRTile *t = self.rows[k]; NSRect r = [self rowRect:k]; NSDictionary *c = t.choices[t.index];
        BOOL hot = self.hover >= HIT_ROW + 10 * k && self.hover <= HIT_ROW + 10 * k + 2, foc = self.rowFocus == k;
        if (foc || hot) { [[accent() colorWithAlphaComponent:foc ? 0.12 : 0.06] setFill]; fill_over(NSInsetRect(r, -10, -2));
                          if (foc) { [accent() setFill]; NSRectFill(NSMakeRect(r.origin.x - 10, r.origin.y - 2, 3, r.size.height + 4)); } }
        draw_text(t.title.uppercaseString, heavy(23), foc || hot ? accent() : text_c(), NSMakeRect(r.origin.x + 6, r.origin.y + 8, 260, 28), NSTextAlignmentLeft, sh, 3);
        [self drawArrow:[self rowArrow:k right:NO] right:NO lit:self.hover == HIT_ROW + 10 * k];
        [self drawArrow:[self rowArrow:k right:YES] right:YES lit:self.hover == HIT_ROW + 10 * k + 2];
        draw_text(c[@"label"], body(17, YES), self.hover == HIT_ROW + 10 * k + 1 ? NSColor.whiteColor : text_c(), [self rowValue:k], NSTextAlignmentCenter, sh, 0.3);
        draw_text(c[@"note"] ?: @"", body(11.5, NO), dim(), NSMakeRect(r.origin.x + 6, r.origin.y + 33, r.size.width - 12, 18), NSTextAlignmentRight, nil, 0);
        if (k + 1 < (NSInteger)self.rows.count) { [[text_c() colorWithAlphaComponent:0.08] setFill]; fill_over(NSMakeRect(r.origin.x, NSMaxY(r) + 4, r.size.width, 1)); }
    }
}
- (NSString *)cardHint:(NSInteger)i
{
    GRCampaign *c = self.campaigns[i];
    if (!c.installed) {
        if (i == 0) return gr_dropin ? @"Ghost Recon's files are missing" : @"Ghost Recon's files are missing: run ./install.sh again";
        return [NSString stringWithFormat:@"%s isn't installed: download_depot %s in Steam's console, then %@", c.def->title, c.def->depot,
                gr_dropin ? [NSString stringWithFormat:@"copy its Mods/%s into the game's Mods", c.def->mods] : @"./install.sh"];
    }
    return [NSString stringWithFormat:@"%s · double-click or Return to play", c.def->title];
}
- (NSString *)currentHint
{
    if (self.open) return @"←/→ change  ·  ↑/↓ move  ·  Return or Esc goes back";
    if (self.hover >= HIT_CARD && self.hover < HIT_CARD + NCAMP) return [self cardHint:self.hover - HIT_CARD];
    NSInteger k = -1;
    if (self.hover >= HIT_TILE && self.hover < HIT_ROW) k = (self.hover - HIT_TILE) / 10; else if (self.hover == HIT_NONE && self.focus >= 0) k = self.focus;
    if (k >= 0 && k < (NSInteger)self.tiles.count) { GRTile *t = self.tiles[k]; return (t.current ? t.current() : t.choices[t.index])[@"note"]; }
    if (!self.chosen.installed && (self.hover == HIT_PLAY || self.hover == HIT_NONE)) return [self cardHint:self.campaign];
    return self.hint;
}
/* ---- the moving part: the chosen campaign's pictures drifting and crossfading behind the window, dust drifting, far
 * guns flashing and tracers crossing the sky, the portrait in a gun-sight's frame with a scan sweeping down it; the still
 * part (titles, cards, tiles, buttons) drawn once into a picture and again only when what it shows changes ---- */
static double hash01(double x) { double s = sin(x * 12.9898) * 43758.5453; return s - floor(s); }
static NSImage *offscreen(NSSize size, CGFloat scale, void (^draw)(void))
{
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)ceil(size.width * scale) pixelsHigh:(NSInteger)ceil(size.height * scale)
                                                                 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep = [rep bitmapImageRepByRetaggingWithColorSpace:NSColorSpace.sRGBColorSpace] ?: rep;   /* (as the window's: no conversion per frame) */
    rep.size = size;
    CGContextRef cg = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep].CGContext;
    [NSGraphicsContext saveGraphicsState];
    CGContextTranslateCTM(cg, 0, size.height); CGContextScaleCTM(cg, 1, -1);
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithCGContext:cg flipped:YES]];
    draw();
    [NSGraphicsContext restoreGraphicsState];
    NSImage *img = [[NSImage alloc] initWithSize:size]; [img addRepresentation:rep];
    return img;
}
static NSImage *ready(NSImage *img, CGFloat maxw)   /* decoded once, at most maxw pixels wide (its pixels, not its points) */
{
    if (!img || img.size.width < 16) return nil;
    NSSize s = img.size; NSInteger pw = 0, ph = 0;
    for (NSImageRep *r in img.representations) if (r.pixelsWide > pw) { pw = r.pixelsWide; ph = r.pixelsHigh; }
    if (pw > 0 && ph > 0) s = NSMakeSize(pw, ph);
    CGFloat k = MIN(1.0, maxw / s.width); NSSize o = NSMakeSize(round(s.width * k), round(s.height * k));
    return offscreen(o, 1, ^{ [img drawInRect:NSMakeRect(0, 0, o.width, o.height) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}]; });
}
static void draw_fill_z(NSImage *img, NSRect r, CGFloat alpha, CGFloat z, CGFloat fx, CGFloat fy, NSImageInterpolation q)
{
    if (!img) return; NSSize s = img.size; if (s.width <= 0 || s.height <= 0) return;
    CGFloat k = MAX(r.size.width / s.width, r.size.height / s.height) * z, w = r.size.width / k, h = r.size.height / k;
    [img drawInRect:r fromRect:NSMakeRect((s.width - w) * fx, (s.height - h) * (1 - fy), w, h) operation:NSCompositingOperationSourceOver fraction:alpha respectFlipped:YES hints:@{NSImageHintInterpolation: @(q)}];
}
- (CGFloat)scale { return self.window ? self.window.backingScaleFactor : 2; }
- (NSRect)portraitRect { return NSMakeRect(W - 48 - 300, 30, 300, 470); }
- (NSRect)portraitPicture { NSRect in = NSInsetRect(self.portraitRect, 10, 10); in.size.height = floor(in.size.width * 800 / 594); return in; }   /* (the box's shape) */
- (NSImage *)sprite:(NSString *)key colors:(NSArray<NSColor *> *)cols
{
    NSImage *c = self.cache[key]; if (c) return c;
    c = offscreen(NSMakeSize(128, 128), 1, ^{ [[[NSGradient alloc] initWithColors:cols] drawFromCenter:NSMakePoint(64, 64) radius:0 toCenter:NSMakePoint(64, 64) radius:64 options:0]; });
    self.cache[key] = c; return c;
}
static void draw_sprite(NSImage *img, NSPoint c, CGFloat rx, CGFloat ry, CGFloat alpha)
{
    if (alpha <= 0.002) return;
    [img drawInRect:NSMakeRect(c.x - rx, c.y - ry, 2 * rx, 2 * ry) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:MIN(1, alpha) respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
}
/* a campaign's slides, each drifting from when it starts fading in until it has faded out; tt: its own clock */
- (void)backdrop:(GRCampaign *)c alpha:(CGFloat)alpha clock:(double)tt
{
    NSArray<NSImage *> *sc = c.scenes; NSUInteger n = sc.count; NSRect b = self.bounds; if (!n) return; if (tt < 0) tt = 0;
    double per = 8.0, fadeT = 1.6;
    void (^slide)(NSUInteger, double, CGFloat) = ^(NSUInteger j, double local, CGFloat a) {
        double p = local / (per + fadeT); CGFloat dir = (j % 2) ? 1 : -1;
        draw_fill_z(sc[j % n], b, a * alpha, (CGFloat)(1.04 + 0.07 * p), (CGFloat)(0.5 + dir * 0.10 * (p - 0.5)), (CGFloat)(0.45 + 0.05 * (p - 0.5)), NSImageInterpolationMedium);
    };
    if (n == 1) { draw_fill_z(sc[0], b, alpha, (CGFloat)(1.08 + 0.035 * sin(tt * 0.11)), (CGFloat)(0.5 + 0.06 * sin(tt * 0.07)), 0.45, NSImageInterpolationMedium); return; }
    NSUInteger k = (NSUInteger)(tt / per); double local = tt - (double)k * per;
    if (local < fadeT && k > 0) { slide(k - 1, local + per, 1); slide(k, local, (CGFloat)(local / fadeT)); }
    else slide(k, local, 1);
}
- (NSImage *)gradeImage   /* drawn once: the field's olive cast, dark on the left for the title and below for the cards */
{
    NSImage *c = self.cache[@"grade"]; if (c) return c;
    NSRect b = self.bounds;
    c = offscreen(b.size, 1, ^{
        [[accent_dim() colorWithAlphaComponent:0.16] setFill]; NSRectFillUsingOperation(b, NSCompositingOperationSourceOver);
        NSGradient *left = [[NSGradient alloc] initWithColorsAndLocations:[ink() colorWithAlphaComponent:0.82], 0.0, [ink() colorWithAlphaComponent:0.45], 0.42, [ink() colorWithAlphaComponent:0.10], 0.76, [ink() colorWithAlphaComponent:0.05], 1.0, nil];
        [left drawInRect:b angle:0];
        NSGradient *foot = [[NSGradient alloc] initWithColorsAndLocations:[ink() colorWithAlphaComponent:0.15], 0.0, [ink() colorWithAlphaComponent:0], 0.30, [ink() colorWithAlphaComponent:0.55], 0.55, [ink() colorWithAlphaComponent:0.88], 0.75, [ink() colorWithAlphaComponent:0.96], 1.0, nil];
        [foot drawInRect:b angle:-90];
    });
    self.cache[@"grade"] = c; return c;
}
- (NSString *)signature
{
    NSMutableString *s = [NSMutableString stringWithFormat:@"%ld|%ld|%ld|%ld|%d|%ld|%@|%.0f", (long)self.campaign, (long)self.hover, (long)self.pressed, (long)self.focus, self.open, (long)self.rowFocus, self.currentHint ?: @"", self.scale];
    for (GRTile *t in self.tiles) [s appendFormat:@"|%@", t.summary ? t.summary() : (t.current ? t.current() : t.choices[t.index])[@"label"]];
    for (GRTile *t in self.rows) [s appendFormat:@"|%ld", (long)t.index];
    for (GRCampaign *c in self.campaigns) [s appendFormat:@"|%d", c.installed];
    return s;
}
static int frames_drawn;   /* (GR_LAUNCHER_TIMING: frames a second, in the window) */
- (void)drawRect:(NSRect)dirty
{
    NSRect b = self.bounds; double T = self.t; frames_drawn++;
    if (!self.cache) self.cache = [NSMutableDictionary dictionary];
    if (![self.cache[@"scale"] isEqual:@(self.scale)]) { [self.cache removeAllObjects]; self.cache[@"scale"] = @(self.scale); }
    [ink() setFill]; NSRectFill(b);
    double fade = MIN(1.0, (T - self.switchT) / 0.6); BOOL fading = fade < 1 && self.prevCampaign != self.campaign;
    if (fading) [self backdrop:self.campaigns[self.prevCampaign] alpha:1 clock:T];
    [self backdrop:self.chosen alpha:fading ? (CGFloat)fade : 1 clock:T];
    if (!self.chosen.installed) { [[NSColor colorWithWhite:0.5 alpha:1] setFill]; NSRectFillUsingOperation(b, NSCompositingOperationSaturation); }
    [self.gradeImage drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationLow)}];
    /* smoke rolling across; far guns flashing along the horizon; tracers; dust */
    NSImage *mist = [self sprite:@"mist" colors:@[rgb(0.28, 0.30, 0.24), [rgb(0.22, 0.24, 0.19) colorWithAlphaComponent:0.45], [ink() colorWithAlphaComponent:0]]];
    for (int i = 0; i < 6; i++) {
        double sp = 0.5 + hash01(i * 3.1), y = H * (0.30 + 0.55 * hash01(i * 7.7)), r = 150 + 160 * hash01(i * 1.3);
        double x = fmod(hash01(i * 5.9) * (W + 2 * r) + T * 7 * sp, W + 2 * r) - r;
        draw_sprite(mist, NSMakePoint(x, y + 10 * sin(T * 0.2 + i)), r, r * 0.55, 0.13 + 0.05 * sin(T * 0.3 + i));
    }
    NSImage *flash = [self sprite:@"flash" colors:@[[NSColor colorWithSRGBRed:1 green:0.75 blue:0.4 alpha:1], [NSColor colorWithSRGBRed:0.95 green:0.4 blue:0.1 alpha:0.4], [ink() colorWithAlphaComponent:0]]];
    for (int i = 0; i < 3; i++) {
        double period = 4.8 + 1.9 * i, ph = fmod(T + i * 1.7, period), k = floor((T + i * 1.7) / period); if (ph > 0.8) continue;
        double a = ph < 0.06 ? ph / 0.06 : pow(1 - (ph - 0.06) / 0.74, 2);
        draw_sprite(flash, NSMakePoint(W * (0.10 + 0.80 * hash01(k * 3.7 + i)), H * (0.36 + 0.10 * hash01(k * 1.9 + i))), 100 + 50 * hash01(k + i), 60, 0.30 * a);
    }
    for (int i = 0; i < 2; i++) {
        double period = 3.4 + 1.5 * i, ph = fmod(T + i * 1.3, period) / 0.5, k = floor((T + i * 1.3) / period); if (ph > 1) continue;
        double y0 = H * (0.12 + 0.30 * hash01(k * 5.1 + i)), dir = hash01(k * 2.3 + i) > 0.5 ? 1 : -1, x = (dir > 0 ? -40 : W + 40) + dir * ph * (W + 80), y = y0 - ph * 50 * hash01(k + 7);
        NSBezierPath *p = [NSBezierPath bezierPath]; [p moveToPoint:NSMakePoint(x, y)]; [p lineToPoint:NSMakePoint(x - dir * 44, y + 7 * hash01(k + 7))];
        p.lineWidth = 1.5; p.lineCapStyle = NSLineCapStyleRound; [[NSColor colorWithSRGBRed:1 green:0.86 blue:0.55 alpha:0.6 * (1 - ph * 0.5)] setStroke]; [p stroke];
    }
    for (int i = 0; i < 80; i++) {
        double sx = hash01(i * 1.618), sy = hash01(i * 2.414 + 7), sp = 0.35 + hash01(i * 0.577 + 3);
        double x = fmod(sx * (W + 60) - T * 18 * sp, W + 60); if (x < 0) x += W + 60; x -= 30;
        double y = fmod(sy * (H + 20) + T * 4 * sp + 6 * sin(T * 0.8 * sp + i), H + 20) - 10;
        [[accent_hi() colorWithAlphaComponent:0.08 + 0.16 * fabs(sin(T * 0.6 * sp + i))] setFill]; CGFloat r = (CGFloat)(0.5 + 0.9 * sp);
        NSRectFillUsingOperation(NSMakeRect(x - r, y - r * 0.7, r * 2.2, r * 1.4), NSCompositingOperationSourceOver);
    }
    /* the portrait (its frame is in the still part): the chosen campaign's box art or field picture, a scan sweeping down */
    {
        NSRect in = self.portraitPicture;
        [NSGraphicsContext saveGraphicsState]; NSRectClip(in); [ink() setFill]; NSRectFill(in);
        GRCampaign *c = self.chosen, *pc = self.campaigns[self.prevCampaign];
        if (fading && pc.portrait) draw_fill_z(pc.portrait, in, 1, pc.coverZ, pc.coverFx, pc.coverFy, NSImageInterpolationHigh);
        if (c.portrait) draw_fill_z(c.portrait, in, fading ? (CGFloat)fade : 1, (CGFloat)(c.coverZ + 0.012 * (0.5 + 0.5 * sin(T * 0.21))), c.coverFx, c.coverFy, NSImageInterpolationHigh);
        if (!c.installed) { [[NSColor colorWithWhite:0.5 alpha:1] setFill]; NSRectFillUsingOperation(in, NSCompositingOperationSaturation); }
        double ph = fmod(T * 0.18, 1.0); CGFloat y = in.origin.y + ph * in.size.height;
        [[[NSGradient alloc] initWithColors:@[[signal_c() colorWithAlphaComponent:0], [signal_c() colorWithAlphaComponent:0.10], [signal_c() colorWithAlphaComponent:0]]] drawInRect:NSMakeRect(in.origin.x, y - 26, in.size.width, 52) angle:90];
        [[signal_c() colorWithAlphaComponent:0.35] setFill]; fill_over(NSMakeRect(in.origin.x, y, in.size.width, 1));
        [[NSColor colorWithWhite:0 alpha:0.07] setFill]; for (CGFloat ly = in.origin.y; ly < NSMaxY(in); ly += 3) fill_over(NSMakeRect(in.origin.x, ly, in.size.width, 1));
        NSGradient *foot = [[NSGradient alloc] initWithColorsAndLocations:[ink() colorWithAlphaComponent:0], 0.78, [ink() colorWithAlphaComponent:0.75], 1.0, nil]; [foot drawInRect:in angle:90];
        [NSGraphicsContext restoreGraphicsState];
    }
    NSString *sig = self.signature;
    if (!self.cache[@"ui"] || ![self.cache[@"uiSig"] isEqual:sig]) { self.cache[@"ui"] = offscreen(b.size, self.scale, ^{ [self drawStill]; }); self.cache[@"uiSig"] = sig; }
    [(NSImage *)self.cache[@"ui"] drawInRect:b fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    if (self.chosen.installed && !self.open) {                         /* Play: its sight brackets breathing */
        CGFloat a = 0.35 + 0.35 * (0.5 + 0.5 * sin(T * 2.2)), d = 4 + 2 * sin(T * 2.2);
        corners(NSInsetRect(self.playRect, -d, -d), 9, 1.5, [accent_hi() colorWithAlphaComponent:a]);
    }
}
- (void)drawStill
{
    NSRect b = self.bounds; GRCampaign *c = self.chosen; (void)b;
    NSShadow *sh = [NSShadow new]; sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.85]; sh.shadowOffset = NSMakeSize(0, -1); sh.shadowBlurRadius = 3;
    /* the portrait's frame: gunmetal, range ticks down its sides, brackets at its corners, the picture's window clear, a
     * caption band under it: the theatre and the operation */
    {
        NSRect pr = self.portraitRect, in = self.portraitPicture;
        NSShadow *ps = [NSShadow new]; ps.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; ps.shadowBlurRadius = 18; ps.shadowOffset = NSMakeSize(0, -6);
        [NSGraphicsContext saveGraphicsState]; [ps set]; [panel_c() setFill]; NSRectFill(pr); [NSGraphicsContext restoreGraphicsState];
        [[[NSGradient alloc] initWithStartingColor:rgb(0.17, 0.18, 0.14) endingColor:rgb(0.05, 0.06, 0.045)] drawInRect:pr angle:-70];
        [[NSColor colorWithWhite:0 alpha:0.16] setFill];                  /* (brushed) */
        for (CGFloat x = pr.origin.x + 2; x < NSMaxX(pr) - 2; x += 2) fill_over(NSMakeRect(x, pr.origin.y + 2, 1, pr.size.height - 4));
        stroke_rect(pr, accent(), 1.5);
        stroke_rect(NSInsetRect(pr, 5, 5), [accent() colorWithAlphaComponent:0.30], 1);
        [[accent() colorWithAlphaComponent:0.55] setFill];
        for (CGFloat ty = in.origin.y + 14; ty < NSMaxY(in) - 10; ty += 10) { CGFloat len = fmod(ty - in.origin.y, 40) < 10 ? 5 : 3;
            NSRectFill(NSMakeRect(pr.origin.x + 2, ty, len, 1)); NSRectFill(NSMakeRect(NSMaxX(pr) - 2 - len, ty, len, 1)); }
        NSRectFillUsingOperation(in, NSCompositingOperationClear);
        stroke_rect(NSInsetRect(in, -1, -1), [NSColor colorWithWhite:0 alpha:0.95], 1);
        corners(NSInsetRect(in, 7, 7), 18, 2, accent_hi());
        reticle(NSMakePoint(NSMidX(in), NSMidY(in) + 30), 11, 1, [signal_c() colorWithAlphaComponent:0.30]);
        NSRect cap = NSMakeRect(pr.origin.x + 10, NSMaxY(in) + 1, pr.size.width - 20, NSMaxY(pr) - 10 - NSMaxY(in) - 1);
        [[ink() colorWithAlphaComponent:0.85] setFill]; NSRectFill(cap);
        rule_x(cap.origin.x + 14, NSMaxX(cap) - 14, cap.origin.y + 12, 0.75);
        draw_text(@(c.def->theatre), heavy(22), text_c(), NSMakeRect(cap.origin.x, cap.origin.y + 22, cap.size.width, 26), NSTextAlignmentCenter, sh, 6);
        draw_text(@(c.def->op), heavy(11.5), accent(), NSMakeRect(cap.origin.x, cap.origin.y + 47, cap.size.width, 14), NSTextAlignmentCenter, nil, 3);
    }
    /* the title: the game's own logo (from GOG's key art, else keyed out of its main menu), else as on the box */
    NSShadow *ts = [NSShadow new]; ts.shadowColor = [NSColor colorWithWhite:0 alpha:0.8]; ts.shadowOffset = NSMakeSize(0, -2); ts.shadowBlurRadius = 10;
    CGFloat mid = 48 + 532 / 2;
    if (self.logo) {
        NSSize ls = self.logo.size; CGFloat lh = 172, lw = lh * ls.width / MAX(1, ls.height);
        if (lw > 500) { lw = 500; lh = lw * ls.height / ls.width; }
        NSShadow *ls2 = [NSShadow new]; ls2.shadowColor = [NSColor colorWithWhite:0 alpha:0.9]; ls2.shadowOffset = NSMakeSize(0, -3); ls2.shadowBlurRadius = 9;
        [NSGraphicsContext saveGraphicsState]; [ls2 set];
        [self.logo drawInRect:NSMakeRect(mid - lw / 2, 22 + (172 - lh) / 2, lw, lh) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:@{NSImageHintInterpolation: @(NSImageInterpolationHigh)}];
        [NSGraphicsContext restoreGraphicsState];
    } else {
        draw_text(@"TOM CLANCY’S", heavy(19), [text_c() colorWithAlphaComponent:0.82], NSMakeRect(48, 52, 532, 22), NSTextAlignmentCenter, ts, 6);
        draw_text(@"GHOST RECON", heavy(88), text_c(), NSMakeRect(48, 72, 532, 92), NSTextAlignmentCenter, ts, 3);
    }
    rule_x(64, 48 + 532 - 16, 206, 0.8);
    NSString *credit = [NSString stringWithFormat:@"%@RED STORM ENTERTAINMENT  ·  %s", c.def->sub ? [NSString stringWithFormat:@"%s  ·  ", c.def->sub] : @"", c.def->year];
    draw_text(credit, heavy(15), accent(), NSMakeRect(48, 218, 532, 18), NSTextAlignmentCenter, sh, 4);
    { NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.alignment = NSTextAlignmentCenter; ps.lineSpacing = 3;
      [@(c.def->blurb) drawWithRect:NSMakeRect(70, 242, 488, 44) options:NSStringDrawingUsesLineFragmentOrigin
                       attributes:@{NSFontAttributeName: [NSFontManager.sharedFontManager convertFont:body(14, NO) toHaveTrait:NSItalicFontMask],
                                    NSForegroundColorAttributeName: [text_c() colorWithAlphaComponent:0.92], NSParagraphStyleAttributeName: ps, NSShadowAttributeName: sh}]; }
    /* the campaigns */
    reticle(NSMakePoint(55, 303), 5, 1.2, accent());
    draw_text(@"CAMPAIGNS", heavy(15), accent(), NSMakeRect(66, 295, 300, 18), NSTextAlignmentLeft, nil, 4);
    draw_text(@"THE GHOSTS  ·  ONE PROGRAM, ALL THREE", heavy(11), [dim() colorWithAlphaComponent:0.8], NSMakeRect(48 + 532 - 360, 298, 360, 14), NSTextAlignmentRight, nil, 2.5);
    reticle(NSMakePoint(55, 507), 5, 1.2, accent());
    draw_text(@"SETTINGS", heavy(15), accent(), NSMakeRect(66, 499, 300, 18), NSTextAlignmentLeft, nil, 4);
    NSInteger hov = self.hover, foc = self.focus; if (self.open) self.hover = self.focus = HIT_NONE;   /* under the panel: nothing lit */
    for (NSInteger i = 0; i < NCAMP; i++) [self drawCard:i shadow:sh];
    for (NSInteger k = 0; k < (NSInteger)self.tiles.count; k++) [self drawTile:k shadow:sh];
    self.hover = hov; self.focus = foc;
    [[[NSGradient alloc] initWithColors:@[[accent() colorWithAlphaComponent:0], [accent() colorWithAlphaComponent:0.3], [accent() colorWithAlphaComponent:0]]] drawInRect:NSMakeRect(48, H - 86, W - 96, 1) angle:0];
    draw_text(@"NATIVE FOR APPLE SILICON  ·  METAL", heavy(11), [dim() colorWithAlphaComponent:0.75], NSMakeRect(48, H - 22, 400, 14), NSTextAlignmentLeft, nil, 3);
    if (self.open) [self drawPanel:sh];
    NSString *hint = [self currentHint];
    if (hint.length) {                                                   /* up to two lines beside Quit */
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new]; ps.lineBreakMode = NSLineBreakByWordWrapping;
        NSDictionary *a = @{NSFontAttributeName: body(12.5, NO), NSForegroundColorAttributeName: dim(), NSParagraphStyleAttributeName: ps, NSShadowAttributeName: sh};
        NSRect hr = NSMakeRect(48, 0, NSMinX(self.quitRect) - 70, 40);
        CGFloat th = MIN(40, ceil([hint boundingRectWithSize:hr.size options:NSStringDrawingUsesLineFragmentOrigin attributes:a].size.height));
        hr.origin.y = NSMidY(self.quitRect) - th / 2; hr.size.height = th + 2; [hint drawWithRect:hr options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine attributes:a];
    }
    [self drawButton:self.quitRect title:self.open ? @"BACK" : @"QUIT" code:self.open ? HIT_BACK : HIT_QUIT primary:NO enabled:YES];
    [self drawButton:self.playRect title:@"PLAY" code:HIT_PLAY primary:YES enabled:c.installed];
}
@end

// ---------------------------------------------------------------- updates (the other ports' updater)
enum { UPD_NONE, UPD_CHECKING, UPD_CURRENT, UPD_AVAILABLE, UPD_ERROR };
static NSString *short_commit(NSString *c) { return c.length > 7 ? [c substringToIndex:7] : (c ?: @""); }
static NSString *update_check(NSString *updater)     /* the newest commit of the branch on GitHub; nil if it can't be reached */
{
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater, @"--check"];
    NSPipe *p = [NSPipe pipe]; t.standardOutput = p; t.standardError = [NSFileHandle fileHandleWithNullDevice];
    if (![t launchAndReturnError:nil]) return nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC), dispatch_get_global_queue(0, 0), ^{ if (t.running) [t terminate]; });
    NSData *d = [p.fileHandleForReading readDataToEndOfFile]; [t waitUntilExit];
    NSString *out = [[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (t.terminationStatus != 0 || !out.length) return nil;
    if (out.length >= 40) return [out substringToIndex:40];   /* a commit (an app built from source) */
    return [out rangeOfCharacterFromSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].location == NSNotFound ? out : nil;   /* a release's tag (the downloaded app) */
}
static NSArray<NSDictionary *> *update_choice(int state, NSString *branch, NSString *built, NSString *latest)
{
    NSString *label = @"Unavailable", *note = @"This copy wasn't installed from the GitHub repository"; BOOL lit = NO;
    switch (state) {
    case UPD_CHECKING: label = @"Checking…"; note = [NSString stringWithFormat:@"Asking GitHub for the newest %@", branch]; break;
    case UPD_CURRENT: label = @"Up to Date"; note = [NSString stringWithFormat:@"%@ %@ · click to check again", branch, short_commit(built)]; break;
    case UPD_AVAILABLE: label = @"Update Ready"; lit = YES; note = [NSString stringWithFormat:@"%@ → %@: click to install (the game is rebuilt from your copy)", short_commit(built), short_commit(latest)]; break;
    case UPD_ERROR: label = @"Can’t Check"; note = @"GitHub unreachable or not signed in: click to retry"; break;
    }
    return @[@{@"value": @"", @"label": label, @"note": note, @"accent": @(lit)}];
}
static NSString *update_phase(NSString *line, NSString *branch)
{
    if ([branch isEqualToString:@"release"]) {   /* the downloaded app's updater (setup/update.sh) */
        if ([line hasPrefix:@"== downloading "]) return [NSString stringWithFormat:@"Downloading %@ from GitHub", [line substringFromIndex:15]];
        if ([line hasPrefix:@"== unpacking"]) return @"Unpacking it";
        if ([line hasPrefix:@"== installing"]) return @"Installing the new app";
        return nil;
    }
    if ([line hasPrefix:@"== fetching"]) return @"Downloading the update from GitHub";
    if ([line hasPrefix:[NSString stringWithFormat:@"== %@:", branch]]) return [@"Got " stringByAppendingString:[line substringFromIndex:branch.length + 4]];
    if ([line hasPrefix:@"== recompiling"]) return @"Rebuilding Ghost Recon from your copy: translating it to native code";
    if ([line hasPrefix:@"== installing"]) return @"Installing the new app";
    return nil;
}
@interface GRBlockTarget : NSObject
@property (copy) void (^fire)(void);
- (void)clicked:(id)b;
@end
@implementation GRBlockTarget
- (void)clicked:(id)b { (void)b; if (self.fire) self.fire(); }
@end
static BOOL update_run(NSWindow *parent, NSString *updater, NSString *branch, NSString *logPath)   /* modal progress; YES when rebuilt */
{
    NSPanel *pn = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 520, 170) styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
    pn.title = @"Updating";
    NSTextField *title = [NSTextField labelWithString:@"Updating to the newest version"]; title.font = [NSFont boldSystemFontOfSize:14]; title.frame = NSMakeRect(20, 128, 480, 22);
    NSTextField *status = [NSTextField wrappingLabelWithString:@"Starting…"]; status.frame = NSMakeRect(20, 64, 480, 56);
    NSProgressIndicator *spin = [[NSProgressIndicator alloc] initWithFrame:NSMakeRect(20, 44, 480, 12)]; spin.indeterminate = YES; [spin startAnimation:nil];
    NSTextField *time = [NSTextField labelWithString:@"Around fifteen minutes. Your saves and settings are kept."]; time.font = [NSFont systemFontOfSize:11]; time.textColor = NSColor.secondaryLabelColor; time.frame = NSMakeRect(20, 14, 370, 18);
    NSButton *btn = [NSButton buttonWithTitle:@"Close" target:nil action:nil]; btn.frame = NSMakeRect(400, 8, 100, 30); btn.hidden = YES;
    for (NSView *x in @[title, status, spin, time, btn]) [pn.contentView addSubview:x];
    if (parent) [pn setFrameOrigin:NSMakePoint(NSMidX(parent.frame) - 260, NSMidY(parent.frame) - 85)]; else [pn center];
    [[NSFileManager defaultManager] createFileAtPath:logPath contents:nil attributes:nil];
    NSFileHandle *log = [NSFileHandle fileHandleForWritingAtPath:logPath];
    NSTask *t = [NSTask new]; t.executableURL = [NSURL fileURLWithPath:@"/bin/bash"]; t.arguments = @[updater];
    NSPipe *pipe = [NSPipe pipe]; t.standardOutput = pipe; t.standardError = pipe;
    NSMutableString *pending = [NSMutableString new], *tail = [NSMutableString new];
    pipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *h) {
        NSData *d = h.availableData; if (!d.length) return;
        [log writeData:d];
        NSString *chunk = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding] ?: @"";
        @synchronized (pending) {
            [pending appendString:chunk]; NSRange nl;
            while ((nl = [pending rangeOfString:@"\n"]).location != NSNotFound) {
                NSString *line = [pending substringToIndex:nl.location]; [pending deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
                [tail appendFormat:@"%@\n", line]; if (tail.length > 600) [tail deleteCharactersInRange:NSMakeRange(0, tail.length - 600)];
                NSString *ph = update_phase(line, branch); if (ph) on_main(^{ status.stringValue = ph; });
            }
        }
    };
    __block BOOL ok = NO;
    __attribute__((objc_precise_lifetime)) GRBlockTarget *bt = [GRBlockTarget new];   /* a button's target is weak: kept here */
    bt.fire = ^{ [NSApp stopModal]; }; btn.target = bt; btn.action = @selector(clicked:);
    t.terminationHandler = ^(NSTask *task) {
        int code = task.terminationStatus;
        on_main(^{
            pipe.fileHandleForReading.readabilityHandler = nil; [log closeFile];
            [spin stopAnimation:nil]; spin.hidden = YES; btn.hidden = NO;
            if (code == 0) { ok = YES; title.stringValue = @"Updated"; status.stringValue = @"The new version is installed. The app restarts when you press Restart."; btn.title = @"Restart"; }
            else {
                NSString *last; @synchronized (pending) { last = [[tail componentsSeparatedByString:@"\n"] componentsJoinedByString:@" "]; }
                title.stringValue = @"The update didn't finish";
                status.stringValue = [NSString stringWithFormat:@"Nothing was changed if it stopped before installing. Details: %@  (%@)", logPath, last.length > 160 ? [last substringFromIndex:last.length - 160] : last];
                time.stringValue = @"";
            }
        });
    };
    if (![t launchAndReturnError:nil]) { [log closeFile]; return NO; }
    [pn makeKeyAndOrderFront:nil]; [NSApp runModalForWindow:pn]; [pn orderOut:nil];
    return ok;
}

// ---------------------------------------------------------------- the choices
static NSImage *image_at(NSArray<NSString *> *dirs, NSString *name)
{
    for (NSString *d in dirs) { NSImage *i = [[NSImage alloc] initWithContentsOfFile:[d stringByAppendingPathComponent:name]]; if (i.size.width > 16) return i; }
    return nil;
}
static NSInteger index_of(NSArray<NSDictionary *> *c, id v, NSInteger dflt)
{ for (NSUInteger k = 0; k < c.count; k++) if ([c[k][@"value"] isEqual:v]) return (NSInteger)k; return dflt; }
static NSString *val(GRTile *t) { return t.choices[t.index][@"value"]; }
static NSInteger campaign_index(id v) { for (int i = 0; i < NCAMP; i++) if ([v isEqual:@(CAMPAIGNS[i].id)]) return i; return -1; }
/* the game's video mode for these choices: 4:3 (the game's picture; the window keeps it, bars at the sides), as tall as
 * the screen (below the notch's band if so) or the window, in points or (Retina) pixels; "" = as set in the game */
static NSString *mode_for(NSString *display, NSString *notch, NSString *res)
{
    if ([res isEqualToString:@"game"]) return @"";
    NSScreen *s = NSScreen.mainScreen; CGFloat h = s.frame.size.height;
    if ([display isEqualToString:@"window"]) h = floor(s.visibleFrame.size.height * 0.78) - 28;   /* main.m's window, less its title bar */
    else if (![notch isEqualToString:@"around"]) { if (@available(macOS 12.0, *)) h -= s.safeAreaInsets.top; }
    if ([res isEqualToString:@"retina"]) h *= s.backingScaleFactor;
    int ih = (int)floor(h) & ~1, iw = (int)lround(ih * 4.0 / 3) & ~1;
    if (ih < 480) { ih = 480; iw = 640; }
    return [NSString stringWithFormat:@"%dx%d", iw, ih];
}
/* the environment the game reads for these choices (GTA_MODE always set, "" for as set in the game) */
static NSDictionary *game_env(NSDictionary *c)
{
    NSString *display = c[@"display"] ?: @"fullscreen", *notch = c[@"notch"] ?: @"below";
    NSString *camp = campaign_index(c[@"campaign"]) >= 0 ? c[@"campaign"] : @"gr";
    return @{@"GR_CAMPAIGN": camp, @"DS_DISPLAY": display, @"DS_NOTCH": notch, @"DSR_VSYNC": c[@"vsync"] ?: @"1",
             @"GTA_MODE": mode_for(display, notch, c[@"resolution"] ?: @"standard")};
}
static NSAlert *alert(NSString *msg, NSString *info) { NSAlert *a = [NSAlert new]; a.messageText = msg; a.informativeText = info; return a; }

// ---------------------------------------------------------------- the launcher
@interface GRLauncher : NSObject <NSApplicationDelegate>
@property (strong) NSWindow *window; @property (strong) GRLaunchView *view; @property (strong) NSTimer *timer;
@property (strong) GRTile *display, *notch, *resolution, *vsync, *updates;
@property NSString *game, *data, *plistPath, *binPath, *exePath, *updater, *branch, *built;
@property BOOL embedded, ready;   /* embedded: inside the game (ds_launcher_run); ready: the game binary is there to run */
@property NSInteger result;
@end

@implementation GRLauncher
/* the folders and the program: from launch.plist in the app (install.sh), the game's own arguments when embedded */
- (void)locateGame:(const char *)gameDir data:(const char *)dataDir
{
    NSString *macos = NSBundle.mainBundle.executablePath.stringByDeletingLastPathComponent, *res = NSBundle.mainBundle.resourcePath ?: macos;
    NSDictionary *cfg = [NSDictionary dictionaryWithContentsOfFile:[res stringByAppendingPathComponent:@"launch.plist"]] ?: @{};
    NSString *data = dataDir ? @(dataDir) : cfg[@"data"] ?: [NSHomeDirectory() stringByAppendingPathComponent:@"Games/GhostReconNative"];
    if (dev_env("DATA_DIR")) data = @(dev_env("DATA_DIR"));
    NSString *game = gameDir ? @(gameDir) : cfg[@"game"] ?: [data stringByAppendingPathComponent:@"game-files/GhostRecon"];
    if (dev_env("GAME_DIR")) game = @(dev_env("GAME_DIR"));
    self.data = data; self.game = game; self.plistPath = [data stringByAppendingPathComponent:@"launcher.plist"];
    self.binPath = [macos stringByAppendingPathComponent:cfg[@"bin"] ?: @"GhostRecon"];
    self.exePath = [res stringByAppendingPathComponent:cfg[@"exe"] ?: @"GhostRecon.exe"];
    self.ready = self.embedded || ([NSFileManager.defaultManager isExecutableFileAtPath:self.binPath] && [NSFileManager.defaultManager fileExistsAtPath:self.exePath]);
    NSString *upd = getenv("DS_UPDATER") ? @(getenv("DS_UPDATER")) : [macos stringByAppendingPathComponent:@"update"];
    self.updater = [NSFileManager.defaultManager isExecutableFileAtPath:upd] ? upd : nil;
    NSDictionary *info = NSBundle.mainBundle.infoDictionary;
    self.branch = getenv("DS_UPDATE_BRANCH") ? @(getenv("DS_UPDATE_BRANCH")) : cfg[@"branch"] ?: info[@"GRBranch"] ?: @"main";
    gr_dropin = [self.branch isEqualToString:@"release"];   /* the downloaded app: no install.sh, the game lives in its own folder */
    self.built = getenv("DS_BUILT_COMMIT") ? @(getenv("DS_BUILT_COMMIT")) : cfg[@"built"] ?: info[@"GRBuilt"] ?: @"";
}
- (GRLaunchView *)makeView
{
    NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:self.plistPath] ?: @{};
    NSFileManager *fm = NSFileManager.defaultManager; NSString *res = NSBundle.mainBundle.resourcePath ?: @"";
    NSMutableArray<GRCampaign *> *camps = [NSMutableArray array];
    for (int i = 0; i < NCAMP; i++) {
        const CampaignDef *d = &CAMPAIGNS[i]; GRCampaign *c = [GRCampaign new]; c.def = d;
        NSString *mods = [self.game stringByAppendingPathComponent:[@"Mods" stringByAppendingPathComponent:@(d->mods)]];
        BOOL dir = NO;
        c.installed = [fm fileExistsAtPath:[self.game stringByAppendingPathComponent:@"GhostRecon.exe"]] && [fm fileExistsAtPath:mods isDirectory:&dir] && dir;
        NSArray *art = @[[res stringByAppendingPathComponent:[@"art" stringByAppendingPathComponent:@(d->id)]],
                         [self.data stringByAppendingPathComponent:[@"art" stringByAppendingPathComponent:@(d->id)]]];
        c.hero = image_at(art, @"hero.jpg"); c.card = image_at(art, @"shot1.jpg");
        /* the slides: the menu's own pictures (Ghost Recon), the intro's frames and the store's screenshots, in turn */
        NSMutableArray *own = [NSMutableArray array], *store = [NSMutableArray array];
        for (int k = 1; k <= 8; k++) { NSImage *im = ready(image_at(art, [NSString stringWithFormat:@"scene-%d.png", k]), 1400); if (im) [own addObject:im];
                                       im = ready(image_at(art, [NSString stringWithFormat:@"intro-%d.jpg", k]), 1400); if (im) [own addObject:im]; }
        for (int k = 2; k <= 8; k++) { NSImage *im = ready(image_at(art, [NSString stringWithFormat:@"shot-%d.jpg", k]), 1600); if (im) [store addObject:im]; }
        if (c.hero) [store insertObject:ready(c.hero, 1600) atIndex:0];
        NSMutableArray *sc = [NSMutableArray array];
        for (NSUInteger k = 0; k < MAX(own.count, store.count); k++) { if (k < store.count) [sc addObject:store[k]]; if (k < own.count) [sc addObject:own[k]]; }
        c.scenes = sc;
        NSImage *por = image_at(art, @"cover.jpg") ?: c.hero ?: image_at(art, @"portrait.png") ?: image_at(art, @"intro-3.jpg") ?: image_at(art, @"intro-2.jpg");   /* the box art (GOG), else the field */
        c.portrait = ready(por, 1000);
        c.coverZ = 1.0; c.coverFx = d->heroX; c.coverFy = d->heroY;
        NSImage *key = i == 0 ? image_at(art, @"keyart.png") : nil;
        if (key && key.size.width > 1000) {                              /* GOG's key art: the Ghost in goggles, left of its logo */
            NSSize ks = key.size; CGFloat aspect = 594.0 / 800, vis1 = ks.height * aspect, want = ks.width * 0.28;   /* (448 of its 1600) */
            c.portrait = ready(key, 1600); c.coverZ = MAX(1, vis1 / want); c.coverFx = 0;
            CGFloat visH = ks.height / c.coverZ; c.coverFy = visH < ks.height ? MIN(1, ks.height * 0.027 / (ks.height - visH)) : 0.5;
        }
        [camps addObject:c];
    }
    GRLaunchView *v = [[GRLaunchView alloc] initWithFrame:NSMakeRect(0, 0, W, H)]; self.view = v;
    NSArray *grArt = @[[res stringByAppendingPathComponent:@"art/gr"], [self.data stringByAppendingPathComponent:@"art/gr"]];
    v.logo = image_at(grArt, @"logo-hd.png") ?: image_at(grArt, @"logo.png");   /* the game's own title: GOG's key art's, else the menu's */
    v.hover = v.pressed = HIT_NONE; v.focus = -1; v.campaigns = camps;
    NSInteger s = campaign_index(saved[@"campaign"]); v.campaign = s >= 0 && camps[s].installed ? s : 0;
    v.hint = @"←/→ choose a campaign · ↑/↓ settings · Return plays · Esc quits";

    NSScreen *scr = NSScreen.mainScreen;
    CGFloat notchH = 0; if (@available(macOS 12.0, *)) notchH = scr.safeAreaInsets.top;
    GRTile *display = self.display = [GRTile new], *notch = self.notch = [GRTile new], *resTile = self.resolution = [GRTile new], *vsync = self.vsync = [GRTile new];
    display.title = @"Display";
    display.choices = @[@{@"value": @"fullscreen", @"label": @"Full Screen", @"note": @"The whole display, the Dock and menu bar out of the way: Game Mode on"},
                        @{@"value": @"window", @"label": @"Window", @"note": @"A window on the desktop (4:3, resizable); ⌘-Tab and the Dock as usual"}];
    display.index = index_of(display.choices, saved[@"display"], 0);
    notch.title = @"Notch";
    notch.choices = @[@{@"value": @"below", @"label": @"Below It", @"note": @"The picture under the camera housing, the band above it black"},
                      @{@"value": @"around", @"label": @"Around It", @"note": @"The whole display's height: the notch over the top of the picture"}];
    notch.index = notchH > 0 ? index_of(notch.choices, saved[@"notch"], 0) : 0;
    resTile.title = @"Resolution";
    resTile.choices = @[@{@"value": @"standard", @"label": @"Standard", @"note": [NSString stringWithFormat:@"Display height in points (%@), scaled up by macOS", mode_for(@"fullscreen", @"around", @"standard")]},
                        @{@"value": @"retina", @"label": @"Retina", @"note": [NSString stringWithFormat:@"Every pixel (%@ full screen): the sharpest picture", mode_for(@"fullscreen", @"around", @"retina")]},
                        @{@"value": @"game", @"label": @"As Set in Game", @"note": @"The game's own Options menu decides (640 × 480 at first)"}];
    if (scr.backingScaleFactor <= 1) resTile.choices = @[resTile.choices[0], resTile.choices[2]];
    resTile.index = index_of(resTile.choices, saved[@"resolution"], 0);
    NSInteger hz = scr.maximumFramesPerSecond; if (hz <= 0) hz = 60;
    vsync.title = @"VSync";
    vsync.choices = @[@{@"value": @"1", @"label": @"On", @"short": @"VSync", @"note": [NSString stringWithFormat:@"Frames paced to the display's %ld Hz: no tearing", (long)hz]},
                      @{@"value": @"0", @"label": @"Off", @"short": @"No VSync", @"note": @"Frames shown as soon as they're drawn: lowest latency, may tear"}];
    vsync.index = index_of(vsync.choices, saved[@"vsync"], 0);
    v.rows = notchH > 0 ? @[display, notch, resTile, vsync] : @[display, resTile, vsync];

    GRTile *gfx = [GRTile new]; gfx.title = @"Graphics Options"; gfx.wide = YES;
    gfx.choices = @[@{@"value": @"", @"label": @"", @"note": notchH > 0 ? @"Display, notch, resolution and VSync, for every campaign" : @"Display, resolution and VSync, for every campaign"}];
    gfx.summary = ^NSString * {
        NSMutableArray *a = [NSMutableArray array];
        for (GRTile *t in @[display, resTile, vsync]) [a addObject:t.choices[t.index][@"short"] ?: t.choices[t.index][@"label"]];
        return [a componentsJoinedByString:@"  ·  "];
    };
    __weak GRLaunchView *wv = v; gfx.activate = ^{ [wv openPanel]; };
    /* the game's writes go to the data folder's copy of the game folder (<data>/game, main.m): each campaign's saves
     * in its mod's folder there (Mods/Origmiss, Mp1, Mp2: save/game campaigns and checkpoints, save/replay) */
    NSString *game = self.game, *dataDir = self.data;
    __weak GRLaunchView *wsv = v;
    NSString *(^saveDir)(void) = ^NSString * {
        static NSString *const mods[NCAMP] = {@"mods/origmiss/save", @"mods/mp1/save", @"mods/mp2/save"};
        NSInteger k = wsv ? MAX(0, MIN(NCAMP - 1, wsv.campaign)) : 0;
        return [[dataDir stringByAppendingPathComponent:@"game"] stringByAppendingPathComponent:mods[k]];
    };
    BOOL haveGame = [fm fileExistsAtPath:[game stringByAppendingPathComponent:@"GhostRecon.exe"]];
    GRTile *saves = [GRTile new]; saves.title = @"Saves";
    saves.current = ^NSDictionary * {
        if (!haveGame) return @{@"label": @"—", @"off": @YES, @"note": gr_dropin ? @"Ghost Recon's files are missing" : @"Ghost Recon's files are missing: run ./install.sh again"};
        return @{@"label": @"Open", @"note": [@"Saved games: " stringByAppendingString:saveDir().stringByAbbreviatingWithTildeInPath]};
    };
    saves.activate = ^{
        if (!haveGame) { NSBeep(); return; }
        NSString *d = saveDir();
        [[NSFileManager defaultManager] createDirectoryAtPath:d withIntermediateDirectories:YES attributes:nil error:nil];
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:d isDirectory:YES]];
    };
    GRTile *files = [GRTile new]; files.title = @"Game Files";
    files.current = ^NSDictionary * {
        if (!haveGame) return @{@"label": @"—", @"off": @YES, @"note": gr_dropin ? @"Ghost Recon's files are missing" : @"Ghost Recon's files are missing: run ./install.sh again"};
        return @{@"label": @"Open", @"note": [@"The game's own folder (Data, Mods, Docs): " stringByAppendingString:game.stringByAbbreviatingWithTildeInPath]};
    };
    files.activate = ^{
        if (!haveGame) { NSBeep(); return; }
        [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:game isDirectory:YES]];
    };
    [self setupUpdates];
    v.tiles = @[gfx, saves, files, self.updates];
    __weak GRLauncher *ws = self;
    v.onChange = ^{ [ws save]; };
    if (dev_env("CAMPAIGN")) v.campaign = MAX(0, MIN(NCAMP - 1, atoi(dev_env("CAMPAIGN"))));   /* development */
    return v;
}
/* development: the window as an image */
- (BOOL)shot
{
    const char *shot = dev_env("SHOT"); if (!shot) return NO;
    GRLaunchView *v = self.view;
    if (dev_env("HOVER")) v.hover = atoi(dev_env("HOVER"));
    if (dev_env("FOCUS")) v.focus = atoi(dev_env("FOCUS"));
    if (dev_env("OPEN")) v.open = YES;
    v.t = dev_env("TIME") ? atof(dev_env("TIME")) : 4.0; v.switchT = -10; v.prevCampaign = v.campaign;   /* (the animation's clock, seconds) */
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:(NSInteger)v.bounds.size.width * 2 pixelsHigh:(NSInteger)v.bounds.size.height * 2
                                                                bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = v.bounds.size;
    [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    if (dev_env("TIMING")) {                                             /* what a frame costs, once warm */
        double t0 = CACurrentMediaTime();
        for (int k = 0; k < 60; k++) { v.t += 1.0 / 60; [v displayRectIgnoringOpacity:v.bounds inContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]]; }
        fprintf(stderr, "frame: %.1f ms\n", (CACurrentMediaTime() - t0) * 1000 / 60);
    }
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:@(shot) atomically:YES];
    return YES;
}
- (NSWindow *)makeWindow
{
    NSWindow *w = [[NSWindow alloc] initWithContentRect:self.view.frame styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                                                backing:NSBackingStoreBuffered defer:NO];
    w.releasedWhenClosed = NO; w.titlebarAppearsTransparent = YES; w.titleVisibility = NSWindowTitleHidden; w.movableByWindowBackground = YES;
    w.title = @"Ghost Recon"; w.backgroundColor = ink(); w.contentView = self.view;
    self.window = w; [w center]; [w makeFirstResponder:self.view];
    /* the animation, 60 times a second (in a modal loop's mode too); a controller: the d-pad or the left stick (left and
     * right the campaigns, up and down the settings; held: repeats), A chooses, B goes back or quits, Start plays */
    GRLaunchView *v = self.view; v.switchT = -10; v.prevCampaign = v.campaign;
    double t0 = CACurrentMediaTime(); __block int held = 0; __block double next = 0; __block uint32_t was = 0; __weak GRLaunchView *wv = v;
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    void (^key)(unsigned short) = ^(unsigned short code) {
        NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:wv.window.windowNumber context:nil
                                    characters:@"" charactersIgnoringModifiers:@"" isARepeat:NO keyCode:code];
        [wv keyDown:e];
    };
    self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 repeats:YES block:^(NSTimer *tm) {
        GRLaunchView *sv = wv; if (!sv) return;
        double t = sv.t = CACurrentMediaTime() - t0;
        GCExtendedGamepad *g = (GCController.current ?: GCController.controllers.firstObject).extendedGamepad;
        if (g && NSApp.active && sv.window.isKeyWindow) {
            float x = g.leftThumbstick.xAxis.value, y = g.leftThumbstick.yAxis.value;
            int dir = g.dpad.left.pressed || x < -0.6f ? 0x7b : g.dpad.right.pressed || x > 0.6f ? 0x7c : g.dpad.up.pressed || y > 0.6f ? 0x7e : g.dpad.down.pressed || y < -0.6f ? 0x7d : 0;
            if (dir != held) { held = dir; next = t + 0.38; if (dir) key((unsigned short)dir); }
            else if (dir && t >= next) { next = t + 0.14; key((unsigned short)dir); }
            uint32_t now = (g.buttonA.pressed ? 1u : 0) | (g.buttonB.pressed ? 2u : 0) | (g.buttonMenu.pressed ? 4u : 0), down = now & ~was; was = now;
            if (down & 1) key(0x24); else if (down & 2) key(0x35); else if ((down & 4) && sv.onPlay) sv.onPlay();
        } else { held = 0; was = 0; }
        sv.needsDisplay = YES;
        static double lastT; if (dev_env("TIMING") && t - lastT >= 1) { fprintf(stderr, "fps: %.0f\n", frames_drawn / (t - lastT)); frames_drawn = 0; lastT = t; }
    }];
    [[NSRunLoop currentRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    return w;
}
- (void)applicationDidFinishLaunching:(NSNotification *)n
{
    [self locateGame:NULL data:NULL];
    GRLaunchView *v = [self makeView];
    __weak GRLauncher *ws = self;
    v.onPlay = ^{ [ws play]; };
    v.onQuit = ^{ [NSApp terminate:nil]; };
    if ([self shot]) exit(0);
    NSMenu *bar = [NSMenu new], *appm = [NSMenu new]; NSMenuItem *it = [NSMenuItem new]; it.submenu = appm; [bar addItem:it];
    [appm addItemWithTitle:@"Quit Ghost Recon" action:@selector(terminate:) keyEquivalent:@"q"]; NSApp.mainMenu = bar;
    [[self makeWindow] makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    if (dev_env("PLAY")) dispatch_async(dispatch_get_main_queue(), ^{ [ws play]; });   /* development: Play at once */
}
- (void)setupUpdates
{
    NSString *updater = self.updater, *branch = self.branch, *built = self.built;
    GRTile *u = [GRTile new]; u.title = @"Updates"; self.updates = u;
    __block int state = updater ? UPD_CHECKING : UPD_NONE; __block NSString *latest = nil;
    u.choices = update_choice(state, branch, built, nil);
    __weak GRTile *wu = u; __weak GRLauncher *ws = self;
    void (^check)(void) = ^{
        if (!updater) return;
        state = UPD_CHECKING; wu.choices = update_choice(state, branch, built, nil); ws.view.needsDisplay = YES;
        void (^done)(NSString *) = ^(NSString *l) {
            latest = l; state = !l ? UPD_ERROR : [l isEqualToString:built] ? UPD_CURRENT : UPD_AVAILABLE;
            wu.choices = update_choice(state, branch, built, l); ws.view.needsDisplay = YES;
        };
        if (dev_env("SHOT")) { done(update_check(updater)); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ NSString *l = update_check(updater); on_main(^{ done(l); }); });
    };
    check();
    u.activate = ^{
        if (state == UPD_CHECKING || state == UPD_NONE) return;
        if (state != UPD_AVAILABLE) { check(); return; }
        NSAlert *a = alert([NSString stringWithFormat:@"Update to the newest %@?", [branch isEqualToString:@"nightly"] ? @"Nightly" : @"version"],
                           [branch isEqualToString:@"release"]   /* the downloaded app (setup/update.sh) */
                           ? [NSString stringWithFormat:@"%@ is downloaded from GitHub and replaces this app. Your game, saves and settings are kept; "
                              "if the game's code changed, it is rebuilt from your copy when the app starts again.", latest]
                           : [NSString stringWithFormat:@"The %@ branch (%@) is downloaded from GitHub and Ghost Recon is rebuilt from your own copy, "
                            "which takes around fifteen minutes. Your saves and settings are kept. The app restarts when it is done.", branch, short_commit(latest)]);
        [a addButtonWithTitle:@"Update"]; [a addButtonWithTitle:@"Cancel"];
        if ([a runModal] != NSAlertFirstButtonReturn) return;
        [[NSFileManager defaultManager] createDirectoryAtPath:ws.data withIntermediateDirectories:YES attributes:nil error:nil];
        if (update_run(ws.window, updater, branch, [ws.data stringByAppendingPathComponent:@"update.log"])) {
            /* the rebuilt app is at the same path: the app's bundle, or the one around the updater */
            NSString *app = [[[updater stringByDeletingLastPathComponent] stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
            NSTask *o = [NSTask new]; o.executableURL = [NSURL fileURLWithPath:@"/usr/bin/open"]; o.arguments = @[@"-n", app];
            [o launchAndReturnError:nil]; [o waitUntilExit];
            exit(0);
        }
        check();
    };
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)a { return YES; }
- (NSDictionary *)choices
{
    return @{@"campaign": @(CAMPAIGNS[self.view.campaign].id), @"display": val(self.display), @"notch": val(self.notch),
             @"resolution": val(self.resolution), @"vsync": val(self.vsync)};
}
- (void)save
{
    [[NSFileManager defaultManager] createDirectoryAtPath:self.data withIntermediateDirectories:YES attributes:nil error:nil];
    [self.choices writeToFile:self.plistPath atomically:YES];
}
- (BOOL)canPlay   /* YES, or an alert said why not */
{
    GRCampaign *c = self.view.chosen;
    if (!c.installed) {
        BOOL dropin = gr_dropin;
        if (self.view.campaign == 0) [alert(@"Ghost Recon's files are missing", [NSString stringWithFormat:@"Expected GhostRecon.exe and Mods/Origmiss in %@.%@", self.game,
                                            dropin ? @"" : @" Run ./install.sh again."]) runModal];
        else if (dropin) [alert([NSString stringWithFormat:@"%s isn't installed", c.def->title],
                    [NSString stringWithFormat:@"Download it in Steam's console (steam://open/console):\n\ndownload_depot %s\n\nthen copy the Mods/%s folder from that download "
                     "(or from a PC's Ghost Recon folder) into:\n\n%@/Mods", c.def->depot, c.def->mods, self.game]) runModal];
        else [alert([NSString stringWithFormat:@"%s isn't installed", c.def->title],
                    [NSString stringWithFormat:@"Download it in Steam's console (steam://open/console):\n\ndownload_depot %s\n\nthen run the project's ./install.sh again: "
                     "it adds the expansion's Mods/%s to the game folder.", c.def->depot, c.def->mods]) runModal];
        return NO;
    }
    if (!self.ready) {
        [alert(@"The game isn't built", [NSString stringWithFormat:@"No %@ beside this launcher. Run the project's ./install.sh.", self.binPath.lastPathComponent]) runModal];
        return NO;
    }
    return YES;
}
- (void)play
{
    [self save];
    if (![self canPlay]) return;
    if (self.embedded) { self.result = 1; [NSApp stopModal]; return; }   /* ds_launcher_run returns 1 */
    NSMutableDictionary *env = [game_env(self.choices) mutableCopy];
    NSString *log = [self.data stringByAppendingPathComponent:@"GhostRecon.log"];
    [env addEntriesFromDictionary:@{@"DS_NO_LAUNCHER": @"1", @"DS_LOG_FILE": log}];
    NSArray<NSString *> *args = @[self.binPath, @"--exe", self.exePath, @"--game", self.game, @"--data", self.data];
    if (dev_env("DRY")) {                                                /* development: what Play runs */
        for (NSString *k in [env.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("%s=%s\n", k.UTF8String, [env[k] UTF8String]);
        for (NSString *a in args) printf("'%s' ", a.UTF8String);
        printf("2>>'%s'\n", log.UTF8String); fflush(stdout); exit(0);
    }
    /* The game runs in a fresh instance of the app that never shows a window: it execs the game at once (main below).
     * A full-screen game window from the process that showed this window can stay black and off the front (as in the
     * Diablo II port), and opened through LaunchServices the instance is still this app, so Game Mode turns on. */
    NSMutableDictionary *all = [NSProcessInfo.processInfo.environment mutableCopy];
    [all addEntriesFromDictionary:env];
    [all addEntriesFromDictionary:@{@"GR_PLAY_BIN": self.binPath, @"GR_PLAY_EXE": self.exePath, @"GR_PLAY_GAME": self.game, @"GR_PLAY_DATA": self.data}];
    [all removeObjectForKey:@"GR_LAUNCHER_PLAY"];
    NSWorkspaceOpenConfiguration *cfg = [NSWorkspaceOpenConfiguration configuration];
    cfg.createsNewApplicationInstance = YES; cfg.environment = all; cfg.activates = YES;
    [self.window orderOut:nil];
    [[NSWorkspace sharedWorkspace] openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:cfg completionHandler:^(NSRunningApplication *app, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (app) { [NSApp terminate:nil]; return; }
            [self.window makeKeyAndOrderFront:nil];
            [alert(@"The game did not start", err.localizedDescription ?: @"") runModal];
        });
    }];
}
@end

#ifdef GR_LAUNCHER_APP
/* the game's instance (see play): straight into the game, its stderr in the game's log (the previous one kept as .old
 * past 5 MB) */
static void exec_game(void)
{
    const char *names[4] = {"GR_PLAY_BIN", "GR_PLAY_EXE", "GR_PLAY_GAME", "GR_PLAY_DATA"}; char *keep[4];
    for (int k = 0; k < 4; k++) { const char *v = getenv(names[k]); if (!v) return; keep[k] = strdup(v); }
    for (int k = 0; k < 4; k++) unsetenv(names[k]);
    const char *argv[] = {keep[0], "--exe", keep[1], "--game", keep[2], "--data", keep[3], 0};
    mkdir(keep[3], 0755);
    const char *log = getenv("DS_LOG_FILE");
    if (log) {
        struct stat st;
        if (!stat(log, &st) && st.st_size > 5000000) { char old[2048]; snprintf(old, sizeof old, "%.*s.old.log", (int)(strlen(log) - 4), log); rename(log, old); }
        int fd = open(log, O_WRONLY | O_APPEND | O_CREAT, 0644); if (fd >= 0) { dup2(fd, 2); close(fd); }
    }
    execv(argv[0], (char *const *)argv);
    fprintf(stderr, "Ghost Recon: %s did not start: %s\n", argv[0], strerror(errno));
}

int main(int argc, const char **argv)
{
    (void)argc; (void)argv;
    if (getenv("GR_PLAY_BIN")) { exec_game(); return 1; }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyRegular;
        GRLauncher *l = [GRLauncher new]; app.delegate = l;
        [app run];
    }
    return 0;
}
#else
static void setenv_soft(NSString *k, NSString *v) { if (!getenv(k.UTF8String)) setenv(k.UTF8String, v.UTF8String, 1); }   /* a terminal's own setting wins */

/* inside the game (main.m): 1 to play (the choices in the environment), 0 to quit */
int ds_launcher_run(const char *game_dir, const char *data_dir)
{
    @autoreleasepool {
        GRLauncher *l = [GRLauncher new]; l.embedded = YES;
        [l locateGame:game_dir data:data_dir];
        if (getenv("DS_NO_LAUNCHER") && !dev_env("SHOT")) {          /* the app's Play (or a terminal): the saved choices */
            NSDictionary *saved = [NSDictionary dictionaryWithContentsOfFile:l.plistPath] ?: @{};
            [game_env(saved) enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) { (void)stop; if (v.length) setenv_soft(k, v); }];
            return 1;
        }
        GRLaunchView *v = [l makeView];
        if ([l shot]) return 0;
        __weak GRLauncher *wl = l;
        v.onPlay = ^{ [wl play]; };
        v.onQuit = ^{ wl.result = 0; [NSApp stopModal]; };
        NSWindow *w = [l makeWindow];
        id obs = [[NSNotificationCenter defaultCenter] addObserverForName:NSWindowWillCloseNotification object:w queue:nil usingBlock:^(NSNotification *n) { (void)n; [NSApp stopModal]; }];
        [NSApp activateIgnoringOtherApps:YES];
        [w makeKeyAndOrderFront:nil];
        [NSApp runModalForWindow:w];
        [l.timer invalidate];
        [[NSNotificationCenter defaultCenter] removeObserver:obs];
        [w orderOut:nil];
        if (!l.result) return 0;
        [l save];
        [game_env(l.choices) enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *val, BOOL *stop) { (void)stop; if (val.length) setenv(k.UTF8String, val.UTF8String, 1); }];
        return 1;
    }
}
#endif
