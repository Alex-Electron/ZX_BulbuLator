/*=================================================================================================
  net_kvm.c - МИНИМАЛЬНЫЙ ВЕБ-КВМ НА ПЛАТЕ: экран машины + канва навигатора + клавиатура.
  Подключается #include-ом в loader_main.c (как nes_rom.c), поэтому видит статику прошивки напрямую.

  Задача владельца: проверить запись в TR-DOS удалённо. Экрана и клавиатуры для этого ДОСТАТОЧНО -
  навигатор работает на плате, и через браузер им управляют так же, как сидя за платой. Родные
  веб-списки файлов и прочее (прежние /api/fs, /api/launch, /api/opt) - это шаг 16.

  ПОЧЕМУ БЕЗ ПРЕРЫВАНИЙ. GIC в прошивке поднят и занят ленточным ISR, от которого зависит тайминг
  загрузки. Вешать туда ещё и Ethernet-DMA - значит рисковать тем, что работает. Поэтому линию GEM0
  в GIC НЕ включаем (`emac_enable_intr` не вызываем), а обработчики порта дёргаем из главного цикла:
  `emacps_recv_handler` и `emacps_send_handler` - обычные публичные функции, они читают статус DMA и
  разбирают дескрипторы, для этого опрос годится. Ничто не прерывает главный цикл, тайминг цел.
  Плата за это - пропускная способность ограничена частотой цикла, для меню и набора текста хватает.

  lwIP собран в режиме NO_SYS=1 / NO_SYS_NO_TIMERS=1 (так его сконфигурировал BSP), значит таймеры
  протоколов вызываем сами: tcp_tmr / etharp_tmr / dhcp_*_tmr.

  КАДРЫ. Отдаём СЫРЫЕ буферы, без сжатия - разворачивание делает браузер. Именно так работал прежний
  КВМ, и отсюда его высокий FPS: ARM не тратит такты на кодирование.
    /frame  машина, 0x0FF00000, у ZX 384x302 4bpp = 57984 Б (байт = два пикселя)
    /osd    канва навигатора, 0x0F800000, 640x400 ARGB8888 = 1 МБ, отдаём по запросу
=================================================================================================*/
#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/dhcp.h"
#include "lwip/etharp.h"
#include "netif/xadapter.h"

/* Эти три живут во внутренних заголовках порта и lwIP. Объявляем сами - и заодно видно приём:
   обработчики Ethernet мы ЗОВЁМ ИЗ ЦИКЛА вместо прерывания, а таймер TCP при NO_SYS крутим руками. */
void emacps_recv_handler(void* arg);
void emacps_send_handler(void* arg);
void emac_disable_intr(void);
void tcp_tmr(void);

#define KVM_PORT        80
#define KVM_FRAME_ADDR  0x0FF00000u
#define KVM_OSD_ADDR    0x0F800000u
#define KVM_OSD_SIZE    (640u * 400u * 4u)

/* Состояние сети наружу для JTAG-проверки (мейлбокс, некешируемое окно). */
#define KVM_STAT (*(volatile uint32_t*)(KMB + 0x60u))   /* bit0 up, bit1 dhcp bound, [15:8] ошибка */
#define KVM_IP   (*(volatile uint32_t*)(KMB + 0x64u))   /* полученный адрес, сетевой порядок */

static struct netif g_knetif;
static int  g_knet_ready = 0;
static u32_t g_ktmr_tcp = 0, g_ktmr_arp = 0, g_ktmr_dhcpf = 0, g_ktmr_dhcpc = 0;
static u32_t g_ktick = 0;          /* грубые такты: инкремент на каждый вызов net_poll */

/* MAC: локально администрируемый, младший байт из VERSION ядра, чтобы две платы не столкнулись */
static unsigned char g_kmac[6] = { 0x02, 0xB0, 0x1B, 0x00, 0x00, 0x01 };

/* --------------------------------------------------------------------------- отдача ответа
   Раздача идёт куском: сколько влезло в окно отправки, остальное - в колбэке sent. Указатель живёт
   в DDR и не двигается, поэтому copy=0 безопасно и лишнего копирования нет. */
