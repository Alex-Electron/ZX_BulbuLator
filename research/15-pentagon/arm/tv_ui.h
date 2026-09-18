/* =================================================================================================
 * tv_ui.h - Declarative Turbo Vision / DOS Navigator UI Framework for BulbuLator
 * =================================================================================================
 */
#ifndef TV_UI_H
#define TV_UI_H

#include <stdint.h>
#include <stddef.h>

/* 🥇 v0.15.384: было 32. Диалог «ROM file and banks» показывает таблицу страниц И матрицу раскладки
   4 слота x 5 вариантов - это 40 виджетов. Переполнение каркас глотает МОЛЧА (add_* просто выходит),
   то есть лишние строки не появились бы, а ошибки не было бы. Цена подъёма - ~1.2 КБ стека на диалог
   (TV_Dialog лежит в кадре вызова), стек прошивки 128 КБ. */
#define TV_MAX_WIDGETS  48
#define TV_MAX_BUTTONS  4

/* Widget Types */
typedef enum {
    TV_W_NONE = 0,
    TV_W_LABEL,
    TV_W_CHECK,
    TV_W_RADIO,
    TV_W_INPUT,
    TV_W_BROWSE_BTN,
    TV_W_CMD
} TV_WidgetType;

/* Dialog Return Codes */
#define TV_RES_OK       1
#define TV_RES_CANCEL   0
#define TV_RES_YES      1
#define TV_RES_NO       0
#define TV_RES_EJECT    2
#define TV_RES_ALT      3

/* Browse Mode */
#define TV_BROWSE_DIR   0
#define TV_BROWSE_FILE  1

/* Individual UI Widget Descriptor */
typedef struct {
    TV_WidgetType type;
    int x, y, w;
    const char* label;
    int* val_ptr;
    int group_id;
    int item_id;
    char* str_buf;
    int str_maxlen;
    int cursor;
    int scroll;
    int target_input_idx;
    int browse_mode;
    const char* ext_filter;
    uint32_t custom_fg;
    uint8_t disabled;
} TV_Widget;

/* Declarative Dialog Descriptor */
typedef struct TV_Dialog_tag {
    const char* title;
    int W, H;
    int left, top;
    int brow;
    int slot;
    int widget_count;
    TV_Widget widgets[TV_MAX_WIDGETS];
    
    int btn_count;
    const char* btn_labels[TV_MAX_BUTTONS];
    int btn_results[TV_MAX_BUTTONS];
    int btn_x[TV_MAX_BUTTONS];
    int btn_w[TV_MAX_BUTTONS];
    
    int focus_idx;
    int focusable_count;
    int focusable_map[TV_MAX_WIDGETS + TV_MAX_BUTTONS];
    
    int default_res;
    int cancel_res;
    /* v0.15.384 ПЕРЕСЧЁТ ПРОИЗВОДНОГО ТЕКСТА ПЕРЕД КАЖДОЙ ОТРИСОВКОЙ. Каркас декларативный: подписи -
       это указатели, и диалог, у которого содержимое ЗАВИСИТ от выбранного значения (таблица страниц
       файла ПЗУ), обновить их иначе не может - хука между «нажали Space» и «нарисовали» не было.
       0 = поведение прежних диалогов без изменений. Функция обязана быть дешёвой: её зовут на каждое
       нажатие клавиши, поэтому чтение с карты внутри делается только при СМЕНЕ файла. */
    void (*refresh)(void);
    /* v0.15.418: кнопка в теле окна (Eject у привода), не закрывает диалог */
    void (*on_cmd)(struct TV_Dialog_tag *d, int cmd_id);
} TV_Dialog;

/* Global modal level tracker */
extern int g_modal_level;

/* Filesystem Mutation & Cache Invalidation API */
extern uint32_t g_fs_mutation_seq;
void tv_fs_touch(void);
void tv_fs_invalidate_cache(void);

/* Dialog Builder & Lifecycle Functions */
void tv_dialog_init(TV_Dialog* d, const char* title, int w, int h);
void tv_dialog_add_label(TV_Dialog* d, int x, int y, const char* text, uint32_t fg);
void tv_dialog_add_check(TV_Dialog* d, int x, int y, const char* text, int* val_ptr);
void tv_dialog_add_radio(TV_Dialog* d, int x, int y, const char* text, int group_id, int item_id, int* val_ptr);
void tv_dialog_add_input(TV_Dialog* d, int x, int y, int fw, char* buf, int maxlen);
void tv_dialog_add_input_browse(TV_Dialog* d, int x, int y, int fw, char* buf, int maxlen, int browse_mode, const char* ext_filter);
void tv_dialog_add_cmd(TV_Dialog* d, int x, int y, const char* label, int cmd_id);
void tv_dialog_add_button(TV_Dialog* d, const char* label, int result_code);
void tv_dialog_draw(TV_Dialog* d);
int  tv_dialog_exec(TV_Dialog* d);

/* Universal Modal File & Directory Browser */
int tv_browse_dialog(char* out_path, int maxlen, int mode, const char* ext_filter);

/* Specialized Controller Configuration Dialogs */
void tv_nemo_ide_dialog(void);
void tv_zcontroller_dialog(void);
void tv_divmmc_dialog(void);
void tv_bdi_drives_dialog(void);   /* v414: приводы Beta Disk - путь у каждой буквы */

/* v0.15.384: файл ПЗУ, его банки и раскладка по слотам машины - один экран (Options > ROM) */
void tv_rom_set_dialog(void);

#endif /* TV_UI_H */
