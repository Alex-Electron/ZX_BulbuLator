/* =================================================================================================
 * tv_ui.c - Declarative Turbo Vision / DOS Navigator UI Framework for BulbuLator
 * =================================================================================================
 */
#include "tv_ui.h"

int g_modal_level = 0;

/* Счётчик мутаций файловой системы. Кэша дерева больше нет (v0.15.395: диалог каталогов читает
   только текущий уровень), но счётчик оставлен: он машино-агностичный признак «на карте что-то
   изменилось», и на него смотрят другие места. Обе функции существуют ради вызовов из прошивки. */
uint32_t g_fs_mutation_seq = 1;

void tv_fs_touch(void) { g_fs_mutation_seq++; }

void tv_fs_invalidate_cache(void) { g_fs_mutation_seq++; }

/* Helper: string length */
static int tv_slen(const char* s) {
    int n = 0;
    if (s) while (s[n]) n++;
    return n;
}

/* Helper: case-insensitive string compare */
static int tv_strcasecmp(const char* s1, const char* s2) {
    while (*s1 && *s2) {
        char c1 = (*s1 >= 'a' && *s1 <= 'z') ? (*s1 - 32) : *s1;
        char c2 = (*s2 >= 'a' && *s2 <= 'z') ? (*s2 - 32) : *s2;
        if (c1 != c2) return (unsigned char)c1 - (unsigned char)c2;
        s1++; s2++;
    }
    return (unsigned char)*s1 - (unsigned char)*s2;
}

/* Compact shadowless 3-cell inline picker button [▼] */
static void dn_picker_btn(int x, int y, int focused) {
    uint32_t bg = focused ? DNK_CUR_BG : DNK_DLG_BG;
    uint32_t fg = focused ? DNK_CUR_FG : DNK_HOTKEY;
    uint32_t brk_fg = focused ? DNK_CUR_FG : DNK_DLG_FG;
    
    dn_putc(x,     y, '[', brk_fg, bg);
    dn_putc(x + 1, y, 0x1F, fg, bg);   /* 0x1F = ▼ in vga866.h */
    dn_putc(x + 2, y, ']', brk_fg, bg);
}

/* Match file extension against filter like "*.HDF;*.IMG;*.*" */
static int match_ext_filter(const char* fname, const char* filter) {
    if (!filter || !*filter || tv_strcasecmp(filter, "*.*") == 0 || tv_strcasecmp(filter, "*") == 0) return 1;
    int flen = tv_slen(fname);
    const char* dot = 0;
    for (int i = flen - 1; i >= 0; i--) {
        if (fname[i] == '.') { dot = &fname[i]; break; }
        if (fname[i] == '/' || fname[i] == '\\') break;
    }
    if (!dot) return 0;
    
    char buf[16];
    const char* p = filter;
    while (*p) {
        while (*p == '*' || *p == ' ' || *p == ';') p++;
        if (!*p) break;
        int bi = 0;
        if (*p == '.') p++;
        while (*p && *p != ';' && *p != ' ' && bi < 15) {
            buf[bi++] = *p++;
        }
        buf[bi] = 0;
        if (tv_strcasecmp(dot + 1, buf) == 0) return 1;
    }
    return 0;
}

/* =================================================================================================
 * Universal Modal File / Directory Browser: tv_browse_dialog
 * =================================================================================================
 */
#define BROWSE_MAX 128
typedef struct {
    char name[48];
    uint32_t size;
    uint8_t is_dir;
} BrowseEntry;

/* =================================================================================================
 * Дерево каталогов с ЛЕНИВЫМ раскрытием (v0.15.395). Держим только то, что РАСКРЫТО: дети читаются
 * в момент нажатия «вправо». Полный путь храним у каждого узла - так вставка и удаление ветки не
 * ломают ссылки (индексы при сдвиге массива уехали бы, и это классический источник тихих дефектов).
 * ================================================================================================= */
#define TREE_MAX 512
typedef struct {
    char    name[32];
    char    full_path[96];      /* всегда со слэшем на конце */
    uint8_t depth;              /* 0 = корень 0:/ */
    uint8_t is_last;            /* последний среди своих братьев - для линий дерева */
    uint8_t expanded;
    uint8_t loaded;             /* детей уже читали */
    uint8_t haskids;            /* и они есть */
} TreeNode;

static TreeNode g_tn[TREE_MAX];
static int      g_tn_n = 0;

/* Свернуть узел: выкинуть всё, что идёт за ним с БОЛЬШЕЙ глубиной (поддерево лежит подряд). */
static void tree_collapse(int idx) {
    int d = g_tn[idx].depth, j = idx + 1;
    while (j < g_tn_n && g_tn[j].depth > d) j++;
    if (j > idx + 1) {
        for (int k = j; k < g_tn_n; k++) g_tn[idx + 1 + (k - j)] = g_tn[k];
        g_tn_n -= (j - idx - 1);
    }
    g_tn[idx].expanded = 0;
}

/* Раскрыть узел: прочитать ЕГО каталог и вставить детей сразу за ним. Возврат: 1 = что-то не влезло. */
static int tree_expand(int idx) {
    if (g_tn[idx].expanded) return 0;
    DIR dir; FILINFO fno;
    int nk = 0, cut = 0;
    if (f_opendir(&dir, g_tn[idx].full_path) == FR_OK) {          /* первый проход: сколько детей */
        while (f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
            if (fno.fname[0] == '.') continue;
            if (fno.fattrib & AM_DIR) nk++;
        }
        f_closedir(&dir);
    }
    g_tn[idx].loaded = 1;
    g_tn[idx].haskids = (nk > 0) ? 1 : 0;
    g_tn[idx].expanded = 1;
    if (nk == 0) return 0;
    if (g_tn_n + nk > TREE_MAX) { nk = TREE_MAX - g_tn_n; cut = 1; }   /* предел не молчит */
    if (nk <= 0) return 1;

    for (int k = g_tn_n - 1; k > idx; k--) g_tn[k + nk] = g_tn[k];     /* раздвинуть хвост */
    g_tn_n += nk;

    int w = idx + 1, put = 0;
    if (f_opendir(&dir, g_tn[idx].full_path) == FR_OK) {          /* второй проход: заполнить */
        while (put < nk && f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
            if (fno.fname[0] == '.') continue;
            if (!(fno.fattrib & AM_DIR)) continue;
            TreeNode* t = &g_tn[w + put];
            int j = 0;
            while (fno.fname[j] && j < (int)sizeof(t->name) - 1) { t->name[j] = fno.fname[j]; j++; }
            t->name[j] = 0;
            int c = 0;
            while (g_tn[idx].full_path[c] && c < (int)sizeof(t->full_path) - 2) { t->full_path[c] = g_tn[idx].full_path[c]; c++; }
            for (int q = 0; t->name[q] && c < (int)sizeof(t->full_path) - 2; q++) t->full_path[c++] = t->name[q];
            t->full_path[c++] = '/'; t->full_path[c] = 0;
            t->depth = (uint8_t)(g_tn[idx].depth + 1);
            t->is_last = 0; t->expanded = 0; t->loaded = 0; t->haskids = 0;
            put++;
        }
        f_closedir(&dir);
    }
    /* по алфавиту и метка последнего - линии дерева рисуются по ней */
    for (int i = 0; i < put - 1; i++)
        for (int j = i + 1; j < put; j++)
            if (tv_strcasecmp(g_tn[w + i].name, g_tn[w + j].name) > 0) {
                TreeNode tmp = g_tn[w + i]; g_tn[w + i] = g_tn[w + j]; g_tn[w + j] = tmp; }
    if (put > 0) g_tn[w + put - 1].is_last = 1;
    return cut;
}

/* Индекс родителя: ближайший предыдущий узел с меньшей глубиной. -1 у корня. */
static int tree_parent(int idx) {
    for (int i = idx - 1; i >= 0; i--) if (g_tn[i].depth < g_tn[idx].depth) return i;
    return -1;
}

