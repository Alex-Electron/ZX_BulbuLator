---
note: DN/Turbo-Vision UI engine blueprint (swarm wf_7ecb19fd, 2026-07-06). Implementation guide for the OSD DN rendering engine on our ARGB palette.
---

# BULBULATOR OSD ENGINE — DN / Turbo-Vision blueprint (implement-ready)

This merges all six studies into one engine that keeps **our** ARGB palette and grafts onto the existing `dn_*` primitives, `menu_t/menu_item` settings model, and the `render_browser_dn` backdrop in `/Users/alex/Yandex.Disk.localized/DIY/EBAZ4205/BulbuLator/research/14-color-osd/arm/loader_main.c`.

Naming: **studies** are cited as `[study §x]`; DN/TV sources they resolved are cited as `[file:line]`. Every glyph is **decimal CP866** (safe in `vga866.h`). No DOS colour indices leave this document — only our `DNK_*`.

> **Six review corrections folded in (search the doc for these):** (1) dialog button-row moved to **H-3** (was H-4) — real pixel fix; (2) the cyan `►◄` button pointers reframed as an **owner enhancement, not DN-authentic**; (3) the green button face flagged as a **new hue pending owner sign-off**, no longer presented as sourced from DN; (4) `dlg_exec` now wraps the modal loop in the TV **`valid()` re-entry**; (5) scrollbar thumb formula tightened to the exact `tscrlbar.cpp:95` term placement; (6) menu-bar title stride set to **+2** for exact DN fidelity. Plus three citation-anchor corrections (frame active/passive selection, input select-all-on-focus, dropdown-anchor reconciliation).

---

## PART 0 — Orientation: layering, colour tokens, input

### 0.1 What exists vs. what this adds

| Layer | Today (`loader_main.c`) | After |
|---|---|---|
| Cell primitives | `dn_putc/puts/putsn/fill/box/hpx/vpx/bar/dim_cell/shadow` (l.359-391) | **unchanged**, moved to `dnui.c`, exported by `dnui.h` |
| Button | `dn_button` = `[bracket]` style (l.394-405) | **replaced** by filled `Button` widget [button §] |
| Settings model | `menu_item[]/menu_t` + `menu_render/move/activate` (l.1759-1837) | **kept** as the *data source*; feeds a config **Dialog** and inline value-items |
| Top bar | static titles drawn in `render_browser_dn` (l.892-895) | **MenuBar** with 5 dropdowns + LEFT/RIGHT nav [dropdown §] |
| Browser | `render_browser_dn` procedural (l.889-906) | reframed as **Window(Frame)+ListView** backdrop [frame §][inputs §5] |
| Dialogs | none (Rename is TODO) | **Dialog** subsystem + modal loop [modal §] |
| State | `osd_on/opt_on/browser_on/osd_view` + `toggle_view` (l.523-529,1918-1921) | browser stays the base view; MenuBar/Dialogs are transient modals over it |

### 0.2 The five emphasis tokens → our palette (this is the whole "DN structure, our colours" bridge)

`[model-shadow-color §4.4]` reduces every DN state to five emphasis primitives. We already have exact ARGB for all of them; map once, reuse everywhere. Existing constants at l.333-356:

```c
/* dnui.h — emphasis tokens (aliases onto the EXISTING DNK_* palette; retheme here only) */
#define EM_NORMAL_FG   DNK_FILE      /* FG(7)  light-gray body text          */
#define EM_BRIGHT_FG   DNK_DIR       /* FG(15) white (active frame, dirs)     */
#define EM_DIM_FG      FG(8)         /* dark-gray: disabled / passive / shadow (NEW alias) */
#define EM_INV_FG      DNK_CUR_FG    /* FG(0)  black text on the selection bar */
#define EM_INV_BG      DNK_CUR_BG    /* BG(3)  cyan selection bar             */
/* three role-specific accents (owner-anchored) */
#define EM_HOTKEY      DNK_HOTKEY    /* FG(4)  red   — hotkey letters / F-nums */
#define EM_HEADER      DNK_HEADER    /* FG(14) yellow— column heads, values    */
#define EM_POINTER     DNK_STATUS    /* FG(11) cyan  — ►◄ pointers, scroll, thumb, tag */
/* chrome / panels / dialog (existing) */
#define EM_PANEL_BG    DNK_PANEL_BG  /* BG(8)  dkgray panel   */
#define EM_CHROME_BG   DNK_MENU_BG   /* BG(7)  ltgray bar/menu */
#define EM_CHROME_FG   DNK_MENU_FG   /* FG(0)  black chrome text */
#define EM_DLG_BG      DNK_DLG_BG    /* BG(7)  ltgray dialog  */
#define EM_DLG_FG      DNK_DLG_FG    /* FG(0)               */
#define EM_FRAME       DNK_FRAME     /* FG(15) white frame   */

/* filled-button face — a NEW hue OUTSIDE the owner's 5-colour palette (dkgray/white/cyan/
   yellow/red). ⚠ OPEN ITEM — PENDING OWNER SIGN-OFF. It is NOT sourced from DN: TV's gray
   dialog draws buttons from cpGrayDialog (tdialog.cpp:31), whose face is not a saturated
   green. Themable — if the owner rejects a 6th hue, alias EM_BTN_FACE onto an existing token
   (e.g. a brightened EM_CHROME_BG) with zero other changes. */
#define EM_BTN_FACE    FG(2)         /* raised face (green PLACEHOLDER — see sign-off note) */
#define EM_BTN_LBL_N   DNK_DLG_FG    /* black label, normal   */
#define EM_BTN_LBL_H   FG(15)        /* white label, focused/default         */
#define EM_BTN_HOT     EM_HOTKEY     /* red hotkey letter (global rule; swap to EM_HEADER for punch) */
#define EM_BTN_PTR     EM_POINTER    /* cyan ►◄ on default/focused (OWNER ENHANCEMENT — see 2.2) */
```

Rule everywhere `[model-shadow-color §4.2; drivers.cpp:170-283]`: text is drawn body-colour, and the char between `~…~` is drawn in the accent (hotkey) colour; the `~` are stripped, never rendered.

### 0.3 Frames are **pixel-lines**, not glyphs (keep the existing choice)

`dn_box` (l.375-381) draws frames as cell-aligned pixel lines with a 3px gap for `dbl` — the owner already tuned this because Terminus `═/║` read as one thin line at 8×16. So: **every framed view uses `dn_box(x,y,w,h,fg,bg,dbl)` with `dbl = active`** `[frame §1; the active/passive selection lives in TFrame.Draw — tframe.cpp:47-57: f=9 active / f=0 passive]`. The `┌─┐/║═╔` glyph tables in `[frame §1]` (constant arrays at `VIEWS.PAS:1953-57`) and `[dropdown §3]` are only needed for the `┬┴` join case (framed twin panels) — we have a single panel, so skip them. Menu-box separators use a thin `dn_hpx` line (see Part 3).

### 0.4 Single input primitive: `ui_getkey()` + `bg_pump()`