typedef struct {
    const u8_t* body;      /* что осталось отдать */
    u32_t       left;
    u8_t        close_after;
} kvm_conn;

static kvm_conn g_kconn[4];
static int kvm_conn_alloc(void){
    for(int i = 0; i < 4; i++) if(!g_kconn[i].left && !g_kconn[i].body) return i;
    return -1;
}

static void kvm_push(struct tcp_pcb* pcb, kvm_conn* c){
    while(c->left){
        u16_t room = tcp_sndbuf(pcb);
        if(room == 0) break;
        u16_t n = (c->left > room) ? room : (u16_t)c->left;
        if(tcp_write(pcb, c->body, n, 0) != ERR_OK) break;   /* 0 = не копировать, данные в DDR */
        c->body += n; c->left -= n;
    }
    tcp_output(pcb);
    if(!c->left && c->close_after){ c->body = 0; tcp_close(pcb); }
}

static err_t kvm_sent(void* arg, struct tcp_pcb* pcb, u16_t len){
    (void)len;
    kvm_conn* c = (kvm_conn*)arg;
    if(c) kvm_push(pcb, c);
    return ERR_OK;
}

/* --------------------------------------------------------------------------- страница
   Держим её крошечной и самодостаточной: канва, цикл дозагрузки кадра, отправка клавиш.
   Раскладка скан-кодов PS/2 set-2 - только то, что нужно для навигатора и набора в TR-DOS. */
static const char KVM_PAGE[] =
"HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
"<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
"<title>BulbuLator KVM</title>"
"<style>body{background:#0b0f16;color:#cfd8e3;font:13px system-ui;margin:0;padding:8px}"
"canvas{image-rendering:pixelated;width:100%;max-width:900px;background:#000;display:block}"
"#s{padding:4px 0;color:#8fa}</style>"
"<div id=s>connecting...</div><canvas id=cv width=384 height=302></canvas>"
"<script>\n"
"const PAL=[0x000000,0x0000c0,0xc00000,0xc000c0,0x00c000,0x00c0c0,0xc0c000,0xc0c0c0,"
"0x000000,0x0000ff,0xff0000,0xff00ff,0x00ff00,0x00ffff,0xffff00,0xffffff];\n"
"const P32=PAL.map(c=>0xff000000|((c&255)<<16)|(c&0xff00)|((c>>16)&255));\n"
"const cv=document.getElementById('cv'),cx=cv.getContext('2d');\n"
"let W=384,H=302,img=cx.createImageData(W,H),px=new Uint32Array(img.data.buffer),fps=0;\n"
"async function frame(){const r=await fetch('/frame',{cache:'no-store'});"
"const u=new Uint8Array(await r.arrayBuffer());let o=0;"
"for(let i=0;i<u.length&&o<px.length-1;i++){const b=u[i];px[o++]=P32[b&15];px[o++]=P32[(b>>4)&15];}"
"cx.putImageData(img,0,0);fps++;}\n"
"async function loop(){try{await frame();}catch(e){}setTimeout(loop,60);}loop();\n"
"setInterval(()=>{document.getElementById('s').textContent=fps+' fps';fps=0;},1000);\n"
"const SC={Escape:0x76,Enter:0x5a,Space:0x29,Backspace:0x66,Tab:0x0d,"
"ArrowUp:0x75,ArrowDown:0x72,ArrowLeft:0x6b,ArrowRight:0x74,"
"F1:0x05,F2:0x06,F3:0x04,F4:0x0c,F5:0x03,F6:0x0b,F7:0x83,F8:0x0a,F9:0x01,F10:0x09,F11:0x78,F12:0x07,"
"Digit1:0x16,Digit2:0x1e,Digit3:0x26,Digit4:0x25,Digit5:0x2e,Digit6:0x36,Digit7:0x3d,Digit8:0x3e,"
"Digit9:0x46,Digit0:0x45,Minus:0x4e,Equal:0x55,Quote:0x52,Semicolon:0x4c,Comma:0x41,Period:0x49,\n"
"KeyA:0x1c,KeyB:0x32,KeyC:0x21,KeyD:0x23,KeyE:0x24,KeyF:0x2b,KeyG:0x34,KeyH:0x33,KeyI:0x43,"
"KeyJ:0x3b,KeyK:0x42,KeyL:0x4b,KeyM:0x3a,KeyN:0x31,KeyO:0x44,KeyP:0x4d,KeyQ:0x15,KeyR:0x2d,"
"KeyS:0x1b,KeyT:0x2c,KeyU:0x3c,KeyV:0x2a,KeyW:0x1d,KeyX:0x22,KeyY:0x35,KeyZ:0x1a,"
"ShiftLeft:0x12,ShiftRight:0x59,ControlLeft:0x14,AltLeft:0x11};\n"
"function send(c,rel){fetch('/api/key?c='+c+'&r='+(rel?1:0)).catch(()=>{});}\n"
"addEventListener('keydown',e=>{const s=SC[e.code];if(s!==undefined){e.preventDefault();send(s,0);}});\n"
"addEventListener('keyup',e=>{const s=SC[e.code];if(s!==undefined){e.preventDefault();send(s,1);}});\n"
"</script>";