int tv_browse_dialog(char* out_path, int maxlen, int mode, const char* ext_filter) {
    if (!out_path || maxlen <= 0) return 0;
    
    const int W = 58, H = 18;
    const int left = (DN_COLS - W) / 2;
    const int top  = (DN_ROWS - H) / 2;
    const int list_y = top + 3;
    const int list_h = 10;
    const int brow   = top + 15;
    
    g_modal_level++;
    box_push(left, top, W + 2, H + 1);
    
    int result = -1;
    int cursor = 0, top_row = 0;
    int focus_btn = -1;
    
    if (mode == TV_BROWSE_DIR) {
        /* 🥇 v0.15.395 ДЕРЕВО С ЛЕНИВЫМ РАСКРЫТИЕМ. Было: рекурсивный скан ВСЕЙ карты в массив на
           128 записей плюс окно ожидания и кэш - сканер молча упирался в предел, и снаружи это
           выглядело как «дерево не дорисовывается до конца». Стало: вправо раскрывает ветку и
           ТОЛЬКО ТОГДА читает её каталог, влево сворачивает. Пределы не молчат. */
        int cut_warn = 0;
        g_tn_n = 1;
        g_tn[0].name[0]='0'; g_tn[0].name[1]=':'; g_tn[0].name[2]='/'; g_tn[0].name[3]=0;
        g_tn[0].full_path[0]='0'; g_tn[0].full_path[1]=':'; g_tn[0].full_path[2]='/'; g_tn[0].full_path[3]=0;
        g_tn[0].depth = 0; g_tn[0].is_last = 1; g_tn[0].expanded = 0; g_tn[0].loaded = 0; g_tn[0].haskids = 0;
        cut_warn |= tree_expand(0);                     /* корень раскрыт сразу - иначе окно пустое */

        /* Если пришли с готовым путём - раскрываем ветку до него и встаём на неё. */
        if (out_path[0] == '0' && out_path[1] == ':') {
            for (int guard = 0; guard < 16; guard++) {
                int best = -1;
                for (int i = 0; i < g_tn_n; i++) {
                    int L = tv_slen(g_tn[i].full_path);
                    int match = 1;
                    for (int c = 0; c < L; c++) {
                        char a = g_tn[i].full_path[c], b = out_path[c];
                        if (a >= 'a' && a <= 'z') a = (char)(a - 32);
                        if (b >= 'a' && b <= 'z') b = (char)(b - 32);
                        if (a != b) { match = 0; break; }
                    }
                    if (match && (best < 0 || L > tv_slen(g_tn[best].full_path))) best = i;
                }
                if (best < 0) break;
                cursor = best;
                if (tv_strcasecmp(g_tn[best].full_path, out_path) == 0) break;
                if (g_tn[best].expanded) break;
                cut_warn |= tree_expand(best);
            }
        }

        while (result < 0) {
            if (cursor >= g_tn_n) cursor = g_tn_n - 1;
            if (cursor < 0) cursor = 0;
            if (cursor < top_row) top_row = cursor;
            if (cursor >= top_row + list_h) top_row = cursor - list_h + 1;
            if (top_row < 0) top_row = 0;

            dn_win_draw(left, top, W, H, "Select Folder");
            dn_fill(left + 2, top + 1, W - 4, 1, DNK_DLG_BG);
            dn_putsn_ell(left + 2, top + 1, g_tn[cursor].full_path, W - 4, DNK_HEADER, DNK_DLG_BG);

            dn_fill(left + 2, list_y, W - 4, list_h, DNK_PANEL_BG);
            for (int r = 0; r < list_h; r++) {
                int idx = top_row + r, y = list_y + r;
                if (idx >= g_tn_n) break;
                int sel = (idx == cursor), act = (focus_btn == -1 && sel);
                uint32_t bg = act ? DNK_CUR_BG : (sel ? DNK_DLG_BG : DNK_PANEL_BG);
                uint32_t fg = (act || sel) ? DNK_CUR_FG : DNK_DIR;
                uint32_t ln = (act || sel) ? DNK_CUR_FG : DNK_SEP;
                dn_fill(left + 2, y, W - 4, 1, bg);
                int cx = left + 3;
                if (g_tn[idx].depth == 0) {
                    dn_puts(cx, y, g_tn[idx].expanded ? "- 0:/" : "+ 0:/", fg, bg);
                } else {
                    /* вертикальные линии предков: рисуем там, где у предка есть братья ниже */
                    for (int d = 1; d < g_tn[idx].depth; d++) {
                        int anc = -1;
                        for (int i = idx - 1; i >= 0; i--) if (g_tn[i].depth == d) { anc = i; break; }
                        if (anc >= 0 && !g_tn[anc].is_last) { dn_putc(cx, y, 0xB3, ln, bg); dn_puts(cx + 1, y, "  ", fg, bg); }
                        else                                  dn_puts(cx, y, "   ", fg, bg);
                        cx += 3;
                    }
                    dn_putc(cx, y, g_tn[idx].is_last ? 0xC0 : 0xC3, ln, bg);
                    dn_putc(cx + 1, y, 0xC4, ln, bg);
                    cx += 2;
                    /* признак ветки: + свернута, - раскрыта, пробел = детей нет (уже смотрели) */
                    char mark = g_tn[idx].expanded ? '-' : (g_tn[idx].loaded && !g_tn[idx].haskids ? ' ' : '+');
                    dn_putc(cx, y, mark, fg, bg);
                    cx += 2;
                    dn_putsn(cx, y, g_tn[idx].name, (left + W - 3) - cx, fg, bg);
                }
            }
            if (cut_warn) {
                dn_putsn(left + 2, list_y + list_h, "> tree limit reached - some branches not shown",
                         W - 4, DNK_SNAP, DNK_DLG_BG);
            }

            dn_fill(left + 1, brow, W - 2, 2, DNK_DLG_BG);
            {   int bw1 = 10, bw2 = 10, gap = 2;
                int total = (bw1 + 1) + (bw2 + 1) + gap;
                int bx = left + (W - total) / 2;
                dn_button(bx, brow, "Choose", focus_btn == 0, bw1);
                dn_button(bx + (bw1 + 1 + gap), brow, "Cancel", focus_btn == 1, bw2);
            }
            { static const char* const kb[4][2] = {{"Right","Expand"},{"Left","Collapse"},{"Enter","Choose"},{"Esc","Cancel"}}; dn_keybar(kb, 4); }

            int k = get_keysym_blocking();
            if (k == K_ESC) { result = 0; break; }
            if (k == K_TAB) { focus_btn = (focus_btn >= 1) ? -1 : focus_btn + 1; continue; }
            if (focus_btn >= 0) {
                if (k == K_LEFT || k == K_RIGHT) { focus_btn = focus_btn ? 0 : 1; continue; }
                if (k == K_UP) { focus_btn = -1; continue; }
                if (k == K_ENTER || k == K_SPACE) {
                    if (focus_btn == 1) { result = 0; break; }
                    int ci = 0;
                    while (g_tn[cursor].full_path[ci] && ci < maxlen - 1) { out_path[ci] = g_tn[cursor].full_path[ci]; ci++; }
                    out_path[ci] = 0; result = 1; break;
                }
                continue;
            }
            if (k == K_UP)    { if (cursor > 0) cursor--; continue; }
            if (k == K_DOWN)  { if (cursor < g_tn_n - 1) cursor++; else focus_btn = 0; continue; }
            if (k == K_PGUP)  { cursor -= list_h; if (cursor < 0) cursor = 0; continue; }
            if (k == K_PGDN)  { cursor += list_h; if (cursor >= g_tn_n) cursor = g_tn_n - 1; continue; }
            if (k == K_HOME)  { cursor = 0; continue; }
            if (k == K_END)   { cursor = g_tn_n - 1; continue; }
            if (k == K_RIGHT) {                       /* раскрыть ветку; если уже раскрыта - к первому ребёнку */
                if (!g_tn[cursor].expanded) { cut_warn |= tree_expand(cursor); }
                else if (cursor + 1 < g_tn_n && g_tn[cursor + 1].depth > g_tn[cursor].depth) cursor++;
                continue;
            }
            if (k == K_LEFT) {                        /* свернуть; если уже свёрнута - к родителю */
                if (g_tn[cursor].expanded) tree_collapse(cursor);
                else { int p = tree_parent(cursor); if (p >= 0) cursor = p; }
                continue;
            }
            if (k == K_ENTER || k == K_SPACE) {
                int ci = 0;
                while (g_tn[cursor].full_path[ci] && ci < maxlen - 1) { out_path[ci] = g_tn[cursor].full_path[ci]; ci++; }
                out_path[ci] = 0; result = 1; break;
            }
        }
    } else {
        /* FILE SELECTOR BROWSER */
        char cur_dir[128];
        int cl = 0;
        
        if (out_path[0] == '0' && out_path[1] == ':') {
            for (int i = 0; out_path[i] && i < (int)sizeof(cur_dir) - 1; i++) {
                cur_dir[i] = out_path[i]; cl = i + 1;
            }
            cur_dir[cl] = 0;
            int last_slash = -1;
            for (int i = 0; i < cl; i++) if (cur_dir[i] == '/') last_slash = i;
            if (last_slash >= 2) { cur_dir[last_slash + 1] = 0; cl = last_slash + 1; }
            else { cur_dir[0]='0'; cur_dir[1]=':'; cur_dir[2]='/'; cur_dir[3]=0; cl=3; }
        } else {
            cur_dir[0]='0'; cur_dir[1]=':'; cur_dir[2]='/'; cur_dir[3]=0; cl=3;
        }

        BrowseEntry items[BROWSE_MAX];
        int n_items = 0;
        int need_scan = 1;
        
        while (result < 0) {
            if (need_scan) {
                need_scan = 0;
                n_items = 0;
                cursor = 0;
                top_row = 0;
                
                if (tv_slen(cur_dir) > 3) {
                    items[0].name[0] = '.'; items[0].name[1] = '.'; items[0].name[2] = 0;
                    items[0].size = 0; items[0].is_dir = 1; n_items = 1;
                }
                
                DIR dir;
                FILINFO fno;
                if (f_opendir(&dir, cur_dir) == FR_OK) {
                    while (n_items < BROWSE_MAX && f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
                        if (fno.fname[0] == '.') continue;
                        if (fno.fattrib & AM_DIR) {
                            int j = 0;
                            while (fno.fname[j] && j < (int)sizeof(items[0].name) - 1) {
                                items[n_items].name[j] = fno.fname[j]; j++;
                            }
                            items[n_items].name[j] = 0;
                            items[n_items].size = 0;
                            items[n_items].is_dir = 1;
                            n_items++;
                        }
                    }
                    f_closedir(&dir);
                    
                    if (f_opendir(&dir, cur_dir) == FR_OK) {
                        while (n_items < BROWSE_MAX && f_readdir(&dir, &fno) == FR_OK && fno.fname[0]) {
                            if (fno.fname[0] == '.') continue;
                            if (!(fno.fattrib & AM_DIR) && match_ext_filter(fno.fname, ext_filter)) {
                                int j = 0;
                                while (fno.fname[j] && j < (int)sizeof(items[0].name) - 1) {
                                    items[n_items].name[j] = fno.fname[j]; j++;
                                }
                                items[n_items].name[j] = 0;
                                items[n_items].size = (uint32_t)fno.fsize;
                                items[n_items].is_dir = 0;
                                n_items++;
                            }
                        }
                        f_closedir(&dir);
                    }
                }
                
                /* Sort items: folders first (A-Z), then files (A-Z) */
                int start_i = (n_items > 0 && items[0].name[0] == '.' && items[0].name[1] == '.') ? 1 : 0;
                for (int i = start_i; i < n_items - 1; i++) {
                    for (int j = i + 1; j < n_items; j++) {
                        int swap = 0;
                        if (items[i].is_dir && !items[j].is_dir) {
                            swap = 0;
                        } else if (!items[i].is_dir && items[j].is_dir) {
                            swap = 1;
                        } else {
                            if (tv_strcasecmp(items[i].name, items[j].name) > 0) swap = 1;
                        }
                        if (swap) {
                            BrowseEntry tmp = items[i];
                            items[i] = items[j];
                            items[j] = tmp;
                        }
                    }
                }
            }
            
            if (cursor < top_row) top_row = cursor;
            if (cursor >= top_row + list_h) top_row = cursor - list_h + 1;
            if (top_row < 0) top_row = 0;
            
            dn_win_draw(left, top, W, H, "Select File");
            
            dn_fill(left + 2, top + 1, W - 4, 1, DNK_DLG_BG);
            dn_putsn(left + 2, top + 1, cur_dir, W - 4, DNK_HEADER, DNK_DLG_BG);
            
            dn_fill(left + 2, list_y, W - 4, list_h, DNK_PANEL_BG);
            
            for (int r = 0; r < list_h; r++) {
                int idx = top_row + r;
                int y = list_y + r;
                if (idx < n_items) {
                    int is_selected = (idx == cursor);
                    int is_active = (focus_btn == -1 && is_selected);
                    
                    uint32_t bg = is_active ? DNK_CUR_BG : (is_selected ? DNK_DLG_BG : DNK_PANEL_BG);
                    uint32_t fg = is_active ? DNK_CUR_FG : (is_selected ? DNK_CUR_FG : (items[idx].is_dir ? DNK_HEADER : DNK_FILE));
                    
                    dn_fill(left + 2, y, W - 4, 1, bg);
                    if (items[idx].is_dir) {
                        if (items[idx].name[0] == '.' && items[idx].name[1] == '.') {
                            dn_putc(left + 3, y, 0x11, (is_active || is_selected) ? DNK_CUR_FG : DNK_HOTKEY, bg);
                            dn_puts(left + 5, y, "..", fg, bg);
                        } else {
                            dn_putc(left + 3, y, 0x10, (is_active || is_selected) ? DNK_CUR_FG : DNK_HOTKEY, bg);
                            dn_putsn(left + 5, y, items[idx].name, W - 18, fg, bg);
                            dn_puts(left + 5 + tv_slen(items[idx].name), y, "/", (is_active || is_selected) ? DNK_CUR_FG : DNK_HOTKEY, bg);
                        }
                    } else {
                        dn_puts(left + 3, y, "  ", fg, bg);
                        dn_putsn(left + 5, y, items[idx].name, W - 18, fg, bg);
                        
                        char szb[12];
                        int sz = items[idx].size;
                        if (sz >= 1024 * 1024) {
                            itoa_u(sz / (1024 * 1024), szb);
                            int p = tv_slen(szb); szb[p++] = 'M'; szb[p] = 0;
                        } else if (sz >= 1024) {
                            itoa_u(sz / 1024, szb);
                            int p = tv_slen(szb); szb[p++] = 'K'; szb[p] = 0;
                        } else {
                            itoa_u(sz, szb);
                        }
                        dn_puts(left + W - 3 - tv_slen(szb), y, szb, (is_active || is_selected) ? DNK_CUR_FG : FG(8), bg);
                    }
                }
            }
            
            dn_fill(left + 1, brow, W - 2, 2, DNK_DLG_BG);
            int bw = 10, gap = 4, total = 2 * (bw + 1) + gap;
            int bx = left + (W - total) / 2;
            dn_button(bx, brow, "Choose", focus_btn == 0, bw);
            dn_button(bx + bw + 1 + gap, brow, "Cancel", focus_btn == 1, bw);
            
            { static const char* const kb[4][2] = {{"Enter","Open/Select"},{"Tab","Buttons"},{"BkSp","Up dir"},{"Esc","Cancel"}}; dn_keybar(kb, 4); }
            
            int k = get_keysym_blocking();
            if (k == K_ESC) { result = 0; break; }
            if (k == K_TAB) {
                if (focus_btn == -1) focus_btn = 0;
                else if (focus_btn == 0) focus_btn = 1;
                else focus_btn = -1;
                continue;
            }
            if (focus_btn >= 0) {
                if (k == K_LEFT || k == K_RIGHT) { focus_btn = !focus_btn; continue; }
                if (k == K_UP) { focus_btn = -1; continue; }
                if (k == K_ENTER || k == K_SPACE) {
                    if (focus_btn == 1) { result = 0; break; }
                    if (n_items > 0 && !items[cursor].is_dir) {
                        int ci = 0;
                        while (cur_dir[ci] && ci < maxlen - 1) { out_path[ci] = cur_dir[ci]; ci++; }
                        if (ci > 0 && out_path[ci - 1] != '/' && ci < maxlen - 1) out_path[ci++] = '/';
                        int fi = 0;
                        while (items[cursor].name[fi] && ci < maxlen - 1) { out_path[ci++] = items[cursor].name[fi++]; }
                        out_path[ci] = 0;
                        result = 1;
                        break;
                    }
                }
                continue;
            }
            
            if (k == K_UP) { if (cursor > 0) cursor--; continue; }
            if (k == K_DOWN) {
                if (cursor < n_items - 1) cursor++;
                else focus_btn = 0;
                continue;
            }
            if (k == K_PGUP) { cursor -= list_h; if (cursor < 0) cursor = 0; continue; }
            if (k == K_PGDN) { cursor += list_h; if (cursor >= n_items) cursor = (n_items > 0) ? n_items - 1 : 0; continue; }
            if (k == K_HOME) { cursor = 0; continue; }
            if (k == K_END)  { cursor = (n_items > 0) ? n_items - 1 : 0; continue; }
            if (k == K_BACK) {
                int clen = tv_slen(cur_dir);
                if (clen > 3) {
                    if (cur_dir[clen - 1] == '/') cur_dir[--clen] = 0;
                    while (clen > 3 && cur_dir[clen - 1] != '/') clen--;
                    cur_dir[clen] = 0;
                    need_scan = 1;
                }
                continue;
            }
            if (k == K_ENTER) {
                if (n_items > 0) {
                    if (items[cursor].is_dir) {
                        if (items[cursor].name[0] == '.' && items[cursor].name[1] == '.') {
                            int clen = tv_slen(cur_dir);
                            if (clen > 3) {
                                if (cur_dir[clen - 1] == '/') cur_dir[--clen] = 0;
                                while (clen > 3 && cur_dir[clen - 1] != '/') clen--;
                                cur_dir[clen] = 0;
                                need_scan = 1;
                            }
                        } else {
                            int clen = tv_slen(cur_dir);
                            if (clen > 0 && cur_dir[clen - 1] != '/' && clen < (int)sizeof(cur_dir) - 2) {
                                cur_dir[clen++] = '/';
                            }
                            int ni = 0;
                            while (items[cursor].name[ni] && clen < (int)sizeof(cur_dir) - 2) {
                                cur_dir[clen++] = items[cursor].name[ni++];
                            }
                            cur_dir[clen++] = '/';
                            cur_dir[clen] = 0;
                            need_scan = 1;
                        }
                    } else {
                        int ci = 0;
                        while (cur_dir[ci] && ci < maxlen - 1) { out_path[ci] = cur_dir[ci]; ci++; }
                        if (ci > 0 && out_path[ci - 1] != '/' && ci < maxlen - 1) out_path[ci++] = '/';
                        int fi = 0;
                        while (items[cursor].name[fi] && ci < maxlen - 1) { out_path[ci++] = items[cursor].name[fi++]; }
                        out_path[ci] = 0;
                        result = 1;
                        break;
                    }
                }
            }
        }
    }
    
    box_pop();
    g_modal_level--;
    dn_keybar_browser();
    /* v0.15.415: навигатор перерисовываем ТОЛЬКО когда меню не открыто. Фон под окном уже вернул
       стек (v0.15.401); лишняя перерисовка стирала открытое меню, а меню считало себя целым -
       отсюда обрывок его строки, оставшийся на списке файлов (артефакт, замеченный владельцем). */
    if(!g_menu_open) render_browser();
    
    return result;
}