All modal loops block on one key source that keeps the tape FIFO fed. `bg_pump()` = exactly the non-key work the main loop does today (service tape, poll SD-insert at l.2311, banner). `ui_getkey()` reads the existing PS/2 scancode FIFO, folds `E0/F0` prefixes, tracks `g_kb_shift/alt/ctrl`, and returns **keydown keysyms** only:

```c
/* loader provides these (they touch tape/SD hardware) */
void bg_pump(void);        /* one iteration of tape/SD/banner servicing (NON-blocking) */
int  ui_getkey(void);      /* blocks: while(no keydown) bg_pump(); returns a keysym below */
```

Keysym set (printable ASCII passes through as itself so input-lines & hotkeys use ASCII directly):

```c
enum { K_NONE=0, K_BACK=8, K_TAB=9, K_ENTER=13, K_ESC=27,      /* + ASCII 32..126 */
       K_UP=0x100,K_DOWN,K_LEFT,K_RIGHT,K_HOME,K_END,K_PGUP,K_PGDN,K_INS,K_DEL,K_STAB,
       K_F1,K_F2,K_F3,K_F4,K_F5,K_F6,K_F7,K_F8,K_F9,K_F10,K_F11,K_F12 };
extern int g_kb_shift,g_kb_alt,g_kb_ctrl;
```

Scancode→keysym uses the existing `SC_*` (l.119-127…): `SC_UP→K_UP`, `SC_ENTER→K_ENTER`, `SC_ESC→K_ESC`, `SC_F9→K_F9`, Tab = PS/2 set-2 `0x0D`→K_TAB (`K_STAB` if `g_kb_shift`), etc. A `sc_to_ascii(code,shift)` table (partly present) supplies printable ASCII for input lines. `K_STAB` from Tab+shift `[modal §6 kbShiftTab=0x0F00]`.

---

## PART 1 — CORE MODEL (Turbo-Vision-like, bare-metal, no malloc)

Every widget **embeds `View` as its first member** (classic C inheritance); a `View*` casts to the concrete type. Concrete dialogs embed their widgets, so a whole dialog is one stack/static allocation. Constants are the TV numerics from `[modal §6; model-shadow-color §3]`.

```c
/* ---------- dnui.h : core ---------- */
typedef struct { short x,y,w,h; } Rect;                 /* cells */

enum { /* sf* state bits [model-shadow-color §3; views.h:63-74] */
  sfVisible=0x001, sfCursorVis=0x002, sfShadow=0x008, sfActive=0x010,
  sfSelected=0x020, sfFocused=0x040, sfDisabled=0x100, sfModal=0x200, sfDefault=0x400 };
enum { /* of* option bits */
  ofSelectable=0x001, ofFramed=0x008, ofPreProcess=0x010, ofPostProcess=0x020 };
enum { /* cm* commands [modal §6; views.h:31-59] */
  cmValid=0, cmMenu=3, cmClose=4, cmOK=10, cmCancel=11, cmYes=12, cmNo=13, cmDefault=14,
  cmBase=100 /* app commands live at >=100 (Part 3.2) */ };
enum { bfNormal=0, bfDefault=1, bfLeftJust=2 };          /* button flags [button §7] */

typedef struct View  View;
typedef struct Group Group;
struct View {
  Rect     bounds;                 /* owner-relative (build-by-data) */
  Rect     abs;                    /* absolute cells (filled by layout_abs) */
  uint16_t state, opts;
  Group*   owner;
  void   (*draw)(View*);           /* paints into g_osdc via dn_* using .abs */
  void   (*handle)(View*,int key); /* consumes a keysym; may set owner->endState */
};
#define DLG_MAXCH 24
struct Group {                     /* a View that owns children + a modal loop */
  View  v;                         /* Group IS-A View (its draw = group_draw) */
  View* ch[DLG_MAXCH]; int nch;    /* children in TAB order (array, not TV's ring)
                                      [modal §4 note: store visual order so Tab=forward] */
  int   cur;                       /* focused child index, -1 = none */
  int   endState;                  /* !=0 => modal loop exits with this cmd */
  uint32_t body;                   /* interior fill colour (the frame's inner spaces) */
};

/* layout: turn owner-relative bounds into absolute cells for the whole tree */
static void layout_abs(View* v){
  Rect o = v->owner ? v->owner->v.abs : (Rect){0,0,DN_COLS,DN_ROWS};
  v->abs = (Rect){ o.x+v->bounds.x, o.y+v->bounds.y, v->bounds.w, v->bounds.h };
}
/* group plumbing */
void group_insert(Group* g, View* c);      /* c->owner=g; g->ch[g->nch++]=c; layout_abs(c) */
void group_draw  (Group* g);               /* body fill -> each child->draw() (Part 4.2) */
void group_focus_next(Group* g, int dir);  /* Tab: skip !ofSelectable/sfDisabled, wrap, repaint 2 */
static inline void group_end(Group* g,int cmd){ if(g->v.state&sfModal) g->endState=cmd; } /* [tgroup.cpp:159] */
```

Draw model `[model-shadow-color §2.3]`: back-to-front painter (no clip engine). A Group paints its body then each child in array order; children don't overlap in a dialog so order is free. Occlusion between *windows* is handled by drawing whole windows bottom→top (browser first, then any floating window/menu/dialog last). Incremental repaint (focus/value change) redraws **only the changed child** — never a full clear — matching the anti-flicker rule (memory: DN мерцание fix).

---

## PART 2 — WIDGET FUNCTION SET (signatures + exact draw + citations)

All draw at `self->abs` and reuse `dn_*`. Colour picked per-state from Part 0.2. Where a study gives the full glyph table, I inline the load-bearing codes and cite the rest.

### 2.1 Window Frame — `frame_draw` `[frame §2-4]`

```c
typedef struct { View v; const char* title; int number; uint8_t wf; } Frame;
/* wf bits: wfClose=1 wfZoom=2 wfGrow=4 (default wfClose|wfZoom|wfGrow) [frame §8] */
void frame_init(Frame* f, Rect r, const char* title, uint8_t wf);
void frame_draw(View* self);
```
Draws, in order `[frame §9]`:
1. `dn_fill(x+1,y+1,w-2,h-2, body)` — interior spaces (the window bg) `[frame §6: frame's middle-line spaces ARE the interior fill]`.
2. `dn_box(x,y,w,h, active?EM_FRAME:EM_DIM_FG, body, /*dbl=*/active)` — **double when `sfActive`, single otherwise**; the active/passive *selection* is in `TFrame.Draw` `[frame §1; tframe.cpp:47-57 (f=9 active / f=0 passive); glyph tables at VIEWS.PAS:1953-57]`.
3. **Title**, centred on row 0, one pad space each side `[frame §2; tframe.cpp:81-93]`: `L=clamp(strlen,0,w-10); I=(w-L)/2;` draw ` title ` at `x+I-1`. Colour = `active?EM_BRIGHT_FG:EM_DIM_FG`; if the title carries `~x~`, that letter in `EM_HEADER`.
4. If `active`: window **number** `'0'+n` at col `w-7` (if `wfZoom`) else `w-3` (only when `n∈1..9`); **close box** cols 2-4 `[`(91)`■`(254)`]`(93); **zoom box** cols `w-5..w-3` `[`(91)`↑`(24)`]`(93) (or `↕`18 if maximised); **resize grip** cols `w-2,w-1` `─`(196)`┘`(217). Brackets in frame colour; **center glyphs `■ ↑ ↕` and the grip in `EM_POINTER`** `[frame §4]`. (Our windows are non-draggable/fixed, so `wf` can be 0 → title only; keep the API for the future player window.)