static const char KVM_HDR_BIN[] =
"HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
static const char KVM_HDR_TXT[] =
"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
static const char KVM_404[] =
"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n";

static char g_kbuf[192];       /* маленькие ответы (info, ok) */

/* Размер кадра машины: у ZX 384x302 4bpp, у NES 256x240 8bpp. Берём из живого MACHINE_ID. */
static u32_t kvm_frame_size(void){
    if((MACHINE_ID & 0xFFFFu) == 0x5A58u) return 384u * 302u / 2u;  /* ZX/Пентагон: байт = два пикселя */
    return 256u * 240u;                                              /* NES: байт = пиксель */
}

/* Совпал ли путь запроса с образцом (сравниваем только образец, дальше идёт строка запроса). */
static int kvm_is(const char* p, const char* pat){
    while(*pat){ if(*p != *pat) return 0; p++; pat++; }
    return 1;
}

static err_t kvm_recv(void* arg, struct tcp_pcb* pcb, struct pbuf* p, err_t err){
    kvm_conn* c = (kvm_conn*)arg;
    if(!p){ tcp_close(pcb); return ERR_OK; }
    if(err != ERR_OK || !c){ pbuf_free(p); tcp_close(pcb); return ERR_OK; }

    char req[160]; u16_t n = (p->tot_len < sizeof(req) - 1) ? p->tot_len : (u16_t)(sizeof(req) - 1);
    pbuf_copy_partial(p, req, n, 0); req[n] = 0;
    tcp_recved(pcb, p->tot_len);
    pbuf_free(p);

    c->close_after = 1;
    /* путь начинается после "GET " */
    const char* path = req;
    while(*path && *path != ' ') path++;
    if(*path == ' ') path++;

    if(path[0] == '/' && (path[1] == ' ' || path[1] == 0)){
        c->body = (const u8_t*)KVM_PAGE; c->left = sizeof(KVM_PAGE) - 1;
    } else if(kvm_is(path, "/frame") || kvm_is(path, "/osd")){
        /* Заголовок отдаём КОПИЕЙ и БЕЗ kvm_push: push с выставленным close_after закрыл бы
           соединение сразу после заголовка, и тело ушло бы в закрытый сокет. Тело - прямо из DDR
           (copy=0), это и есть причина высокого FPS: ARM не копирует и не кодирует кадр. */
        tcp_write(pcb, KVM_HDR_BIN, sizeof(KVM_HDR_BIN) - 1, TCP_WRITE_FLAG_COPY);
        if(path[1] == 'f'){ c->body = (const u8_t*)KVM_FRAME_ADDR; c->left = kvm_frame_size(); }
        else              { c->body = (const u8_t*)KVM_OSD_ADDR;   c->left = KVM_OSD_SIZE; }
    } else if(kvm_is(path, "/api/key")){
        /* /api/key?c=<код>&r=<0|1> */
        int code = -1, rel = 0;
        for(const char* q = path; *q && *q != ' '; q++){
            if(q[0] == 'c' && q[1] == '=') { code = 0; for(const char* d = q + 2; *d >= '0' && *d <= '9'; d++) code = code * 10 + (*d - '0'); }
            if(q[0] == 'r' && q[1] == '=') rel = (q[2] == '1');
        }
        if(code >= 0 && code < 256){
            uint32_t nxt = g_kinj_w + 1u;
            if((nxt - g_kinj_r) <= KINJ_N){
                g_kinj[g_kinj_w % KINJ_N] = (uint32_t)((rel ? 0x200u : 0u) | (uint32_t)code);
                g_kinj_w = nxt;
            }
        }
        c->body = (const u8_t*)KVM_HDR_TXT; c->left = sizeof(KVM_HDR_TXT) - 1;
    } else if(kvm_is(path, "/info")){
        int k = 0; const char* t;
        for(t = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\nfb="; *t; t++) g_kbuf[k++] = *t;
        { uint32_t v = kvm_frame_size(); char d[12]; itoa_u(v, d); for(int i = 0; d[i]; i++) g_kbuf[k++] = d[i]; }
        for(t = " core=0x"; *t; t++) g_kbuf[k++] = *t;
        { uint32_t v = REG_VERSION; const char* hx = "0123456789abcdef";
          for(int i = 7; i >= 0; i--) g_kbuf[k++] = hx[(v >> (i * 4)) & 15]; }
        g_kbuf[k++] = '\n'; g_kbuf[k] = 0;
        c->body = (const u8_t*)g_kbuf; c->left = (u32_t)k;
    } else {
        c->body = (const u8_t*)KVM_404; c->left = sizeof(KVM_404) - 1;
    }
    kvm_push(pcb, c);
    return ERR_OK;
}

static err_t kvm_accept(void* arg, struct tcp_pcb* pcb, err_t err){
    (void)arg;
    if(err != ERR_OK) return err;
    int i = kvm_conn_alloc();
    if(i < 0){ tcp_abort(pcb); return ERR_ABRT; }
    g_kconn[i].body = 0; g_kconn[i].left = 0; g_kconn[i].close_after = 1;
    tcp_arg(pcb, &g_kconn[i]);
    tcp_recv(pcb, kvm_recv);
    tcp_sent(pcb, kvm_sent);
    tcp_nagle_disable(pcb);
    return ERR_OK;
}

/*--------------------------------------------------------- 🥇 ПОЧЕМУ СЕТИ НЕТ БЕЗ НОВОГО БИТСТРИМА
  Измерено на живой плате 2026-08-05, и это ответ на вопрос «почему lwIP поднялся, а адреса нет».

  1. `frames_tx=0`, `frames_rx=0` при включённых приёме и передаче, и НИ ОДИН PHY не отвечает по
     MDIO (все 32 адреса - нули). То есть кадры не доходили до провода вообще.
  2. Живые регистры: MIO 16..27 и 52/53 стоят как обычный GPIO (поля выбора периферии нулевые),
     такты GEM0 взяты ИЗ EMIO (`RCLK_CTRL=0x11`, в `CLK_CTRL` бит6 = источник EMIO).
  3. В проекте ПЛИС ПРЕЖНЕГО веб-КВМ (`ws/ebaz_kvm/hw/design_4_wrapper.xsa`) есть
     `C_EN_EMIO_ENET0`, а `ENET0_GMII_*` и `ENET0_MDIO_*` выведены НАРУЖУ как внешние порты,
     причём набором `RX_DV`/`TX_EN`/`RX_CLK`/`TX_CLK` - то есть MII. Моста RGMII в проекте нет.

  Вывод: **PHY этой платы висит на выводах ПЛИС, а не на MIO.** Значит сеть невозможно поднять
  одной прошивкой: битстрим обязан вывести сигналы GEM0 (EMIO) на нужные ноги.

  ⚠ ТУПИК, КОТОРЫЙ НЕ НАДО ПОВТОРЯТЬ: замуксовать MIO 16..27 на GEM0 из ARM (`L0_SEL=1`) и MDIO на
  52/53 (`L3_SEL=4`) - можно, `frames_tx` даже становится 1, но провод от этого не появляется, зато
  MIO 24/25 - это UART платы (`L3_SEL=7`, выход и вход), и его такая правка ломает. Проверено и
  откатано; в прошивке этого кода СОЗНАТЕЛЬНО нет.

  Что нужно на стороне ПЛИС (шаг 16): `C_EN_EMIO_ENET0`, MII-сигналы и MDIO наружу, ноги PHY из
  документации платы, плюс места под это при нынешних 87 % LUT. */

/* --------------------------------------------------------------------------- подъём и опрос
   Возвращает то же слово, что кладёт в KVM_STAT: бит0 = порт слушает, старший байт = код отказа.
   Возврат, а не только регистр, - чтобы команда мейлбокса 13 могла ответить, не зная про макросы. */
static uint32_t net_init(void){
    ip_addr_t z; ip_addr_set_zero_ip4(&z);
    KVM_STAT = 0; KVM_IP = 0;
    if(g_knet_ready) return KVM_STAT = 1u;          /* повторный вызов - уже поднято */
    g_kmac[5] = (unsigned char)(REG_VERSION & 0xFFu);

    lwip_init();
    if(!xemac_add(&g_knetif, &z, &z, &z, g_kmac, XPAR_XEMACPS_0_BASEADDR)){
        return KVM_STAT = 0x0100u;                  /* MAC не поднялся */
    }
    /* 🥇 ОБЯЗАТЕЛЬНО, оплачено умершим отладочным APB и оживлением платы через rst -system на DAP.
       `xemac_add` внутри init_dma САМ делает XScuGic_EnableIntr для GEM0, не спрашивая нас. GIC у
       прошивки поднят (там живёт ленточный ISR), обработчика GEM0 нет - и первое же завершение
       передачи уводит процессор в Xil_ExceptionNullHandler. Мы опрашиваем, значит линию гасим. */
    emac_disable_intr();

    netif_set_default(&g_knetif);
    netif_set_up(&g_knetif);
    dhcp_start(&g_knetif);

    struct tcp_pcb* pcb = tcp_new();
    if(!pcb) return KVM_STAT = 0x0200u;
    if(tcp_bind(pcb, IP_ANY_TYPE, KVM_PORT) != ERR_OK) return KVM_STAT = 0x0300u;
    pcb = tcp_listen(pcb);
    tcp_accept(pcb, kvm_accept);

    g_knet_ready = 1;
    return KVM_STAT = 1u;
}

/* Вызывается из ГЛАВНОГО ЦИКЛА. Прерываний не используем сознательно (см. шапку). */
static void net_poll(void){
    if(!g_knet_ready) return;
    emacps_recv_handler(&g_knetif);      /* вместо ISR: разобрать принятые дескрипторы */
    emacps_send_handler(&g_knetif);
    xemacif_input(&g_knetif);            /* отдать пакеты в lwIP */

    g_ktick++;                            /* грубая база времени: цикл заметно быстрее 1 мс */
    if((u32_t)(g_ktick - g_ktmr_tcp)   > 2000u){ g_ktmr_tcp   = g_ktick; tcp_tmr(); }
    if((u32_t)(g_ktick - g_ktmr_arp)   > 100000u){ g_ktmr_arp   = g_ktick; etharp_tmr(); }
    if((u32_t)(g_ktick - g_ktmr_dhcpf) > 20000u){ g_ktmr_dhcpf = g_ktick; dhcp_fine_tmr(); }
    if((u32_t)(g_ktick - g_ktmr_dhcpc) > 1200000u){ g_ktmr_dhcpc = g_ktick; dhcp_coarse_tmr(); }

    if(dhcp_supplied_address(&g_knetif)){
        KVM_STAT = 3u;
        KVM_IP = ip4_addr_get_u32(netif_ip4_addr(&g_knetif));
    }
}