/* =================================================================================================
 * Turbo Vision Dialog Core Implementation
 * =================================================================================================
 */
void tv_dialog_init(TV_Dialog* d, const char* title, int w, int h) {
    if (!d) return;
    if (w < 20) w = 20;
    if (w > DN_COLS - 2) w = DN_COLS - 2;
    if (h < 6)  h = 6;
    if (h > DN_ROWS - 2) h = DN_ROWS - 2;

    d->title = title;
    d->W = w;
    d->H = h;
    d->left = (DN_COLS - w) / 2;
    d->top  = (DN_ROWS - h) / 2;
    d->brow = d->top + h - 3;
    d->slot = 0;
    d->widget_count = 0;
    d->btn_count = 0;
    d->focus_idx = 0;
    d->focusable_count = 0;
    d->default_res = TV_RES_OK;
    d->cancel_res = TV_RES_CANCEL;
    d->refresh = 0;                     /* v384: пересчёт производного текста; 0 = как было */
    d->on_cmd = 0;

    for (int i = 0; i < TV_MAX_WIDGETS; i++) {
        d->widgets[i].type = TV_W_NONE;
    }
}

void tv_dialog_add_label(TV_Dialog* d, int x, int y, const char* text, uint32_t fg) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS) return;
    TV_Widget* w = &d->widgets[d->widget_count++];
    w->type = TV_W_LABEL;
    w->x = x;
    w->y = y;
    w->label = text;
    w->custom_fg = fg;
    w->disabled = 0;
}

void tv_dialog_add_check(TV_Dialog* d, int x, int y, const char* text, int* val_ptr) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS) return;
    int idx = d->widget_count++;
    TV_Widget* w = &d->widgets[idx];
    w->type = TV_W_CHECK;
    w->x = x;
    w->y = y;
    w->label = text;
    w->val_ptr = val_ptr;
    w->disabled = 0;
    d->focusable_map[d->focusable_count++] = idx;
}

void tv_dialog_add_radio(TV_Dialog* d, int x, int y, const char* text, int group_id, int item_id, int* val_ptr) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS) return;
    int idx = d->widget_count++;
    TV_Widget* w = &d->widgets[idx];
    w->type = TV_W_RADIO;
    w->x = x;
    w->y = y;
    w->label = text;
    w->group_id = group_id;
    w->item_id = item_id;
    w->val_ptr = val_ptr;
    w->disabled = 0;
    d->focusable_map[d->focusable_count++] = idx;
}

void tv_dialog_add_input(TV_Dialog* d, int x, int y, int fw, char* buf, int maxlen) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS) return;
    int idx = d->widget_count++;
    TV_Widget* w = &d->widgets[idx];
    w->type = TV_W_INPUT;
    w->x = x;
    w->y = y;
    w->w = fw;
    w->str_buf = buf;
    w->str_maxlen = maxlen;
    w->cursor = tv_slen(buf);
    w->scroll = 0;
    w->disabled = 0;
    d->focusable_map[d->focusable_count++] = idx;
}

void tv_dialog_add_input_browse(TV_Dialog* d, int x, int y, int fw, char* buf, int maxlen, int browse_mode, const char* ext_filter) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS - 1) return;
    
    int input_w = fw - 4;
    if (input_w < 10) input_w = 10;
    
    int input_idx = d->widget_count++;
    TV_Widget* w_in = &d->widgets[input_idx];
    w_in->type = TV_W_INPUT;
    w_in->x = x;
    w_in->y = y;
    w_in->w = input_w;
    w_in->str_buf = buf;
    w_in->str_maxlen = maxlen;
    w_in->cursor = tv_slen(buf);
    w_in->scroll = 0;
    w_in->disabled = 0;
    d->focusable_map[d->focusable_count++] = input_idx;
    
    int btn_idx = d->widget_count++;
    TV_Widget* w_btn = &d->widgets[btn_idx];
    w_btn->type = TV_W_BROWSE_BTN;
    w_btn->x = x + input_w + 1;
    w_btn->y = y;
    w_btn->w = 3;
    w_btn->label = "\x1F";
    w_btn->target_input_idx = input_idx;
    w_btn->browse_mode = browse_mode;
    w_btn->ext_filter = ext_filter;
    w_btn->disabled = 0;
    d->focusable_map[d->focusable_count++] = btn_idx;
}

void tv_dialog_add_cmd(TV_Dialog* d, int x, int y, const char* label, int cmd_id) {
    if (!d || d->widget_count >= TV_MAX_WIDGETS) return;
    int idx = d->widget_count++;
    TV_Widget* w = &d->widgets[idx];
    w->type = TV_W_CMD;
    w->x = x;
    w->y = y;
    w->label = label ? label : "Eject";
    w->item_id = cmd_id;
    w->w = tv_slen(w->label) + 2;       /* [label] */
    w->disabled = 0;
    d->focusable_map[d->focusable_count++] = idx;
}

void tv_dialog_add_button(TV_Dialog* d, const char* label, int result_code) {
    if (!d || d->btn_count >= TV_MAX_BUTTONS) return;
    int bi = d->btn_count++;
    d->btn_labels[bi] = label;
    d->btn_results[bi] = result_code;
    d->focusable_map[d->focusable_count++] = 100 + bi;
}

static void tv_draw_buttons(TV_Dialog* d, int focused_btn) {
    if (d->btn_count <= 0) return;
    
    int min_w = (d->btn_count >= 3) ? 8 : 10;
    int total_w = 0;
    int gap = (d->btn_count >= 3) ? 2 : 4;
    
    for (int i = 0; i < d->btn_count; i++) {
        int len = tv_slen(d->btn_labels[i]);
        int face = len + 4;
        if (face < min_w) face = min_w;
        d->btn_w[i] = face + 1;
        total_w += d->btn_w[i];
        if (i > 0) total_w += gap;
    }
    
    int bx = d->left + (d->W - total_w) / 2;
    if (bx < d->left + 1) bx = d->left + 1;
    
    dn_fill(d->left + 1, d->brow, d->W - 2, 2, DNK_DLG_BG);
    for (int i = 0; i < d->btn_count; i++) {
        d->btn_x[i] = bx;
        dn_button(bx, d->brow, d->btn_labels[i], (i == focused_btn), d->btn_w[i] - 1);
        bx += d->btn_w[i] + gap;
    }
}