Passive/inactive → single line, dim title, **no icons** `[frame §4]`. This is our browser's active window and every dialog's frame.

### 2.2 Filled Button — `button_draw/handle` `[button §; tbutton.cpp:102-164]`  ← replaces `dn_button`

```c
typedef struct { View v; const char* title; uint16_t cmd; uint8_t bf; } Button;
void button_init(Button* b, Rect r, const char* title, uint16_t cmd, uint8_t bf);
void button_draw(View* self);            /* r.h==2 standard; r.w>=len+4 for clean shadow */
void button_handle(View* self, int key); /* Enter/Space -> group_end(owner, cmd) */
```
Standard **W×2** `[button §3; COLORVGA.PAS:258]`. `s=w-1`, title row `T=0`, `i = down?2:1`. Strip `~`; `len`=display length; `l=(s-len-1)/2; if(l<1)l=1;` local label col `lc=i+l`.

Per row `y=0` (face) — **UP state** `[button §3]`:
- col 0 = blank (the 2,1 shadow offset — leave panel showing).
- cols `1..s-1` = `dn_fill(... EM_BTN_FACE)`.
- col `s` = right-edge shadow glyph **220** (`▄`) at `y==0` (219 `█` on middle rows if H>2), drawn `fg=DN_SHADOW,bg=EM_PANEL_BG` `[button §2; tvtext1.cpp:116]`.
- label at `lc`: `dn_puts(disp, lbl, EM_BTN_FACE)` where `lbl = focused/default?EM_BTN_LBL_H:EM_BTN_LBL_N`; over-stamp hotkey char in `EM_BTN_HOT` `[button §5]`.
- **default/focused only**: `►`(16) at `lc-1`, `◄`(17) at `lc+len`, colour `EM_BTN_PTR` (cyan). Clamp into `[x+1, x+s-1]`; if the label nearly fills, fall back to edge cols `x+1`/`x+s-1` `[button §6]`. **This is the mandatory filled+pointer style; no brackets.**

> **Provenance note (do NOT "restore fidelity" by deleting these).** The cyan `►◄` pointers are an **owner enhancement, not DN/TV-authentic**. In colour mode TV/DN distinguish the default button by **face colour only** — `TView::showMarkers = False` by default (`tview.cpp:37`), flipped True only in monochrome (`tprogram.cpp:253/264`), and DN sets `ShowMarkers := False` in colour (`DNAPP.PAS:874`); the pointer/bracket code is gated on `showMarkers==True` (`tbutton.cpp:89,138,154`). Had they drawn (mono only), the glyphs would be `»/«`(175/174, selected) or `→/←`(26/27, default) at the button **edges** (col 0 / col s), never 16/17 flanking the label (`tvtext1.cpp:64`, `tbutton.cpp:97-98`). The owner explicitly requires the cyan 16/17 pointers (it is literally the current `dn_button`, `loader_main.c:396,400`), so **keep them — owner spec wins.** By contrast the filled **face + block-glyph shadow (220/219/223) geometry IS DN-authentic** (`tbutton.cpp:102-164`, `tvtext1.cpp:116`).

Shadow row `y=1` — cols `2..s` = **223** (`▀`), `fg=DN_SHADOW,bg=EM_PANEL_BG` `[button §3]`.

**Pressed** (transient on Enter/Space): face shifts to cols `2..s` (`i=2`), **no pointers, no shadow row** (whole row blank) — the push-in cue `[button §3]`.

Per-state colour `[button §7]`: face bg constant across enabled states; only label brightness escalates (normal `EM_BTN_LBL_N` → focused `EM_BTN_LBL_H`); hotkey always `EM_BTN_HOT`; disabled → desaturated face + `EM_DIM_FG` label, no accent. Focus ⇒ default (coupled) `[button §7; tbutton.cpp:296]`.

Worked map (`~O~K`, W=10): `. F F ► O K ◄ F F ▄` / `. . ▀ ▀ ▀ ▀ ▀ ▀ ▀ ▀` `[button §8]`.

### 2.3 Input line — `input_draw/handle` `[inputs §1; tinputli.cpp:134-161]`

```c
typedef struct { View v; char* buf; int max, cur, first, selA, selB; } Input;
void input_init(Input* in, Rect r, char* buf, int max);   /* r.h==1 */
void input_draw(View* self);
void input_handle(View* self, int key);   /* ASCII inserts; K_LEFT/RIGHT/HOME/END/K_BACK/K_DEL */
```
Draw `[inputs §1]`: fill width with field bg (`EM_DLG_BG`, brighter than dialog if you want the recessed look); text from **col 1** (`DrawShift=1`); `►`(16) at last col if scroll-right possible, `◄`(17) at col 0 if `first>0`, both `EM_POINTER`; selection span re-drawn in `EM_INV_FG/EM_INV_BG`. Focus indicator = the hardware cursor at `cur-first+1` **plus** select-all-on-focus (freshly focused field shows all text inverse until a keypress) `[inputs §1; tinputli.cpp:526-527]`. Backing store is the caller's `char buf[]` (e.g. `RenameDialog.namebuf`).

### 2.4 Cluster: Checkbox / Radio — `check_draw/radio_draw` + `cluster_handle` `[inputs §2; tcluster.cpp:80-129]`

```c
typedef struct { View v; const char* const* labels; int n; int* value; int isRadio; } Cluster;
void check_init(Cluster* c, Rect r, const char*const* labels,int n, int* bitmask);
void radio_init(Cluster* c, Rect r, const char*const* labels,int n, int* index);
void cluster_draw(View* self);
void cluster_handle(View* self,int key);  /* K_UP/DOWN move item; Space/Enter toggle/select */
```
Single-column (our case, `r.h>=n`): item `i` at row `i`, layout per item `[inputs §2]`: `col+0` space, `col+1` `(`/`[`, **`col+2` marker**, `col+3` `)`/`]`, `col+4` space, **`col+5` label**. Marker: radio `•`(7) when `i==*index` else space → `(•)`/`( )`; checkbox `X`(88) when `*mask&(1<<i)` else space → `[X]`/`[ ]` `[inputs §0; tradiobu.cpp:20, tcheckbo.cpp:20]`. Colours: normal `EM_NORMAL_FG` on `EM_DLG_BG`; the item under the cursor **when the cluster is focused** = `EM_INV_FG/EM_INV_BG` with the hardware cursor on its marker `[inputs §2]`; hotkey letter `EM_HOTKEY`; disabled `EM_DIM_FG`. `showMarkers` stays **off** — state shown by colour + the `•/X` glyph only.

### 2.5 Static text / Label — `stext_draw` / `label_draw` `[inputs §3-4]`

```c
typedef struct { View v; const char* text; } StaticText;   /* non-selectable */
typedef struct { View v; const char* text; View* link; } Label;  /* brightens when link focused */
```
Static: word-wrap into `w×h`, text from col 0; a leading char `3` (0x03) centres that line `[inputs §3]`; colour `EM_DLG_FG`. Label: text from col 1 with `~x~` accent; when `link->state & sfFocused` → brighten body toward `EM_BRIGHT_FG` `[inputs §4; tlabel.cpp:100]`. Neither is `ofSelectable` → Tab skips them.

### 2.6 List viewer — `listview_draw/handle` `[inputs §5; tlstview.cpp:77-157]` ← the browser panel

```c
typedef struct {
  View v; int count, cur, top, cols;
  void (*getText)(int idx, char* out, int outmax);  /* supplied by the app (browser) */
  uint32_t (*rowFg)(int idx);                        /* app: file-type colour (dir/snap/tape/music) */
  int (*isTagged)(int idx);
} ListView;
void listview_draw(View* self);
void listview_handle(View* self,int key);  /* K_UP/DOWN/PGUP/PGDN/HOME/END; Enter -> owner cmd */
```
For each visible row: fill cell with base colour, draw scrolled text at `curCol+1`, column divider `│`(179) at `curCol+colWidth-1` in `EM_DIM_FG` **only if `cols>1`** (single column ⇒ divider clipped, none) `[inputs §5]`. **Focus rule (key):** the highlight bar (`EM_INV_FG/EM_INV_BG` = black-on-cyan) + hardware cursor appears **only when the list itself is focused/active** (both `sfSelected|sfActive` set); an unfocused list shows the same rows with no bar `[inputs §5; tlstview.cpp:86-97; model-shadow-color §4.3]`. Tagged items keep `EM_POINTER` regardless. `getText/rowFg/isTagged` are the seams the browser plugs into (Part 6.4).

### 2.7 Scrollbar — `scrollbar_draw` `[inputs §6; tscrlbar.cpp:60-108]`

```c
typedef struct { View v; int val, minV, maxV; } ScrollBar;  /* vertical if w==1 */
void scrollbar_draw(View* self);
```
Vertical (`w==1`, `size=max(3,h)`, `s=size-1`, `range=maxV-minV`): cell 0 = `▲`(30) `EM_POINTER`; cells `1..s-1` = `▒`(177) `EM_DIM_FG` (or `▓`(178) if `range==0` — **inactive, no thumb**); thumb `■`(254) `EM_POINTER` at

```
pos = ((val - minV) * (size - 3) + range/2) / range + 1      /* range>0 only */
```

**(1 cell, does not scale)** — the `+range/2` rounding term is added to the *product* before dividing `[inputs §6; tscrlbar.cpp:95, getSize()=max(3,dim) at :98-107]`. Cell `s` = `▼`(31) `EM_POINTER`. Horizontal swaps arrows for `◄`(17)/`►`(16). This is the browser's right-edge scrollbar and any list/memo field in a dialog.

---

## PART 3 — DROPDOWN-MENU SUBSYSTEM

### 3.1 Data model `[dropdown §0]`

```c
typedef struct Menu Menu;
typedef struct {
  const char* name;         /* "~F~iles"; NULL = separator */
  uint16_t    cmd;          /* leaf command; 0 if submenu or value-item */
  uint16_t    key;          /* global accelerator keysym (K_F6…), 0=none */
  const char* param;        /* right-aligned shortcut label ("F6"), or NULL */
  const Menu* sub;          /* submenu (cmd==0 && sub!=NULL), or NULL */
  const menu_item* value;   /* OPTIONAL inline value-item -> reuses the settings engine */
  uint8_t     disabled;
} MenuItem;
struct Menu { const MenuItem* items; int count; int deflt; };   /* deflt = remembered cursor */
typedef struct { const char* title; const Menu* menu; } BarItem; /* title carries ~hotkey~ */
```

### 3.2 The five bar tables + app commands (concrete starting point)

```c
enum { /* app commands (loader) */
  cmFileLoad=cmBase, cmFileUp, cmFileRename, cmFileMkdir, cmFileDelete, cmFileSort, cmFileRev,
  cmPlayStart, cmPlayStop, cmPlayPause, cmPlayerWin,
  cmTapePlay, cmTapeStop,
  cmOptSettings, cmOptSave, cmOptEject,
  cmHelpAbout, cmHelpKeys };

static const MenuItem mi_files[] = {
  {"~L~oad / Run", cmFileLoad,  K_ENTER, "Enter"},
  {"~U~p one dir", cmFileUp,    0,       NULL},
  {NULL},                                                   /* separator */
  {"~R~ename\x85", cmFileRename,K_F6,    "F6"},             /* \x85 = "…" if in font, else "..." */
  {"~M~ake dir\x85",cmFileMkdir,0,       NULL},
  {"~D~elete\x85", cmFileDelete,K_DEL,   "Del"},
  {NULL},
  {"~S~ort mode",  0,           K_F3,    "F3", NULL, &opt_items[0]},  /* value-item: SORT (reuses settings) */
  {"Re~v~erse",    cmFileRev,   0,       "Alt+F3"},
};
static const Menu m_files = { mi_files, 9, 0 };

static const MenuItem mi_play[] = {
  {"~S~tart",   cmPlayStart, 0, "Space"},
  {"S~t~op",    cmPlayStop,  0, "BkSp"},
  {"~P~ause",   cmPlayPause, 0, "Space"},
  {NULL},
  {"~M~ode",    0, K_F2, "F2", NULL, &opt_items[4]},        /* value-item: PLAY MODE */
  {NULL},
  {"Player ~w~indow", cmPlayerWin, K_F8, "F8"},
};
static const Menu m_play = { mi_play, 7, 0 };

static const MenuItem mi_tape[] = {
  {"~P~lay tape", cmTapePlay, 0, NULL},
  {"S~t~op tape", cmTapeStop, 0, "BkSp"},
  {NULL},
  {"~S~ound",     0,0,NULL,NULL,&opt_items[12]},            /* value-items reuse the settings table */
  {"~M~P3 as tape",0,0,NULL,NULL,&opt_items[14]},
  {"~L~ong leader",0,0,NULL,NULL,&opt_items[15]},
};
static const Menu m_tape = { mi_tape, 6, 0 };

static const MenuItem mi_opts[] = {
  {"~S~ettings\x85", cmOptSettings, 0, NULL},               /* opens the config DIALOG (Part 4.5) */
  {NULL},
  {"Sa~v~e config",  cmOptSave,    0, NULL},                /* act_save()  */
  {"~E~ject SD",     cmOptEject,   0, NULL},                /* act_eject() */
};
static const Menu m_opts = { mi_opts, 4, 0 };

static const MenuItem mi_help[] = {
  {"~A~bout\x85", cmHelpAbout, K_F1, "F1"},
  {"~K~eys\x85",  cmHelpKeys,  0, NULL},
};
static const Menu m_help = { mi_help, 2, 0 };

static BarItem g_bar[] = {                                  /* order == LEFT/RIGHT order */
  {"~F~iles",   &m_files}, {"~P~lay", &m_play}, {"~T~ape", &m_tape},
  {"~O~ptions", &m_opts},  {"~H~elp", &m_help} };
static const int g_bar_n = 5;
```