void tv_dialog_draw(TV_Dialog* d) {
    if (!d) return;
    if (d->refresh) d->refresh();       /* v384: подписи, зависящие от значений, - до отрисовки */
    clip_push_full();
    dn_win_draw(d->left, d->top, d->W, d->H, d->title);
    
    int cur_foc_map = (d->focusable_count > 0 && d->focus_idx < d->focusable_count) 
                      ? d->focusable_map[d->focus_idx] : -1;
    int focused_btn = (cur_foc_map >= 100) ? (cur_foc_map - 100) : -1;
    
    for (int i = 0; i < d->widget_count; i++) {
        TV_Widget* w = &d->widgets[i];
        int is_foc = (cur_foc_map == i);
        int wx = d->left + w->x;
        int wy = d->top + w->y;
        
        switch (w->type) {
            case TV_W_LABEL:
                dn_puts(wx, wy, w->label, w->custom_fg ? w->custom_fg : DNK_DLG_FG, DNK_DLG_BG);
                break;
            case TV_W_CHECK:
                dn_check(wx, wy, w->label, (w->val_ptr ? *w->val_ptr : 0), is_foc, w->disabled);
                break;
            case TV_W_RADIO:
                dn_radio(wx, wy, w->label, (w->val_ptr && *w->val_ptr == w->item_id), is_foc, w->disabled);
                break;
            case TV_W_INPUT:
                if (w->str_buf) {
                    int len = tv_slen(w->str_buf);
                    int fw = w->w;
                    int foff = w->scroll;
                    if (w->cursor < foff) foff = w->cursor;
                    if (w->cursor >= foff + fw) foff = w->cursor - fw + 1;
                    if (foff < 0) foff = 0;
                    w->scroll = foff;
                    
                    for (int fi = 0; fi < fw; fi++) {
                        int idx = foff + fi;
                        unsigned char ch = (idx < len) ? (unsigned char)w->str_buf[idx] : ' ';
                        int is_cur = is_foc && (idx == w->cursor);
                        dn_putc(wx + fi, wy, ch, is_cur ? DNK_FLD_BG : DNK_FLD_FG, is_cur ? DNK_FLD_FG : DNK_FLD_BG);
                    }
                }
                break;
            case TV_W_BROWSE_BTN:
                dn_picker_btn(wx, wy, is_foc);
                break;
            case TV_W_CMD: {
                const char* lab = w->label ? w->label : "Eject";
                int n = tv_slen(lab);
                uint32_t bg = is_foc ? DNK_CUR_BG : DNK_BTN_FACE;
                uint32_t fg = is_foc ? DNK_CUR_FG : DNK_BTN_TXT;
                dn_putc(wx, wy, '[', fg, bg);
                dn_puts(wx + 1, wy, lab, fg, bg);
                dn_putc(wx + 1 + n, wy, ']', fg, bg);
                break;
            }
            default:
                break;
        }
    }
    
    tv_draw_buttons(d, focused_btn);
}

/* 🥇 v0.15.403 СЕКЦИЯ ОКНА - ЕДИНИЦА ОБХОДА ПО TAB (см. шапку правки).
   Раньше здесь каждая галочка и каждое поле ввода объявлялись ОТДЕЛЬНОЙ группой, поэтому Tab шёл
   по элементам поштучно - жалоба владельца «таб проходит по каждому элементу, а не прыгает по
   группам». Теперь номер секции считается по РАЗМЕТКЕ окна, и диалогам не нужно ничего объявлять:
   подпись-заголовок между элементами начинает новую секцию, смена типа элемента - тоже, другая
   радиогруппа - тоже, кнопки окна - всегда последняя.
   Так работает и TurboVision (кластер = одна остановка), и современные движки (ARIA composite
   widget с roving tabindex, Win32 WS_GROUP). */
static int tv_section_of(TV_Dialog* d, int foc_idx) {
    if (!d || foc_idx < 0 || foc_idx >= d->focusable_count) return -1;
    int sect = 0;
    for (int f = 1; f <= foc_idx; f++) {
        int a = d->focusable_map[f - 1], b = d->focusable_map[f];
        if (b >= 100) {                       /* кнопки - всегда своя, последняя секция */
            if (a < 100) sect++;
            continue;
        }
        TV_Widget* wa = &d->widgets[a];
        TV_Widget* wb = &d->widgets[b];
        int brk = 0;
        /* Заголовок секции (DNK_HEADER) между элементами - граница Tab.
           Подписи полей вроде "A:" / "B:" - не заголовки: четыре привода BDI
           это ОДНА секция, стрелки ходят по буквам, Tab уходит на галочку. */
        for (int i = a + 1; i < b; i++) {
            if (d->widgets[i].type == TV_W_LABEL && d->widgets[i].custom_fg == DNK_HEADER) {
                brk = 1; break;
            }
        }
        /* ввод и его кнопка выбора файла - один смысл, остальная смена типа разделяет */
        int ka = (wa->type == TV_W_BROWSE_BTN || wa->type == TV_W_CMD) ? TV_W_INPUT : wa->type;
        int kb = (wb->type == TV_W_BROWSE_BTN || wb->type == TV_W_CMD) ? TV_W_INPUT : wb->type;
        if (ka != kb) brk = 1;
        if (ka == TV_W_RADIO && kb == TV_W_RADIO && wa->group_id != wb->group_id) brk = 1;
        if (brk) sect++;
    }
    return sect;
}
static int tv_get_group_id(TV_Dialog* d, int foc_idx) { return tv_section_of(d, foc_idx); }

/* v0.15.403 Куда ВСТАВАТЬ, попав в секцию: у радиогруппы - на ВЫБРАННУЮ кнопку (так делают Win32
   и Qt: остановка табуляции у группы одна, и это текущий выбор), у остальных - на первый элемент. */