Note the **value-item bridge**: an entry with `->value` set (pointing into the existing `opt_items[]`) shows `LABEL … VALUE` and cycles on Enter using the current settings engine (`menu_activate` logic). Zero data duplication; the quick toggles stay in the dropdown, the heavy settings go to the dialog.

### 3.3 Bar draw + anchor capture `[dropdown §1-2]`

Replace the static bar draw in `render_browser_dn` (l.892-895). Draw row 0 and **record each item's `x0`** so the dropdown anchors exactly under it (works with any spacing):

```c
static int g_bar_x0[8], g_bar_w[8];        /* filled by menubar_draw */
void menubar_draw(int cur){                /* cur = highlighted bar item, or -1 */
  dn_fill(0,0,DN_COLS,1, EM_CHROME_BG);
  int x=2;                                 /* col 0/1 gutter; keep our layout */
  for(int i=0;i<g_bar_n;i++){
    int len=cstrlen(g_bar[i].title);       /* display length, ignores '~' [drivers2.cpp:76] */
    g_bar_x0[i]=x; g_bar_w[i]=len;
    int sel=(i==cur);
    uint32_t fg=sel?EM_INV_FG:EM_CHROME_FG, bg=sel?EM_INV_BG:EM_CHROME_BG;
    if(sel) dn_fill(x-1,0,len+2,1,bg);     /* highlight the leading+trailing pad */
    put_cstr(x,0,g_bar[i].title, fg,bg, EM_HOTKEY); /* body fg; ~letter~ in red */
    x += len + 2;                          /* DN stride: +2 = exactly one blank column between titles [tmenubar.cpp:86] */
  }
  /* version string top-right stays as l.895 */
}
```
Dropdown anchor for item `i` `[dropdown §2: left=itemRect.a.x-1, top=1]`: `left = g_bar_x0[i]-1; top = 1;` then flip if it would overrun the right edge (`if(left+W>DN_COLS) left=DN_COLS-W`).

> **Anchor reconciliation (stated so nobody re-derives it as a bug):** TV's raw formula `left = itemRect.a.x - 1` measures from an origin that *includes* the desktop's external frame margin at col 0. Our `dn_box` has **no external margin**, so `g_bar_x0[i]-1` lands the dropdown's border one column left of the title text — and the net **item-text column matches TV**. The two expressions look contradictory but describe the same rendered column.

### 3.4 Box sizing + row rendering `[dropdown §2-3]`

```c
typedef struct { const Menu* menu; int bar, cur, left, top, W, H; } MenuState;

void menubox_size(const Menu* m,int* W,int* H){
  int w=10;
  for(int i=0;i<m->count;i++){ const MenuItem* it=&m->items[i]; if(!it->name) continue;
    int L=cstrlen(it->name)+6;
    if(it->cmd==0 && it->sub) L+=3;                      /* submenu arrow room */
    else if(it->param)        L+=cstrlen(it->param)+2;   /* shortcut room */
    else if(it->value)        L+=8;                      /* value room */
    if(L>w) w=L; }
  *W=w; *H=2+m->count;                                   /* +2 = top/bottom border rows */
}
```
Render `[dropdown §3]`: outer frame `dn_box(left,top,W,H, EM_FRAME, EM_CHROME_BG, 0)` (single-line). Per item row `ry`:
- fill interior `dn_fill(left+1,ry,W-2,1, rowBg)` where `rowBg = (idx==cur)?EM_INV_BG:EM_CHROME_BG`.
- name via `put_cstr(left+2, ry, name, rowFg, rowBg, EM_HOTKEY)`; `rowFg = disabled?EM_DIM_FG : (idx==cur?EM_INV_FG:EM_CHROME_FG)` (disabled ⇒ no hotkey accent).
- if `sub`: `►`(16) at `left+W-3`. If `param`: right-aligned at `left+W-3-len(param)` in `rowFg`. If `value`: draw the value string (from `it->value->choices[*it->value->val]` or the RANGE number) right-aligned in `idx==cur?EM_INV_FG:EM_HEADER`.
- **separator** (`name==NULL`): a thin `dn_hpx` line across `left+1..left+W-2` at the row's mid-scanline in `EM_FRAME` (our pixel-line equivalent of `├─┤`).

Shadow: `dn_shadow(left,top,W,H)` (Part 5) before the box.

### 3.5 The modal nav FSM (flat bar; non-recursive) `[dropdown §5]`