static int tv_section_entry(TV_Dialog* d, int any_idx) {
    int sect = tv_section_of(d, any_idx), first = any_idx;
    while (first > 0 && tv_section_of(d, first - 1) == sect) first--;
    int fm = d->focusable_map[first];
    if (fm < 100 && d->widgets[fm].type == TV_W_RADIO) {
        for (int f = first; f < d->focusable_count && tv_section_of(d, f) == sect; f++) {
            int m = d->focusable_map[f];
            if (m < 100 && d->widgets[m].val_ptr && *d->widgets[m].val_ptr == d->widgets[m].item_id) return f;
        }
    }
    return first;
}
int tv_dialog_exec(TV_Dialog* d) {
    if (!d) return TV_RES_CANCEL;
    
    g_modal_level++;
    box_push(d->left, d->top, d->W + 2, d->H + 1);
    
    { static const char* const kb[5][2] = {{"Tab","Section"},{"Arrows","Item"},{"Space","Toggle"},
                                          {"Enter","OK"},{"Esc","Cancel"}}; dn_keybar(kb, 5); }
    
    tv_dialog_draw(d);
    
    int result = -999;
    while (result == -999) {
        int k = get_keysym_blocking();
        if (k == K_ESC) {
            result = d->cancel_res;
            break;
        }
        
        int cur_foc_map = (d->focusable_count > 0 && d->focus_idx < d->focusable_count) 
                          ? d->focusable_map[d->focus_idx] : -1;
        
        /* 🥇 v0.15.403 ОБЩИЕ КЛАВИШИ ОКНА - до разбора элементов, чтобы вести себя ОДИНАКОВО везде.
           `Enter` = кнопка по умолчанию из любого места (TurboVision, Win32): это и есть «быстро
           выйти на кнопку», ради которого владелец просил правку - табом можно вообще не ходить.
           `End` = сразу на кнопки, `Home` = в начало окна. Переключает элемент ТОЛЬКО пробел -
           раньше Enter на галочке переключал, а на радиокнопке закрывал окно, то есть одна клавиша
           делала три разных дела. */
        /* v0.15.413: КНОПКА под фокусом нажимается сама - и кнопка окна, и кнопка выбора файла.
           Правило «Enter = кнопка по умолчанию» действует только когда фокус НЕ на кнопке (так и в
           TurboVision). Иначе Enter на кнопке выбора файла применял окно вместо открытия дерева. */
        int foc_is_button = (cur_foc_map >= 100) ||
                            (cur_foc_map >= 0 && cur_foc_map < d->widget_count &&
                             (d->widgets[cur_foc_map].type == TV_W_BROWSE_BTN ||
                              d->widgets[cur_foc_map].type == TV_W_CMD));
        if (k == K_ENTER && !foc_is_button) {
            if (d->default_res != TV_RES_CANCEL || d->btn_count == 0) { result = d->default_res; break; }
        }
        if (k == K_END && d->btn_count > 0) {
            for (int f = 0; f < d->focusable_count; f++)
                if (d->focusable_map[f] >= 100) { d->focus_idx = f; break; }
            tv_dialog_draw(d);
            continue;
        }
        if (k == K_HOME) { d->focus_idx = 0; tv_dialog_draw(d); continue; }
        /* Tab / Shift+Tab: Jump between logical groups */
        if (k == K_TAB) {
            if (d->focusable_count > 0) {
                int cur_grp = tv_get_group_id(d, d->focus_idx);
                if (!g_kb_shift) {
                    int next_idx = d->focus_idx;
                    for (int step = 0; step < d->focusable_count; step++) {
                        next_idx = (next_idx + 1) % d->focusable_count;
                        if (tv_get_group_id(d, next_idx) != cur_grp) {
                            d->focus_idx = tv_section_entry(d, next_idx);
                            break;
                        }
                    }
                } else {
                    int prev_idx = d->focus_idx;
                    for (int step = 0; step < d->focusable_count; step++) {
                        prev_idx = (prev_idx + d->focusable_count - 1) % d->focusable_count;
                        int grp = tv_get_group_id(d, prev_idx);
                        if (grp != cur_grp) {
                            while (prev_idx > 0 && tv_get_group_id(d, prev_idx - 1) == grp) {
                                prev_idx--;
                            }
                            d->focus_idx = tv_section_entry(d, prev_idx);
                            break;
                        }
                    }
                }
                tv_dialog_draw(d);
            }
            continue;
        }
        
        if (cur_foc_map >= 100) {
            int bi = cur_foc_map - 100;
            if (k == K_LEFT) {
                if (bi > 0) {
                    for (int f = 0; f < d->focusable_count; f++) {
                        if (d->focusable_map[f] == 100 + (bi - 1)) { d->focus_idx = f; break; }
                    }
                    tv_dialog_draw(d);
                }
                continue;
            }
            if (k == K_RIGHT) {
                if (bi < d->btn_count - 1) {
                    for (int f = 0; f < d->focusable_count; f++) {
                        if (d->focusable_map[f] == 100 + (bi + 1)) { d->focus_idx = f; break; }
                    }
                    tv_dialog_draw(d);
                }
                continue;
            }
            if (k == K_UP) {
                int cur_grp = 3000;
                int prev_idx = d->focus_idx;
                for (int step = 0; step < d->focusable_count; step++) {
                    prev_idx = (prev_idx + d->focusable_count - 1) % d->focusable_count;
                    if (tv_get_group_id(d, prev_idx) != cur_grp) {
                        d->focus_idx = prev_idx;
                        break;
                    }
                }
                tv_dialog_draw(d);
                continue;
            }
            if (k == K_ENTER || k == K_SPACE) {
                result = d->btn_results[bi];
                break;
            }
        } else if (cur_foc_map >= 0 && cur_foc_map < d->widget_count) {
            TV_Widget* w = &d->widgets[cur_foc_map];
            if (w->type == TV_W_CHECK) {
                if (k == K_SPACE) {                     /* v0.15.403: переключает ТОЛЬКО пробел */
                    if (w->val_ptr) *w->val_ptr = !(*w->val_ptr);
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_UP || k == K_DOWN) {
                    d->focus_idx = (d->focus_idx + (k == K_UP ? d->focusable_count - 1 : 1)) % d->focusable_count;
                    tv_dialog_draw(d);
                    continue;
                }
            } else if (w->type == TV_W_RADIO) {
                if (k == K_SPACE) {
                    if (w->val_ptr) *w->val_ptr = w->item_id;
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_ENTER) {                     /* v0.15.403: выбрать И принять - как в TurboVision */
                    if (w->val_ptr) *w->val_ptr = w->item_id;
                    result = d->default_res;
                    break;
                }
                if (k == K_UP || k == K_DOWN) {
                    d->focus_idx = (d->focus_idx + (k == K_UP ? d->focusable_count - 1 : 1)) % d->focusable_count;
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_LEFT || k == K_RIGHT) {
                    int dir = (k == K_RIGHT) ? 1 : -1;
                    int cur_grp = 1000 + w->group_id;
                    int next_idx = d->focus_idx;
                    for (int step = 0; step < d->focusable_count; step++) {
                        next_idx = (next_idx + dir + d->focusable_count) % d->focusable_count;
                        if (tv_get_group_id(d, next_idx) == cur_grp) {
                            d->focus_idx = next_idx;
                            break;
                        }
                    }
                    tv_dialog_draw(d);
                    continue;
                }
            } else if (w->type == TV_W_BROWSE_BTN) {
                if (k == K_SPACE || k == K_ENTER) {
                    if (w->target_input_idx >= 0 && w->target_input_idx < d->widget_count) {
                        TV_Widget* tin = &d->widgets[w->target_input_idx];
                        if (tin->str_buf) {
                            if (tv_browse_dialog(tin->str_buf, tin->str_maxlen, w->browse_mode, w->ext_filter)) {
                                tin->cursor = tv_slen(tin->str_buf);
                            }
                            tv_dialog_draw(d);
                        }
                    }
                    continue;
                }
                if (k == K_UP || k == K_DOWN) {
                    d->focus_idx = (d->focus_idx + (k == K_UP ? d->focusable_count - 1 : 1)) % d->focusable_count;
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_LEFT) {
                    if (w->target_input_idx >= 0) {
                        for (int f = 0; f < d->focusable_count; f++) {
                            if (d->focusable_map[f] == w->target_input_idx) { d->focus_idx = f; break; }
                        }
                        tv_dialog_draw(d);
                    }
                    continue;
                }
                if (k == K_RIGHT) {
                    if (cur_foc_map + 1 < d->widget_count && d->widgets[cur_foc_map + 1].type == TV_W_CMD) {
                        for (int f = 0; f < d->focusable_count; f++) {
                            if (d->focusable_map[f] == cur_foc_map + 1) { d->focus_idx = f; break; }
                        }
                        tv_dialog_draw(d);
                    }
                    continue;
                }
            } else if (w->type == TV_W_CMD) {
                if (k == K_SPACE || k == K_ENTER) {
                    if (d->on_cmd) d->on_cmd(d, w->item_id);
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_UP || k == K_DOWN) {
                    d->focus_idx = (d->focus_idx + (k == K_UP ? d->focusable_count - 1 : 1)) % d->focusable_count;
                    tv_dialog_draw(d);
                    continue;
                }
                if (k == K_LEFT) {
                    if (d->focus_idx > 0) d->focus_idx--;
                    tv_dialog_draw(d);
                    continue;
                }
            } else if (w->type == TV_W_INPUT) {
                if (k == K_ENTER) {
                    result = d->default_res;
                    break;
                }
                if (k == K_UP || k == K_DOWN) {
                    d->focus_idx = (d->focus_idx + (k == K_UP ? d->focusable_count - 1 : 1)) % d->focusable_count;
                    tv_dialog_draw(d);
                    continue;
                }
                if (w->str_buf) {
                    int len = tv_slen(w->str_buf);
                    if (k == K_RIGHT && w->cursor >= len) {
                        if (cur_foc_map + 1 < d->widget_count && d->widgets[cur_foc_map + 1].type == TV_W_BROWSE_BTN) {
                            for (int f = 0; f < d->focusable_count; f++) {
                                if (d->focusable_map[f] == cur_foc_map + 1) { d->focus_idx = f; break; }
                            }
                            tv_dialog_draw(d);
                            continue;
                        }
                    }
                    if (k == K_LEFT) {
                        if (w->cursor > 0) { w->cursor--; tv_dialog_draw(d); }
                        continue;
                    }
                    if (k == K_RIGHT) {
                        if (w->cursor < len) { w->cursor++; tv_dialog_draw(d); }
                        continue;
                    }
                    if (k == K_HOME) {
                        w->cursor = 0; tv_dialog_draw(d); continue;
                    }
                    if (k == K_END) {
                        w->cursor = len; tv_dialog_draw(d); continue;
                    }
                    if (k == K_BACK || k == 0x66u) {
                        if (w->cursor > 0) {
                            for (int i = w->cursor - 1; i < len; i++) w->str_buf[i] = w->str_buf[i + 1];
                            w->cursor--;
                            tv_dialog_draw(d);
                        }
                        continue;
                    }
                    if (k >= 32 && k < 256 && len + 1 < w->str_maxlen) {
                        for (int i = len; i >= w->cursor; i--) w->str_buf[i + 1] = w->str_buf[i];
                        w->str_buf[w->cursor++] = (char)k;
                        tv_dialog_draw(d);
                        continue;
                    }
                }
            }
        }
    }
    
    box_pop();
    g_modal_level--;
    dn_keybar_browser();
    /* v0.15.415: навигатор перерисовываем ТОЛЬКО когда меню не открыто. Фон под окном уже вернул
       стек (v0.15.401); лишняя перерисовка стирала открытое меню, а меню считало себя целым -
       отсюда обрывок его строки, оставшийся на списке файлов (артефакт, замеченный владельцем). */
    if(!g_menu_open) render_browser();
    
    return result;
}

/* =================================================================================================
 * Storage Controllers Settings Dialogs
 * =================================================================================================
 */
void tv_nemo_ide_dialog(void) {
    int m = (opt_defmachine >= 0 && opt_defmachine < N_MACHINES) ? opt_defmachine : 0;
    TV_Dialog d;
    tv_dialog_init(&d, "NEMO-IDE Hard Disk Settings", 62, 18);
    
    int ide_enable = opt_ide;
    int ide_source = 0;
    int ide_dev = opt_idedev;
    
    static char ide_img_path[96] = "";
    static char ide_fld_path[96] = "0:/GAMES/";
    if (!ide_img_path[0]) {
        const char* p = g_mp[m].idefile[0] ? g_mp[m].idefile : "0:/HDD.HDF";
        int i = 0; for (; p[i] && i < (int)sizeof(ide_img_path) - 1; i++) ide_img_path[i] = p[i];
        ide_img_path[i] = 0;
    }
    
    tv_dialog_add_check(&d, 3, 2, "Interface enabled (ports #10/#11, #30-#F0)", &ide_enable);
    
    tv_dialog_add_label(&d, 3, 4, "Storage source:", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 5, "Image file (.HDF / .IMG):", 1, 0, &ide_source);
    tv_dialog_add_input_browse(&d, 7, 6, 50, ide_img_path, sizeof(ide_img_path), TV_BROWSE_FILE, "*.HDF;*.IMG;*.BIN;*.RAW;*.*");
    
    tv_dialog_add_radio(&d, 5, 8, "Virtual folder:", 1, 1, &ide_source);
    tv_dialog_add_input_browse(&d, 7, 9, 50, ide_fld_path, sizeof(ide_fld_path), TV_BROWSE_DIR, NULL);
    
    tv_dialog_add_label(&d, 3, 11, "IDE Device mode:", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 12, "Master (Single drive)", 2, 0, &ide_dev);
    tv_dialog_add_radio(&d, 30, 12, "Master + Slave", 2, 1, &ide_dev);
    
    tv_dialog_add_button(&d, "  OK  ", TV_RES_OK);
    tv_dialog_add_button(&d, " Eject ", TV_RES_EJECT);
    tv_dialog_add_button(&d, "Cancel", TV_RES_CANCEL);
    
    int res = tv_dialog_exec(&d);
    if (res == TV_RES_OK) {
        int i = 0;
        const char* src = (ide_source == 0) ? ide_img_path : ide_fld_path;
        for (; src[i] && i < (int)sizeof(g_mp[m].idefile) - 1; i++) g_mp[m].idefile[i] = src[i];
        g_mp[m].idefile[i] = 0;
        
        opt_idedev = ide_dev;
        opt_ide = ide_enable;
        apply_ide();
    } else if (res == TV_RES_EJECT) {
        ide_close();
        opt_ide = 0;
        apply_ide();
    }
}

extern int opt_zcturbo;
void tv_zcontroller_dialog(void) {
    int m = (opt_defmachine >= 0 && opt_defmachine < N_MACHINES) ? opt_defmachine : 0;
    TV_Dialog d;
    tv_dialog_init(&d, "Z-Controller (SD Card)", 64, 23);   /* v384: 24 всё равно зажималось в 23 */
    
    int zc_enable = opt_zc;
    int zc_source = opt_zcmode;
    int zc_fs_mode = opt_zcfat32 ? 1 : (opt_zcroot ? 2 : 0);
    int zc_turbo = opt_zcturbo;
    int zc_write = opt_zcwr;        /* v410: разрешение записи - настройка ЭТОГО контроллера */
    
    static char zc_fld_path[96] = "";
    static char zc_img_path[96] = "0:/SDCARD.IMG";
    if (!zc_fld_path[0]) {
        const char* p = g_mp[m].zcfile[0] ? g_mp[m].zcfile : "0:/DIVMMC/";
        int i = 0; for (; p[i] && i < (int)sizeof(zc_fld_path) - 1; i++) zc_fld_path[i] = p[i];
        zc_fld_path[i] = 0;
    }
    
    tv_dialog_add_check(&d, 3, 2, "Interface enabled (ports #57, #77 - KOE standard)", &zc_enable);
    
    tv_dialog_add_label(&d, 3, 4, "Storage source:", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 5, "Virtual folder:", 1, 0, &zc_source);
    tv_dialog_add_input_browse(&d, 7, 6, 52, zc_fld_path, sizeof(zc_fld_path), TV_BROWSE_DIR, NULL);
    
    tv_dialog_add_radio(&d, 5, 8, "Image file (.IMG / .HDF):", 1, 1, &zc_source);
    tv_dialog_add_input_browse(&d, 7, 9, 52, zc_img_path, sizeof(zc_img_path), TV_BROWSE_FILE, "*.IMG;*.HDF;*.RAW;*.BIN;*.*");
    
    /* v0.15.410 Запись - под блоком образа: она работает ТОЛЬКО с образом (папочный том пока
       только на чтение), и соседство об этом и говорит. */
    tv_dialog_add_check(&d, 7, 10, "Allow writes (image only)", &zc_write);
    
    tv_dialog_add_label(&d, 3, 12, "Folder FS mode (when folder selected):", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 13, "FAT32 (Dynamic root, full LFN - Wild Player)", 2, 1, &zc_fs_mode);
    tv_dialog_add_radio(&d, 5, 14, "FAT16 (2048 root - Bob Fossil LFN)", 2, 0, &zc_fs_mode);
    tv_dialog_add_radio(&d, 5, 15, "FAT16 (512 root - Strict DOS)", 2, 2, &zc_fs_mode);
    
    /* 🥇 v0.15.384 (нашёл сторож tools/audit_tv_dialogs.py): окно просили H=24, а tv_dialog_init
       зажимает высоту в 23 (DN_ROWS-2). Значит brow уехал на top+20, последняя допустимая строка тела -
       H-5 = 18, и радио на строке 19 стояло ВПЛОТНУЮ к кнопкам: пустой строки над кнопочной панелью,
       которую владелец просил 18.08, у этого диалога не было. Сдвигаем блок на строку выше. */
    tv_dialog_add_label(&d, 3, 16, "SPI Bus Speed:", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 17, "Turbo SPI (28 MHz - Fast FPGA)", 3, 1, &zc_turbo);
    tv_dialog_add_radio(&d, 5, 18, "Standard SPI (3.5 MHz - Classic ZC)", 3, 0, &zc_turbo);
    
    tv_dialog_add_button(&d, "  OK  ", TV_RES_OK);
    tv_dialog_add_button(&d, " Eject ", TV_RES_EJECT);
    tv_dialog_add_button(&d, "Cancel", TV_RES_CANCEL);
    
    int res = tv_dialog_exec(&d);
    if (res == TV_RES_OK) {
        int i = 0;
        const char* src = (zc_source == 0) ? zc_fld_path : zc_img_path;
        for (; src[i] && i < (int)sizeof(g_mp[m].zcfile) - 1; i++) g_mp[m].zcfile[i] = src[i];
        g_mp[m].zcfile[i] = 0;
        
        opt_zcmode = zc_source;
        g_mp[m].zcmode = zc_source;   /* v430: без этого режим не попадал в профиль и не сохранялся в ini */
        if (zc_fs_mode == 0) { opt_zcfat32 = 0; opt_zcroot = 0; }
        else if (zc_fs_mode == 1) { opt_zcfat32 = 1; opt_zcroot = 0; }
        else if (zc_fs_mode == 2) { opt_zcfat32 = 0; opt_zcroot = 1; }
        opt_zcturbo = zc_turbo;
        g_mp[m].zcturbo = zc_turbo;
        opt_zc = zc_enable;
        opt_zcwr = zc_write;        /* v410 */
        apply_zc();
        apply_cardwr();             /* защита записи - свойство карты: поднимаем её заново */
    } else if (res == TV_RES_EJECT) {
        opt_zc = 0;
        apply_zc();
    }
}

/* 🥇 v0.15.414 ОКНО ПРИВОДОВ BETA DISK (просьба владельца: «под каждой буквой поле с выбором пути
   до TRD, с кнопкой дерева, ровно как в диалогах DivMMC или Z-Controller»).
   Пустое поле = привод пуст: одно правило вместо отдельной кнопки извлечения, и оно совпадает с
   поведением полей образа у карты. Начальный фокус - первое поле сверху (каркас ставит focus_idx=0).
   Короткий выбор буквы, который открывается при Enter на `.trd` в навигаторе, остаётся как был:
   там файл уже выбран, и спрашивать надо только букву. */
static char g_bdi_dlg_pth[4][96];
static void bdi_dlg_eject(TV_Dialog* d, int drv) {
    (void)d;
    if (drv < 0 || drv >= 4) return;
    if (g_dopen[drv]) {
        if (disk_eject_safe(drv)) return;   /* занят - поле не трогаем */
    }
    g_bdi_dlg_pth[drv][0] = 0;
}
void tv_bdi_drives_dialog(void) {
    int wr = opt_diskwr;
    for (int d = 0; d < NDRV && d < 4; d++) {
        int i = 0;
        for (; g_dpath[d][i] && i < (int)sizeof(g_bdi_dlg_pth[d]) - 1; i++) g_bdi_dlg_pth[d][i] = g_dpath[d][i];
        g_bdi_dlg_pth[d][i] = 0;
    }
    TV_Dialog dg;
    tv_dialog_init(&dg, "BDI / TR-DOS drives (Beta Disk)", 64, 14);
    dg.on_cmd = bdi_dlg_eject;
    tv_dialog_add_label(&dg, 2, 2, "One row: letter, image, tree, Eject:", DNK_HEADER);
    static const char* const LTR[4] = { "A:", "B:", "C:", "D:" };
    for (int d = 0; d < NDRV && d < 4; d++) {
        int y = 4 + d;
        int fx = 5, fw = 46;
        tv_dialog_add_label(&dg, 2, y, LTR[d], DNK_DLG_FG);
        tv_dialog_add_input_browse(&dg, fx, y, fw, g_bdi_dlg_pth[d], sizeof(g_bdi_dlg_pth[d]), TV_BROWSE_FILE,
                                   "*.TRD;*.SCL;*.*");
        tv_dialog_add_cmd(&dg, fx + (fw - 4) + 1 + 3 + 1, y, "Eject", d);
    }
    tv_dialog_add_check(&dg, 3, 9, "Allow writes to mounted images", &wr);
    tv_dialog_add_button(&dg, "  OK  ", TV_RES_OK);
    tv_dialog_add_button(&dg, "Cancel", TV_RES_CANCEL);
    if (tv_dialog_exec(&dg) != TV_RES_OK) return;

    /* Применяем по одному приводу: пустое поле - извлечь, изменившийся путь - вставить. Порядок
       именно такой, иначе вставка в занятый привод молча оставила бы старый образ. */
    int done = 0, failed = 0, out = 0;
    for (int d = 0; d < NDRV && d < 4; d++) {
        int same = 1;
        for (int i = 0; i < (int)sizeof(g_bdi_dlg_pth[d]); i++) {
            if (g_bdi_dlg_pth[d][i] != g_dpath[d][i]) { same = 0; break; }
            if (!g_bdi_dlg_pth[d][i]) break;
        }
        if (same) continue;
        if (!g_bdi_dlg_pth[d][0]) { if (g_dopen[d]) { if (disk_eject_safe(d)) failed++; else out++; } continue; }
        if (disk_mount_drv(g_bdi_dlg_pth[d], d) == 0) done++; else failed++;
    }
    if (wr != opt_diskwr) { opt_diskwr = wr ? 1 : 0; disk_wp_refresh(); }
    if (failed)      dn_status_msg("SOME DRIVES FAILED - CHECK THE PATH");
    else if (done)   dn_status_msg("DISK IMAGES INSERTED");
    else if (out)    dn_status_msg("DRIVE EJECTED, WRITTEN BACK TO CARD");
    else             dn_status_msg("BDI SETTINGS SAVED");
}
void tv_divmmc_dialog(void) {
    int m = (opt_defmachine >= 0 && opt_defmachine < N_MACHINES) ? opt_defmachine : 0;
    TV_Dialog d;
    tv_dialog_init(&d, "DivMMC & esxDOS Settings", 64, 22);   /* v429: +2 - галочка на 17 и пустая строка над кнопками */
    
    int dm_enable = opt_divmmc;
    int dm_autotrap = 1;
    int dm_source = opt_dmmode;
    int dm_fs_mode = opt_dmfat32 ? 1 : (opt_dmroot ? 2 : 0);
    int dm_write = opt_dmwr;        /* v410: разрешение записи - настройка ЭТОГО контроллера */
    int dm_fast  = opt_dmfast;      /* v427: быстрое подтверждение записи (B0150) */
    
    static char dm_fld_path[96] = "";
    static char dm_img_path[96] = "0:/DIVMMC.IMG";
    if (!dm_fld_path[0]) {
        const char* p = g_mp[m].dmfile[0] ? g_mp[m].dmfile : "0:/DIVMMC/";
        int i = 0; for (; p[i] && i < (int)sizeof(dm_fld_path) - 1; i++) dm_fld_path[i] = p[i];
        dm_fld_path[i] = 0;
    }
    
    tv_dialog_add_check(&d, 3, 2, "Interface enabled (ports #E3, #EB, 128 KB RAM)", &dm_enable);
    tv_dialog_add_check(&d, 3, 3, "Automapper active (traps #0000, #0066, #3D13)", &dm_autotrap);
    
    tv_dialog_add_label(&d, 3, 5, "Storage source:", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 6, "Virtual folder:", 1, 0, &dm_source);
    tv_dialog_add_input_browse(&d, 7, 7, 52, dm_fld_path, sizeof(dm_fld_path), TV_BROWSE_DIR, NULL);
    
    tv_dialog_add_radio(&d, 5, 9, "Image file (.IMG / .HDF):", 1, 1, &dm_source);
    tv_dialog_add_input_browse(&d, 7, 10, 52, dm_img_path, sizeof(dm_img_path), TV_BROWSE_FILE, "*.IMG;*.HDF;*.RAW;*.*");
    
    /* v0.15.410: см. окно Z-Controller - запись работает только с образом. */
    tv_dialog_add_check(&d, 7, 11, "Allow writes (image only)", &dm_write);
    tv_dialog_add_label(&d, 3, 12, "Folder FS mode (when folder selected):", DNK_HEADER);
    tv_dialog_add_radio(&d, 5, 13, "FAT16 (2048 root - Bob Fossil LFN)", 2, 0, &dm_fs_mode);
    tv_dialog_add_radio(&d, 5, 14, "FAT32 (Dynamic root, full LFN)", 2, 1, &dm_fs_mode);
    tv_dialog_add_radio(&d, 5, 15, "FAT16 (512 root - Strict DOS)", 2, 2, &dm_fs_mode);
    /* v0.15.429: обход фокуса идёт по ПОРЯДКУ ДОБАВЛЕНИЯ, а не по координатам - поэтому галочка
       добавляется здесь, ПОСЛЕ блока FS, как и нарисована. Подпись называет, КОГДА трогать:
       выключать только если чужой драйвер ждёт после записи строго 0xFF. */
    tv_dialog_add_check(&d, 3, 17, "Fast write ack (esxDOS; off = strict SD spec)", &dm_fast);
    
    tv_dialog_add_button(&d, "  OK  ", TV_RES_OK);
    tv_dialog_add_button(&d, " Eject ", TV_RES_EJECT);
    tv_dialog_add_button(&d, "Cancel", TV_RES_CANCEL);
    
    int res = tv_dialog_exec(&d);
    if (res == TV_RES_OK) {
        int i = 0;
        const char* src = (dm_source == 0) ? dm_fld_path : dm_img_path;
        for (; src[i] && i < (int)sizeof(g_mp[m].dmfile) - 1; i++) g_mp[m].dmfile[i] = src[i];
        g_mp[m].dmfile[i] = 0;
        
        opt_dmmode = dm_source;
        if (dm_fs_mode == 0) { opt_dmfat32 = 0; opt_dmroot = 0; }
        else if (dm_fs_mode == 1) { opt_dmfat32 = 1; opt_dmroot = 0; }
        else if (dm_fs_mode == 2) { opt_dmfat32 = 0; opt_dmroot = 1; }
        opt_divmmc = dm_enable;
        opt_dmwr = dm_write;        /* v410 */
        opt_dmfast = dm_fast;       /* v427: применяется тем же apply_cardwr - карта поднимается заново */
        apply_cardwr();             /* защита записи - свойство карты */
        apply_divmmc();
    } else if (res == TV_RES_EJECT) {
        opt_divmmc = 0;
        apply_divmmc();
    }
}