```c
int menubar_exec(int start){                 /* returns a command id, 0 = cancelled */
  int bar = start<0 ? 0 : start;             /* or restore last-used */
  MenuState ms; int done=0, ret=0;
  menubox_enter(&ms, bar);                    /* ms.menu=g_bar[bar].menu; ms.cur=menu->deflt; size+anchor */
  render_browser();                           /* BACKDROP stays drawn underneath */
  menubar_draw(bar); dn_shadow(ms.left,ms.top,ms.W,ms.H); menubox_draw(&ms);
  while(!done){
    int k = ui_getkey();
    switch(k){
      case K_LEFT:  bar=(bar-1+g_bar_n)%g_bar_n; goto reopen;   /* switch menus, auto-open (sticky autoSelect) */
      case K_RIGHT: bar=(bar+1)%g_bar_n;         goto reopen;
      case K_UP:    menubox_move(&ms,-1); break;                /* skips separators, wraps; repaint 2 rows */
      case K_DOWN:  menubox_move(&ms,+1); break;
      case K_HOME:  menubox_first(&ms); break;
      case K_END:   menubox_last(&ms);  break;
      case K_ENTER: {
        const MenuItem* it=&ms.menu->items[ms.cur];
        if(it->disabled || !it->name) break;
        if(it->value){ menuitem_value_cycle(it,+1); menubox_row(&ms,ms.cur); break; } /* stay open, cycle */
        if(it->sub){ /* rare: nested submenu -> recurse menubox loop anchored at parent.left+2 [dropdown §2] */ break; }
        ret=it->cmd; done=1; break;                              /* leaf -> return command */
      }
      case K_ESC: case K_F9: ret=0; done=1; break;               /* Esc OR F9-again: exit whole menu */
      default:
        if(k>=32 && k<127){                                      /* hotkey letter [dropdown §5 default] */
          int idx=menu_find_hotkey(ms.menu,k);                   /* match char after '~', enabled only */
          if(idx>=0){ ms.cur=idx; /* then act as Enter */ 
                      const MenuItem* it=&ms.menu->items[idx];
                      if(it->value){menuitem_value_cycle(it,+1);menubox_row(&ms,idx);}
                      else if(it->cmd){ret=it->cmd;done=1;} break; }
          int b=bar_find_hotkey(k);                              /* Alt+letter / bar letter -> jump menu */
          if(b>=0){ bar=b; goto reopen; }
        }
        break;
    }
    continue;
  reopen:
    menubox_enter(&ms,bar);
    render_browser(); menubar_draw(bar); dn_shadow(ms.left,ms.top,ms.W,ms.H); menubox_draw(&ms);
    ms.menu = g_bar[bar].menu;                                   /* deflt remembered per menu */
  }
  render_browser();                            /* CLOSE: repaint the browser backdrop — never hide it */
  return ret;
}
```
This satisfies the owner exactly: **F9 opens the bar with a dropdown open; LEFT/RIGHT switch menus and auto-open the neighbour (`goto reopen`); Esc or F9 exits back to the browser** (which is always the backdrop and is repainted, not hidden). Global accelerators (a leaf's `->key`) can also be dispatched directly from the main loop without opening the bar (Part 6.3). Nested submenus (`->sub`) are supported by re-entering `menubox_*` anchored at `parent.left+2` `[dropdown §2]`, but the five main menus are flat so the recursion path is dormant.

`menubox_move` repaints only the two changed rows (old cursor + new) `[dropdown §5 trackKey; matches current menu_move l.1819]`.

---

## PART 4 — MODAL-DIALOG SUBSYSTEM `[modal §; tdialog.cpp/tgroup.cpp]`

### 4.1 Build-by-data

A concrete dialog embeds its `Group` + all widgets + backing buffers, so it's one allocation. Insert children in **tab order**:

```c
void dlg_init(Group* d, Rect r, const char* title, uint32_t body);  /* sets d->v.draw=group_draw, sfModal on exec */
void dlg_add (Group* d, View* child);                               /* child->bounds is dialog-relative */
```
Margins `[modal §2]`: content x starts at **col 2** (col 1 blank); right limit **col W-3**; first content row 1-2; the **bottom button row top at `H-3`** — face on row `H-3`, its `▀` shadow row on `H-2` seated directly on the frame at `H-1` with no gap `[modal §2; msgbox.cpp:84 → moveTo(x, size.y-3)]`. (A W×2 button at row `H-4` would float with a stray blank row above the frame — that was the pre-review error.) Canonical field patterns (label-left+input; label-above+list+scrollbar; right-aligned button column) are in `[modal §2]`. Centred button row: buttons 10×2, `startX=(W-Σw-2(n-1))/2` = `(W-Σ(w+2)+2)/2`, stride `w+2` `[modal §2; msgbox.cpp:69-86]`.

### 4.2 Draw order `[modal §3]`

`group_draw(d)`:
1. `dn_shadow(abs)` behind (Part 5).
2. body fill = frame interior spaces in `body`.
3. **double-line** frame + centred title + close `[■]` (a dialog is always active) `[modal §1]`.
4. children in array order (static/labels/scrollbars, then inputs/clusters/buttons).
5. focused control's cursor last.
Incremental repaint on focus/value change redraws **only the changed child** `[modal §3; anti-flicker rule]`.

### 4.3 The modal loop (Tab / default / cancel / valid) `[modal §4]`

```c
int  dlg_valid(Group* d, int endState);   /* cmCancel -> always True; else every Input's validator must pass */

int dlg_exec(Group* d){
  d->v.state |= sfModal|sfVisible;
  layout_abs(&d->v); for(int i=0;i<d->nch;i++) layout_abs(d->ch[i]);
  if(d->cur<0) dlg_focus_next(d,+1);          /* seat initial focus [msgbox.cpp:88] */
  group_draw(d);
  do {                                        /* TV modal loop: do{...}while(!valid(endState)) [tgroup.cpp:184] */
    d->endState=0;
    while(!d->endState){
      int k = ui_getkey();                    /* blocks; bg_pump() inside -> FIFO-safe */
      dlg_handle(d,k);
    }
  } while(!dlg_valid(d, d->endState));         /* failed validator -> reset, KEEP dialog open */
  return d->endState;                          /* cmOK / cmCancel / any button cmd; caller repaints backdrop */
}
void dlg_handle(Group* d,int k){
  if(k==K_ESC){ group_end(d,cmCancel); return; }                 /* Esc = cancel; valid(cmCancel)=True [tdialog.cpp:56] */
  if(k==K_ENTER){ Button* t=dlg_enter_target(d); if(t) group_end(d,t->cmd); return; } /* default btn */
  if(k==K_TAB ){ dlg_focus_next(d,+1); return; }
  if(k==K_STAB){ dlg_focus_next(d,-1); return; }
  if(k>=32&&k<127){ if(dlg_preprocess_hotkey(d,k)) return; }      /* ~x~ labels/buttons [model §3.2] */
  if(d->cur>=0) d->ch[d->cur]->handle(d->ch[d->cur], k);         /* route to focused control */
}
```
`dlg_focus_next` `[modal §4; tgroup.cpp:224-256]`: step index (wrap), skip `!ofSelectable | sfDisabled`, `setCurrent`, repaint old+new. `dlg_enter_target` `[button §7; modal §4]`: the **focused button** if the focused child is a Button (grab-default), else the designated `bfDefault` button — so the Enter target + the cyan-pointer emphasis follow focus when it's on a button, otherwise rest on the default. `dlg_valid()` gate `[modal §4; tgroup.cpp:184]`: `cmCancel` always allowed (so Esc/Cancel always closes); other exits require every input's validator to pass (input-line length/char rules) — a failing validator resets `endState` and the outer `do/while` keeps the dialog open. No validators are wired yet, so the effect is latent, but the hook is present.

### 4.4 setData / getData + snapshot-revert `[modal §4]`

Two supported binding styles; use **live-bound + snapshot** for settings (keeps the current live-apply UX with clean OK/Cancel), and the **record walk** for value objects (player state, Tetris scores):

```c
/* A) live-bound (settings): controls point at the real variables; onchange applies immediately. */
void dlg_snapshot(Group* d);   /* copy each bound var into a save slot on OPEN */
void dlg_revert  (Group* d);   /* on cmCancel: restore vars + re-run their apply() */
/* B) record walk [modal §4; tgroup.cpp:303-315]: fixed control order, dataSize per control:
     Input=max+1, Cluster=2 (u16 index/bitmask), Button/Label/Static=0. */
void dlg_setData(Group* d, void* rec);   /* BEFORE exec */
void dlg_getData(Group* d, void* rec);   /* AFTER, if endState!=cmCancel */
```

### 4.5 The two concrete dialogs the owner needs

**Rename dialog** (from `Files ▸ Rename…`, F6) — Archive-dialog style `[modal §; button §; inputs §1]`:
```c
typedef struct {
  Group dlg; StaticText prompt; Input name; Button ok, cancel, help;
  char buf[NAMELEN+1];
} RenameDialog;
void rename_dialog(const char* oldname){
  RenameDialog r; strcpy(r.buf, oldname);
  dlg_init(&r.dlg, (Rect){24,7,32,9}, "Rename", EM_DLG_BG);        /* H=9 -> button row top = H-3 = 6 */
  stext_init(&r.prompt,(Rect){2,2,28,1}, "New file name:");        dlg_add(&r.dlg,&r.prompt.v);
  input_init(&r.name, (Rect){2,3,28,1}, r.buf, NAMELEN);           dlg_add(&r.dlg,&r.name.v);
  button_init(&r.ok,   (Rect){4,6,10,2}, "~O~K",     cmOK,     bfDefault); dlg_add(&r.dlg,&r.ok.v);     /* y=H-3 */
  button_init(&r.cancel,(Rect){15,6,10,2},"~C~ancel", cmCancel, 0);        dlg_add(&r.dlg,&r.cancel.v);  /* y=H-3 */
  int res = dlg_exec(&r.dlg);
  if(res==cmOK) do_rename(oldname, r.buf);                         /* f_rename via sdop_freeze_begin/end */
  render_browser();                                                /* backdrop repaint */
}
```
Button row = `>OK<  Cancel` with cyan pointers on OK (the default), translucent shadow, Tab moves focus, Enter fires the focused/default button, Esc cancels — exactly the requested DN Archive style. With H=9 the buttons sit on rows 6-7, their `▀` shadow on row 7 (H-2) directly above the frame on row 8 (H-1) — no floating gap.

**Config dialog** (from `Options ▸ Settings…`) — the recommendation below; built from the existing `opt_items[]`.

### 4.6 Bridge: `dialog_from_menu()` — reuse the settings table verbatim

The existing `menu_item[]` maps mechanically onto dialog controls, so no data is duplicated `[owner req: render data-driven table faithfully + real buttons]`:

| `item_kind` | rendered as | control |
|---|---|---|
| `ITEM_CHOICE`, `nchoices==2` (NO/YES) | checkbox `[X]` | `Cluster` (checkbox, 1 item) |
| `ITEM_CHOICE`, `nchoices>2` | radio cluster `(•)` | `Cluster` (radio, N items) — or a 1-line "cycler" |
| `ITEM_RANGE` | value + `◄ ►` stepper | `Input`-like stepper (L/R = ±step, live) |
| `ITEM_ACTION` | filled button | `Button` (cmd runs `action`) |

```c
void dialog_from_menu(Group* d, menu_t* m);   /* walk m->items, add the mapped control per row,
                                                  bind ->val, wire ->onchange as live-apply */
```
`onchange` still fires on every change (live preview). `dlg_snapshot` on open + `dlg_revert` on Cancel give safe commit/revert. Because 19 items is a lot for one modal, split into topical dialogs (Display/Browser, Sound/Tape, Position) each built from a slice of `opt_items[]`, or use one dialog with a scrolling `ListView` of controls.

---

## PART 5 — SHADOW ARGB RULE `[model-shadow-color §1]`

Keep the accepted translucent drop shadow; make it correct per the study. The existing `dn_shadow` L-shape (l.389-391) already matches DN's offset region exactly `[§1.4]`: right band cols `X+w,X+w+1` rows `Y+1..Y+h`; bottom band cols `X+2..X+w-1` row `Y+h`; they meet in the bottom-right corner — verified an L, not a filled box. **Keep it.** Two required upgrades to `dn_dim_cell`:

```c
/* char-preserving, idempotent-by-redraw, near-black floor, transparent -> translucent black */
static void dn_dim_cell(int cx,int cy){
  if(cx<0||cy<0||cx>=DN_COLS||cy>=DN_ROWS) return;
  for(int r=0;r<16;r++){ int qy=cy*16+r;
    for(int c=0;c<8;c++){ int qx=cx*8+c; uint32_t p=g_osdc[qy*OSDC_W+qx];
      uint32_t a=p&0xFF000000u, rr=(p>>16)&0xFF, gg=(p>>8)&0xFF, bb=p&0xFF;
      if(a==0){                                   /* transparent OSD over live video: cast onto video  [§1.6(6)] */
        g_osdc[qy*OSDC_W+qx]=0x60000000u;         /* ~38% black -> shadow reads over the ZX picture     */
      } else {
        uint32_t y=(rr*54+gg*183+bb*19)>>8;       /* luma */
        if(y<24){                                 /* near-black floor: don't vanish  [§1.6(5)]           */
          g_osdc[qy*OSDC_W+qx]=a|0x00555555u;     /* fixed dim grey = DOS[8]                              */
        } else {
          g_osdc[qy*OSDC_W+qx]=a|((rr>>1)<<16)|((gg>>1)<<8)|(bb>>1);  /* halve RGB, keep glyph [§1.6(2)] */
        }
      } } }
}
```
**Idempotency** `[§1.6(1)]`: halving compounds if a cell is dimmed twice. Our engine avoids this by the group rule — **always fully repaint the backdrop region before `dn_shadow`** (as `menubar_exec`/`open_options` already do via `render_browser`). So shadow is applied exactly once per fresh backdrop. For partial redraws where you cannot repaint the backdrop, carry a 1-bit "already shadowed" flag per cell (`slNoShadow`) and skip re-dimming `[§1.5]`. Never blank a shadow cell to a space — dim the colour only `[§1.2]`.

Who casts: **windows, dialogs, and menu boxes** set `sfShadow`; the **browser panel, top bar, and status bar do not** `[§1.5]`.

---

## PART 6 — FILE / FUNCTION LAYOUT + GRAFT

### 6.1 Files (fits the existing multi-`.c` build; memory: `build_browser.sh` compiles the set)

```
dnui.h   — Rect, View, Group, Menu/MenuItem/BarItem, enums (sf*/of*/cm*/K_*/bf*),
           EM_* colour tokens, prototypes for every dn_* primitive + widget + menu/dialog exec.
dnui.c   — the primitives (dn_*), colour helpers, put_cstr/cstrlen, every widget draw/handle,
           frame/button/input/cluster/label/stext/listview/scrollbar,
           menubar_draw/menubox_*/menubar_exec, dlg_*/dlg_valid/dialog_from_menu, dn_shadow/dn_dim_cell.
loader_main.c — includes dnui.h; owns: g_osdc canvas + OSDC_W/H, DOS[]/FG/BG/DNK_*,
           bg_pump(), ui_getkey(); the bar tables (Part 3.2); app_dispatch(cmd);
           rename_dialog()/config dialogs; the browser getText/rowFg/isTagged seams.
```
Move l.326-405 (palette + primitives) into `dnui.c`, exporting via `dnui.h`; leave `g_osdc`, `OSDC_W/H`, `DOS[]`, `g_dn_alpha` in `loader_main.c` (declared `extern` in `dnui.h`). First-cut alternative: paste `dnui.c` as one `#include "dnui.inc"` section inside `loader_main.c` to avoid touching the build immediately.

### 6.2 Exact graft points in `loader_main.c`

- **l.394-405 `dn_button`** → delete; call sites use the `Button` widget. The dropdown's action rows (l.1786-1789) become `Button` draws.
- **l.892-895 (bar in `render_browser_dn`)** → replace with `menubar_draw(-1)` (records `g_bar_x0[]`). Keep the version string (l.895).
- **l.896-901 (panel + path title)** → a `Frame` (active window, `dbl=1`) + `dn_draw_list` behind a `ListView` (Part 6.4).
- **l.1913-1921 `open_options/open_view/toggle_view`** → Options is no longer a persistent `osd_view`. F9 now runs the bar:
```c
/* main loop, replacing the F9 branch at l.2336 / l.2359 */
if(k==K_F9){ int cmd = menubar_exec(/*start=*/0); if(cmd) app_dispatch(cmd); continue; }
```
- **l.2347-2361 (inline `opt_on` routing of UP/DOWN/LEFT/RIGHT/ENTER)** → removed while a modal owns the keys; `menubar_exec`/`dlg_exec` own those keys during their lifetime. Browser routing (UP/DOWN/PGUP/PGDN/ENTER/F3/F2 when `browser_on`) stays for the non-modal base state.
- **l.2369-2372 (Esc cascade)** → still valid for the base state (Esc closes any leftover OSD → player → machine); the menu/dialog Esc is handled inside their loops.
- **`menu_render/menu_move/menu_activate` (l.1804-1837)** → kept, but repurposed as the **value-item helper** (`menuitem_value_cycle`) reused by both inline menu value-items (Part 3) and `dialog_from_menu` steppers/cyclers (Part 4.6). `dn_menu_msg` (l.1809) stays for transient "SAVED"/"SAFE TO REMOVE" messages.

### 6.3 `app_dispatch` — the single command sink

```c
void app_dispatch(int cmd){
  switch(cmd){
    case cmFileLoad:   browser_enter(); break;
    case cmFileUp:     /* navigate ".." */ break;
    case cmFileRename: rename_dialog(flist[bcursor]); break;
    case cmFileMkdir:  mkdir_dialog();  break;
    case cmFileDelete: confirm_delete(flist[bcursor]); break;   /* Yes/No message dialog */
    case cmFileRev:    g_sort_desc=!g_sort_desc; sort_entries(); dn_draw_list(); break;
    case cmPlayStart:  browser_enter(); break;
    case cmPlayStop:   player_stop(); /*…*/ break;
    case cmPlayPause:  player_pause_toggle(); /*…*/ break;
    case cmPlayerWin:  winamp_on=1; OSD_CTRL|=2u; break;
    case cmTapePlay:   /* start tape */ break;
    case cmTapeStop:   tape_stop(); break;
    case cmOptSettings:config_dialog(); break;                  /* dialog_from_menu(&opt_menu) */
    case cmOptSave:    act_save();  break;                      /* existing l.1840 */
    case cmOptEject:   act_eject(); break;                      /* existing l.1846 */
    case cmHelpAbout:  show_help(); break;                      /* existing */
    case cmHelpKeys:   show_keys(); break;
  }
}
```
A leaf's global accelerator (`MenuItem.key`, e.g. `K_F6→cmFileRename`) can be dispatched directly from the main loop without opening the bar — the same command sink.

### 6.4 Browser → engine mapping (browser stays the always-present backdrop)

The browser becomes a **Window(Frame) + ListView** but keeps its bespoke row draw via the ListView seams — no rewrite of the file logic:
```c
static void browser_getText(int i,char* o,int n){ /* format one flist[] row: name/ext/size/date */ }
static uint32_t browser_rowFg(int i){
  if(fisdir[i]) return DNK_DIR;                     /* white dirs   */
  const char* e=fext(flist[i]);
  if(is_snap(e)) return DNK_SNAP; if(is_tape(e)) return DNK_TAPE; if(is_music(e)) return DNK_MUSIC;
  return DNK_FILE; }                                /* colours unchanged (l.344-348) */
static int browser_isTagged(int i){ return on_play_path(i); }
```
`bcursor/btop/fcount` bind to `ListView.cur/top/count`. The cyan cursor bar = ListView focused-item INVERSE (`DNK_CUR_BG`), shown only while the browser is the active view — which it is whenever no menu/dialog is modal. `render_browser()` draws Frame → ListView → `menubar_draw(-1)` → status row; `menubar_exec`/`dlg_exec` overlay their content and repaint `render_browser()` on close, so the browser is **never hidden** `[owner req]`.

### 6.5 RECOMMENDATION on Options (owner's explicit question)

**Put the settings in a modal config DIALOG opened from `Options ▸ Settings…`, not in the inline value-dropdown.** Rationale, decisive: (1) DN-authentic — DN's Options menu items open dialogs, they don't edit values inline (TV/DN menus are command/submenu only and cannot cycle a value inline — `tmnuview.cpp`, `tmenubox.cpp`; the current inline-value dropdown is itself the non-DN extension, so moving settings to a dialog is the authentic structure); (2) consistent with Rename and every future config; (3) radio/checkbox clusters read far better than a flat `LABEL……VALUE` list; (4) OK/Cancel gives safe commit/revert while `onchange` keeps live preview; (5) `dialog_from_menu(&opt_menu)` reuses the existing `opt_items[]` verbatim — **no functionality lost, no data duplicated** (honours the "never reduce functionality" rule). Keep a *few* high-frequency toggles (Play-mode, Tape-sound, Volume via numpad ±) additionally reachable as **inline value-items** inside the Play/Tape dropdowns (Part 3.2) so power users don't open a dialog for a quick flip. So: **dialog for the full settings, inline value-items for the hot handful** — both drawn by this one engine, both fed by the one `opt_items[]` table.

### 6.6 Extensibility (player window + Tetris ride the same engine)

Both are just a `View`/`Group` with a custom `draw`/`handle`:
- **Music-player window**: a `Frame`-topped `Group`; children are either native widgets or the existing sprite skin blits (`winamp_draw`, l.1870) wrapped as one custom-`draw` View. Run **non-modally** as a floating window (it casts a shadow, sits over the browser) or modally via `dlg_exec` when you want it to own input.
- **Tetris**: a single `View` whose `draw` renders the well with `dn_putc` glyphs and `handle` consumes `K_LEFT/RIGHT/DOWN/UP`; insert into a `Group` and `dlg_exec` it modally, or make it the active view like the browser. The core model (View + Group + `ui_getkey`/`bg_pump` loop + shadow) is all it needs — no engine changes.

---

## OPEN ITEMS (owner sign-off before / during coding)

- **⚠ Green button face (`EM_BTN_FACE=FG(2)`).** This is a **new hue outside the owner's fixed 5-colour palette** (dkgray/white/cyan/yellow/red) and is **not sourced from DN** (TV's gray dialog uses `cpGrayDialog`, not a saturated green — `tdialog.cpp:31`). It is themable (one `#define`). Confirm the hue with the owner, or alias `EM_BTN_FACE` onto an existing token. Everything else in the button (filled face + 220/219/223 block-glyph shadow, geometry) is verified DN-authentic.
- **Cyan `►◄` button pointers** are an owner enhancement, preserved by spec — see the provenance note in Part 2.2. Do not delete them as a "fidelity fix."

---

### Minimum build order (each testable on hardware)
1. `dnui.h` core + `ui_getkey/bg_pump` + move primitives; **filled `Button`** replacing `dn_button` (visible win immediately in the current Options dropdown action rows).
2. `menubar_draw`+`menubox_*`+`menubar_exec` on the 5 tables; wire F9 → `menubar_exec` → `app_dispatch`. (LEFT/RIGHT dropdowns over the browser.)
3. `Dialog` core + modal loop (`dlg_exec` with the `valid()` re-entry) + `Input`/`StaticText` → **Rename dialog** (F6, buttons at H-3).
4. `Cluster`/`Label`/`ScrollBar` + `dialog_from_menu` → **config dialog** (Options ▸ Settings…).
5. Reframe browser as Window+ListView; fold `dn_draw_list` behind the ListView seams.

Everything above keeps the current ARGB palette (dkgray panels / white frames / cyan cursor / yellow headers / red hotkeys), reuses `dn_*`, and preserves the live-apply settings model — DN supplies only structure, glyphs, geometry, and logic.