/* =================================================================================================
 * v0.15.384 «ROM FILE AND BANKS» - ОДИН ЭКРАН ПРО ПЗУ (задание владельца 19.08: «меню управления
 * банками ром тоже не совсем логично выглядит, надо как-то уметь показывать какие банки или
 * содержимое в ром файле, и выбирать из разных вариантов любого ром файла»).
 *
 * Что здесь видно и почему именно это:
 *   - ФАЙЛ и путь к нему. Через универсальный picker, то есть ЛЮБАЯ папка, а не только 0:/ROMS/:
 *     готовые наборы лежат и в 0:/zc/ (PROTEUS.ROM), и куда владелец их положит.
 *   - РАЗМЕР и ЧИСЛО СТРАНИЦ. Файлы бывают 16/32/48/64 КБ, то есть 1..4 страницы, и делать вид, что
 *     их всегда четыре, значит врать на трёх из четырёх видов файлов.
 *   - ТАБЛИЦА СТРАНИЦ: номер, что в странице лежит (rom_ident.c - «128 menu», «TR-DOS 6.11Q»,
 *     «GLUK SERVICE», «FATALL v0.25», «PROTEUS SVC», «esxDOS», «DIAG ROM», «EMPTY (FF)»...) и В КАКОЙ
 *     СЛОТ она уедет. Колонка «уедет» считается ТОЙ ЖЕ функцией, что и заливка (rom_auto_map), -
 *     показанное и сделанное разойтись не могут.
 *   - AUTO / MANUAL. AUTO - раскладка по содержимому, как с v207. MANUAL - таблица «слот <- страница»:
 *     именно этого просил владелец, и именно так одностраничный файл кладётся в любой слот.
 *   - СТАРТОВЫЙ СЛОТ (ROM BOOT SLOT) - показан, чтобы причина и следствие были в одном окне.
 *   - ПРЕДУПРЕЖДЕНИЕ о слоте, который останется с ПРЕЖНИМ содержимым BRAM. Раньше об этом молчали.
 *
 * Навигация - каркасная и ничем не отличается от остальных диалогов: Tab между группами (у каждой
 * строки-слота своя группа), стрелки только двигают фокус, Space выбирает, Enter/OK применяет один раз.
 * Все строки - ASCII: канва CP866, многобайтовых символов тут быть не может (v378 уже ловили).
 * ================================================================================================= */
#define RSD_SLOTS 4
/* 🥇 У подписей каркаса TV КЛИПА ИНТЕРЬЕРА НЕТ (clip_push в tv_ui.c не вызывается): строка, которая не
   влезла, честно вылезет за рамку окна на панель навигатора. Значит длину считает автор, руками.
   Окно 76 клеток -> интерьер x = 1..74. Подпись с x=3 имеет 72 знака, с x=4 - 71. Буфер = знаки+1. */
#define RSD_TXT   73                            /* подписи с x=3: info / boot / warn */
#define RSD_ROWC  72                            /* строки таблицы страниц: x=4 */
static const char* const RSD_SLOTNAME[RSD_SLOTS] = { "128 menu", "48 BASIC", "TR-DOS", "Service" };

static char       rsd_path[96] = "0:/ROMS/";
static char       rsd_seen[96] = "\x01";        /* заведомо != rsd_path -> первая перерисовка читает файл */
static uint32_t   rsd_size = 0, rsd_npg = 0;
static uint8_t    rsd_ids[RSD_SLOTS], rsd_kinds[RSD_SLOTS];
static char       rsd_lbl[RSD_SLOTS][20];
static int        rsd_read_ok = 0;
static int        rsd_mode = 0;                 /* 0 AUTO / 1 MANUAL */
static int        rsd_map[RSD_SLOTS];           /* слот -> номер страницы в файле, -1 = не грузить */
static char       rsd_info[RSD_TXT], rsd_boot[RSD_TXT], rsd_warn[RSD_TXT];
static char       rsd_row[RSD_SLOTS][RSD_ROWC];
static char       rsd_slotlbl[RSD_SLOTS][20];
static TV_Dialog* rsd_dlg = 0;
static int        rsd_matrix0 = -1;             /* индекс первого виджета матрицы (шаг 5 на слот) */

static int rsd_add(char* d, int cap, int at, const char* s){
    if(!s) return at;
    for(int i=0; s[i] && at < cap-1; i++) d[at++] = s[i];
    d[at] = 0; return at;
}
static int rsd_addu(char* d, int cap, int at, uint32_t v){
    char t[12]; itoa_u(v, t); return rsd_add(d, cap, at, t);
}
static int rsd_pad(char* d, int cap, int at, int col){
    while(at < col && at < cap-1) d[at++] = ' ';
    d[at] = 0; return at;
}

/* Файл, лежащий прямо в 0:/ROMS/, храним КОРОТКИМ ИМЕНЕМ - ровно так, как хранили с v207. Тогда он
   совпадает с элементом списка «Whole ROM set», а не добавляется в него отдельной длинной строкой, и
   ini остаётся байт-в-байт таким же, как у прежних версий. Путь остаётся путём только там, где он
   действительно нужен: другая папка (0:/zc/PROTEUS.ROM) или подпапка внутри ROMS. */
static const char* rsd_store_name(const char* p){
    const char* pre = "0:/ROMS/";
    int i = 0;
    for(; pre[i]; i++){
        char a = p[i], b = pre[i];
        if(a >= 'a' && a <= 'z') a -= 32;
        if(b >= 'a' && b <= 'z') b -= 32;
        if(a != b) return p;
    }
    const char* rest = p + i;
    if(!rest[0]) return p;
    for(int j=0; rest[j]; j++) if(rest[j] == '/') return p;   /* подпапка - оставляем полный путь */
    return rest;
}

static void rsd_refresh(void){
    int m = (opt_defmachine >= 0 && opt_defmachine < N_MACHINES) ? opt_defmachine : 0;

    /* --- 1. ФАЙЛ СМЕНИЛСЯ - ПЕРЕЧИТАТЬ. Сравнение по строке, а не флагом: перерисовка бывает на
           каждое нажатие клавиши, а чтение до 64 КБ с карты - только при смене файла. --- */
    int same = 1;
    for(int i=0; i<(int)sizeof(rsd_path); i++){
        if(rsd_path[i] != rsd_seen[i]){ same = 0; break; }
        if(!rsd_path[i]) break;
    }
    if(!same){
        int k=0; for(; rsd_path[k] && k < (int)sizeof(rsd_seen)-1; k++) rsd_seen[k] = rsd_path[k];
        rsd_seen[k] = 0;
        rsd_read_ok = rom_set_probe(rsd_path, &rsd_size, &rsd_npg, rsd_ids, rsd_kinds, rsd_lbl);
        /* Новый файл - новая раскладка по содержимому, и она же стартовая точка для MANUAL: владелец
           правит готовое, а не собирает с нуля. */
        int pg[RSD_SLOTS]; rom_auto_map(rsd_kinds, rsd_npg, pg);
        for(int s=0; s<RSD_SLOTS; s++) rsd_map[s] = pg[s];
    }

    /* --- 2. ДЕЙСТВУЮЩАЯ РАСКЛАДКА. В AUTO её считает ТА ЖЕ функция, что и заливка. --- */
    int eff[RSD_SLOTS];
    if(rsd_mode == 1){
        for(int s=0; s<RSD_SLOTS; s++)
            eff[s] = (rsd_map[s] >= 0 && (uint32_t)rsd_map[s] < rsd_npg) ? rsd_map[s] : -1;
    } else {
        rom_auto_map(rsd_kinds, rsd_npg, eff);
        for(int s=0; s<RSD_SLOTS; s++) rsd_map[s] = eff[s];   /* переход в MANUAL начинается с AUTO */
    }

    /* --- 3. СТРОКА О ФАЙЛЕ --- */
    { int a = 0; rsd_info[0] = 0;
      if(!rsd_read_ok && rsd_size){
          /* 🥇 v0.15.386: «файла нет» - НЕПРАВДА, когда файл открылся, но его размер не набор
             (ESXMMC.BIN 8192 Б, битстрим .BIN на 1.2 МБ). Называем размер и требование. */
          a = rsd_addu(rsd_info, RSD_TXT, 0, rsd_size);
          a = rsd_add (rsd_info, RSD_TXT, a, " bytes - not a ROM set: needs 16 / 32 / 48 / 64 KB");
      } else if(!rsd_read_ok){
          rsd_add(rsd_info, RSD_TXT, 0, "not read: no such file, or the card is out");
      } else {
          a = rsd_addu(rsd_info, RSD_TXT, a, rsd_size);
          a = rsd_add (rsd_info, RSD_TXT, a, " bytes = ");
          a = rsd_addu(rsd_info, RSD_TXT, a, rsd_npg);
          a = rsd_add (rsd_info, RSD_TXT, a, (rsd_npg == 1) ? " page x 16K" : " pages x 16K");
      } }

    /* --- 4. СТРОКА О СТАРТОВОМ СЛОТЕ. Номер страницы после сброса зашит в ЯДРЕ (rom_boot_page), а
           пункт ROM BOOT SLOT перекладывает в неё содержимое выбранного слота. Владелец должен видеть
           причину рядом со следствием - иначе «почему машина стартует не с того» неответим. --- */
    { int bp  = rom_boot_page(m);
      int bus = (g_mp[m].rombus >= 1 && g_mp[m].rombus <= RSD_SLOTS) ? g_mp[m].rombus - 1 : -1;
      int b   = (bus >= 0) ? bus : bp;
      int a = rsd_add(rsd_boot, RSD_TXT, 0, "Machine boots from slot ");
      a = rsd_addu(rsd_boot, RSD_TXT, a, (uint32_t)b);
      a = rsd_add (rsd_boot, RSD_TXT, a, " (");
      a = rsd_add (rsd_boot, RSD_TXT, a, RSD_SLOTNAME[b]);
      a = rsd_add (rsd_boot, RSD_TXT, a, ")  -  ROM BOOT SLOT = ");
      a = rsd_add (rsd_boot, RSD_TXT, a, (bus >= 0) ? "set by hand" : "AUTO"); }

    /* --- 5. ТАБЛИЦА СТРАНИЦ --- */
    for(int p=0; p<RSD_SLOTS; p++){
        int a = 0; rsd_row[p][0] = 0;
        if((uint32_t)p >= rsd_npg) continue;                 /* такой страницы в файле нет - строка пуста */
        a = rsd_add (rsd_row[p], RSD_ROWC, a, "Page ");
        a = rsd_addu(rsd_row[p], RSD_ROWC, a, (uint32_t)p);
        a = rsd_pad (rsd_row[p], RSD_ROWC, a, 8);
        a = rsd_add (rsd_row[p], RSD_ROWC, a, rsd_lbl[p][0] ? rsd_lbl[p] : "?");
        a = rsd_pad (rsd_row[p], RSD_ROWC, a, 26);
        a = rsd_add (rsd_row[p], RSD_ROWC, a, "-> ");
        /* В MANUAL одна страница законно уезжает в НЕСКОЛЬКО слотов. Перечисляем номерами, а не
           названиями: четыре названия подряд («slot 0 128 menu, slot 1 48 BASIC, ...») - это 95 знаков,
           то есть строка вылезла бы из окна (клипа у подписей нет). */
        { int n = 0, first = -1;
          for(int s=0; s<RSD_SLOTS; s++) if(eff[s] == p){ if(first < 0) first = s; n++; }
          if(!n) rsd_add(rsd_row[p], RSD_ROWC, a, "not loaded");
          else if(n == 1){
              a = rsd_add (rsd_row[p], RSD_ROWC, a, "slot ");
              a = rsd_addu(rsd_row[p], RSD_ROWC, a, (uint32_t)first);
              a = rsd_add (rsd_row[p], RSD_ROWC, a, " (");
              a = rsd_add (rsd_row[p], RSD_ROWC, a, RSD_SLOTNAME[first]);
              rsd_add(rsd_row[p], RSD_ROWC, a, ")");
          } else {
              a = rsd_add(rsd_row[p], RSD_ROWC, a, "slots ");
              for(int s=0, k=0; s<RSD_SLOTS; s++) if(eff[s] == p){
                  if(k++) a = rsd_add(rsd_row[p], RSD_ROWC, a, ",");
                  a = rsd_addu(rsd_row[p], RSD_ROWC, a, (uint32_t)s);
              }
          } }
    }

    /* --- 6. ПОДПИСИ СТРОК МАТРИЦЫ --- */
    for(int s=0; s<RSD_SLOTS; s++){
        int a = rsd_add (rsd_slotlbl[s], 20, 0, "Slot ");
        a = rsd_addu(rsd_slotlbl[s], 20, a, (uint32_t)s);
        a = rsd_add (rsd_slotlbl[s], 20, a, " ");
        rsd_add(rsd_slotlbl[s], 20, a, RSD_SLOTNAME[s]);
    }

    /* --- 7. ПРЕДУПРЕЖДЕНИЕ О НЕЗАПОЛНЕННОМ СЛОТЕ. Такая страница физически сохраняет ПРЕЖНЕЕ
           содержимое BRAM (заливка пропускает страницу без источника) - молчать об этом нельзя. --- */
    rsd_warn[0] = 0;
    if(rsd_read_ok){
        char dg[2*RSD_SLOTS]; int dn = 0;
        /* 🥇 v0.15.386: слот, у которого ЕСТЬ свой источник, прежним содержимым НЕ остаётся, и
           пугать им нельзя. Источников кроме набора два: персональный файл слота (Options > ROM >
           Slot N) и ПЗУ esxDOS, которое DivMMC кладёт в страницу 2. Ровно эти же исключения делает
           предупреждение самой заливки (rom_load_set) - иначе окно и строка статуса врали бы врозь. */
        for(int s=0; s<RSD_SLOTS; s++){
            if(eff[s] >= 0) continue;
            if(g_mp[m].rom[s][0]) continue;
            if(s == 2 && opt_divmmc) continue;
            if(dn) dg[dn++] = ',';
            dg[dn++] = (char)('0'+s);
        }
        dg[dn] = 0;
        if(dn){
            int many = (dn > 1);
            int a = rsd_add(rsd_warn, RSD_TXT, 0, (rsd_npg > 1) ? "WARNING: " : "Note: ");
            a = rsd_add(rsd_warn, RSD_TXT, a, many ? "slots " : "slot ");
            a = rsd_add(rsd_warn, RSD_TXT, a, dg);
            rsd_add(rsd_warn, RSD_TXT, a, many ? " keep the ROM already in memory"
                                              : " keeps the ROM already in memory");
        }
    }

    /* --- 8. МАТРИЦА ЖИВАЯ ТОЛЬКО В MANUAL, и только для страниц, которые в файле ЕСТЬ. --- */
    if(rsd_dlg && rsd_matrix0 >= 0){
        for(int s=0; s<RSD_SLOTS; s++)
            for(int col=0; col<RSD_SLOTS+1; col++){
                int idx = rsd_matrix0 + s*(RSD_SLOTS+1) + col;
                if(idx >= rsd_dlg->widget_count) continue;
                int exists = (col == RSD_SLOTS) ? 1 : ((uint32_t)col < rsd_npg);
                rsd_dlg->widgets[idx].disabled = (rsd_mode != 1 || !exists) ? 1 : 0;
            }
    }
}

void tv_rom_set_dialog(void){
    int m = (opt_defmachine >= 0 && opt_defmachine < N_MACHINES) ? opt_defmachine : 0;

    /* Стартовое значение поля: набор ЭТОЙ машины (имя в 0:/ROMS/ или полный путь), иначе папка наборов. */
    if(g_mp[m].romset[0]) rom_path_make(rsd_path, (int)sizeof(rsd_path), g_mp[m].romset);
    else { int i=0; const char* p0 = "0:/ROMS/"; for(; p0[i]; i++) rsd_path[i]=p0[i]; rsd_path[i]=0; }
    rsd_seen[0] = 1; rsd_seen[1] = 0;                    /* заставить пробу при первой же перерисовке */
    rsd_mode = g_mp[m].rommode ? 1 : 0;
    for(int s=0; s<RSD_SLOTS; s++) rsd_map[s] = g_mp[m].rommap[s];
    rsd_info[0] = rsd_boot[0] = rsd_warn[0] = 0;

    TV_Dialog d;
    tv_dialog_init(&d, "ROM file and banks", 76, 23);     /* brow = top+20, последняя строка тела y = 18 */
    d.refresh = rsd_refresh;
    rsd_dlg = &d;
    rsd_matrix0 = -1;

    tv_dialog_add_label(&d, 3, 1, "ROM file (any folder; 16 / 32 / 48 / 64 KB = 1..4 pages):", DNK_HEADER);
    tv_dialog_add_input_browse(&d, 3, 2, 66, rsd_path, sizeof(rsd_path), TV_BROWSE_FILE, "*.ROM;*.BIN;*.*");
    tv_dialog_add_label(&d, 3, 3, rsd_info, 0);
    tv_dialog_add_label(&d, 3, 4, rsd_boot, 0);

    tv_dialog_add_label(&d, 3, 6, "Pages in this file and where each one goes:", DNK_HEADER);
    for(int p=0; p<RSD_SLOTS; p++) tv_dialog_add_label(&d, 4, 7+p, rsd_row[p], 0);

    /* Подсказка «когда это трогать» - обязательна: переключатель без объяснения бесполезен. Место для
       неё внутри окна, а не в строке состояния меню: пункт открывается КОМАНДОЙ, у команд vwhy нет. */
    /* 🥇 v0.15.386 ЭТА ПОДСКАЗКА СТОЯЛА НА СТРОКЕ 10 - РОВНО ТАМ, ГДЕ ЧЕТВЁРТАЯ СТРОКА ТАБЛИЦЫ
       (страницы идут 7+p, то есть p=3 -> y=10). Подписи рисуются в порядке добавления, подсказка идёт
       ПОЗЖЕ - и затирала строку «Page 3». У всех наборов на карте по 64 КБ, то есть страниц ровно
       четыре: главное, что просил владелец увидеть, было невидимо. Строка 11 свободна. */
    tv_dialog_add_label(&d, 3, 11, "MANUAL: for unrecognised pages or another variant from this file.", 0);
    tv_dialog_add_label(&d, 3, 12, "Bank mapping:", DNK_HEADER);
    tv_dialog_add_radio(&d, 18, 12, "AUTO (by signature)", 1, 0, &rsd_mode);
    tv_dialog_add_radio(&d, 44, 12, "MANUAL (table below)", 1, 1, &rsd_mode);
    tv_dialog_add_label(&d, 4, 13, "Slot of the machine   takes page:", DNK_HEADER);
    for(int s=0; s<RSD_SLOTS; s++) tv_dialog_add_label(&d, 4, 14+s, rsd_slotlbl[s], 0);
    rsd_matrix0 = d.widget_count;                        /* дальше РОВНО матрица: шаг RSD_SLOTS+1 на слот */
    for(int s=0; s<RSD_SLOTS; s++){
        static const char* const PN[RSD_SLOTS+1] = { "P0", "P1", "P2", "P3", "none" };
        for(int col=0; col<RSD_SLOTS+1; col++)
            tv_dialog_add_radio(&d, 22 + col*10, 14+s, PN[col], 10+s,
                                (col == RSD_SLOTS) ? -1 : col, &rsd_map[s]);
    }
    tv_dialog_add_label(&d, 3, 18, rsd_warn, DNK_HOTKEY);

    tv_dialog_add_button(&d, "  OK  ",    TV_RES_OK);
    tv_dialog_add_button(&d, " Built-in ", TV_RES_EJECT);
    tv_dialog_add_button(&d, "Cancel",    TV_RES_CANCEL);

    int res = tv_dialog_exec(&d);
    rsd_dlg = 0;

    if(res == TV_RES_OK){
        if(!rom_port_ok()) return;                       /* ядро без порта заливки - менять нечего */
        if(!rsd_read_ok){ dn_status_msg("ROM FILE NOT READ - NOTHING CHANGED"); return; }
        { const char* st = rsd_store_name(rsd_path);
          int i=0; for(; st[i] && i < (int)sizeof(g_mp[m].romset)-1; i++) g_mp[m].romset[i] = st[i];
          g_mp[m].romset[i] = 0; }
        g_mp[m].rommode = rsd_mode ? 1 : 0;
        for(int s=0; s<RSD_SLOTS; s++)
            g_mp[m].rommap[s] = (rsd_map[s] >= 0 && rsd_map[s] < RSD_SLOTS) ? rsd_map[s] : -1;
        romset_rescan_sync();                            /* список и пункт «Whole ROM set» - на выбранный файл */
        if(g_tape_on) tape_stop();                       /* как apply_romset: машина уходит в холодный старт */
        rom_reapply_and_reset();                         /* ОДНО применение, по OK - см. apply_romset */
    } else if(res == TV_RES_EJECT){
        if(!rom_port_ok()) return;
        g_mp[m].romset[0] = 0;                           /* «Built-in» = вернуть ПЗУ, вшитое в битстрим */
        g_mp[m].rommode   = 0;
        for(int s=0; s<RSD_SLOTS; s++) g_mp[m].rommap[s] = -1;
        romset_rescan_sync();
        if(g_tape_on) tape_stop();
        rom_reapply_and_reset();
    }
}
