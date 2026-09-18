#!/usr/bin/env python3
# kvm.py - веб-КВМ платы EBAZ4205 через JTAG. Смотрит на файлы, которые пишет kvm_probe.tcl
# (одно живое подключение xsdb), и отдаёт браузеру экран машины + живые счётчики.
#
# Ethernet этой платы висит на выводах ПЛИС, а не на MIO, поэтому настоящий сетевой КВМ требует
# отдельного битстрима (задача #18). Этот обходится тем, что уже есть: отладочным JTAG.
#
# 🥇 Что стоит помнить про JTAG (ЗАМЕРЕНО): одно слово - 17 мс, блок 6912 Б - 119 мс, кадр из DDR -
# 804 мс. Поэтому регистры читаются ПАКЕТАМИ, а разбираются здесь; и поэтому кадр экрана неизбежно
# «рваный» по вертикали при анимации - за 119 мс луч проходит около шести кадров, а синхронизации
# с ним у отладочного канала нет.
import http.server, socketserver, os, time, struct, zlib, urllib.parse

D = "/tmp/kvm"
SCALE = 2

# палитра ZX: 8 цветов x 2 яркости (BRIGHT)
PAL = [(0,0,0),(0,0,192),(192,0,0),(192,0,192),(0,192,0),(0,192,192),(192,192,0),(192,192,192),
       (0,0,0),(0,0,255),(255,0,0),(255,0,255),(0,255,0),(0,255,255),(255,255,0),(255,255,255)]

def png(w, h, rows):
    """минимальный PNG без зависимостей: rows = список bytearray по 3*w байт"""
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(t, d):
        c = struct.pack(">I", len(d)) + t + d
        return c + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 6))
            + chunk(b"IEND", b""))

def zx_to_png(buf):
    """6912 байт экрана ZX -> PNG. Раскладка адресов у Спектрума не линейна, поэтому считаем её,
       а не 'рисуем по порядку': y = (addr>>11 & 3)*64 + (addr>>5 & 7)*8 + (addr>>8 & 7).
       Третье слагаемое - НОМЕР СТРОКИ ВНУТРИ СИМВОЛА, а не блок из восьми: перепутав их местами,
       получаешь узнаваемую, но нечитаемую кашу (проверено)."""
    if len(buf) < 6912:
        buf = buf + b"\x00" * (6912 - len(buf))
    px = [[0]*256 for _ in range(192)]
    for a in range(6144):
        y = ((a >> 11) & 3) * 64 + ((a >> 5) & 7) * 8 + ((a >> 8) & 7)
        x0 = (a & 31) * 8
        b = buf[a]
        attr = buf[6144 + (y >> 3) * 32 + (a & 31)]
        ink = (attr & 7) | ((attr & 64) >> 3)
        pap = ((attr >> 3) & 7) | ((attr & 64) >> 3)
        row = px[y]
        for bit in range(8):
            row[x0 + bit] = ink if (b >> (7 - bit)) & 1 else pap
    rows = []
    for y in range(192):
        line = bytearray()
        for x in range(256):
            line += bytes(PAL[px[y][x]]) * SCALE
        for _ in range(SCALE):
            rows.append(line)
    return png(256 * SCALE, 192 * SCALE, rows)

def words(name):
    try:
        with open(D + "/" + name, "rb") as f:
            d = f.read()
        return list(struct.unpack("<%dI" % (len(d)//4), d[:len(d)//4*4]))
    except Exception:
        return []

def regs():
    """собрать человеческую таблицу из пакетов, прочитанных опросом"""
    r00, rA0, r140, mb = words("r00.bin"), words("rA0.bin"), words("r140.bin"), words("mb.bin")
    def g(a, off):                      # off - смещение В БАЙТАХ от начала пакета
        i = off // 4
        return a[i] if i < len(a) else None
    out = []
    def add(k, v):
        if v is not None:
            out.append((k, "0x%08X" % v))
    add("VERSION", g(r00, 0x00))
    add("MACHINE_CFG", g(rA0, 0xBC - 0xA0))
    add("MACH_DBG", g(r140, 0x150 - 0x140))
    add("VIDEO 0xAC", g(rA0, 0xAC - 0xA0))
    add("FDC_STAT", g(r140, 0x160 - 0x140))
    add("AUD_DBG", g(r140, 0x170 - 0x140))
    st = g(r140, 0x174 - 0x140)
    pk = g(r140, 0x17C - 0x140)
    add("GS_STAT", st)
    if st is not None:
        out += [("GS b7 (машине)",      str((st >> 22) & 1)),
                ("GS b0 команда",       str((st >> 21) & 1)),
                ("GS байт не забран",   str((st >> 20) & 1)),
                ("GS cmd",              "0x%02X" % ((st >> 8) & 0xFF)),
                ("GS последний байт",   "0x%02X" % (st & 0xFF)),
                ("GS ПЕРЕПОЛНЕНИЕ ПЛИС", "%d/%d" % ((st >> 31) & 1, (st >> 30) & 1))]
    if pk is not None:
        out += [("ПИК ARM-ноги",    "%d / 127" % ((pk >> 16) & 0xFF)),
                ("ПИК итог. микса", "%d / 127" % (pk & 0xFF))]
    names = [(0x90, "GS ПЗУ загружено"), (0x94, "GS PC"), (0x9C, "GS забрал команд"),
             (0xA0, "GS прерываний"), (0xA4, "GS команд"), (0xA8, "GS данных"),
             (0xAC, "GS чтений #B3"), (0xB0, "GS липкие"), (0xB4, "GS сэмплов"),
             (0xBC, "GS проходов"), (0xC4, "GS ПОТЕРЯНО")]
    for off, nm in names:
        v = g(mb, off - 0x80)
        if v is None: continue
        if   off == 0x94: out.append((nm, "0x%04X" % (v & 0xFFFF)))
        elif off == 0xB0: out.append((nm, "0x%X" % v))
        else:             out.append((nm, str(v)))
    v = g(mb, 0xC0 - 0x80)
    if v is not None:
        out.append(("GS очередь ПЛИС/ARM", "%d / %d" % (v & 0xFFFF, (v >> 16) & 0xFFFF)))
    return out

PAGE = """<!doctype html><meta charset=utf-8><title>BulbuLator JTAG KVM</title>
<style>
body{background:#12141a;color:#d8dee9;font:14px/1.55 ui-monospace,Menlo,monospace;margin:0;padding:16px}
h1{font-size:15px;margin:0 0 4px;color:#88c0d0;font-weight:600}
#age{font-size:12px;color:#616e88;margin:0 0 12px}
#age.stale{color:#bf616a}
.wrap{display:flex;gap:22px;flex-wrap:wrap;align-items:flex-start}
img{image-rendering:pixelated;border:1px solid #3b4252;background:#000;display:block}
table{border-collapse:collapse}td{padding:1px 12px 1px 0;white-space:nowrap}
td.k{color:#81a1c1}td.v{color:#eceff4}
.hot{color:#a3be8c}.bad{color:#bf616a}
small{color:#616e88;display:block;margin-top:10px;max-width:520px}
</style>
<h1>BulbuLator - экран машины и живые счётчики (по JTAG)</h1>
<div id=age>...</div>
<div class=wrap>
  <div>
    <img id=s width=512 height=384>
    <small>Кадр читается одним трансфером 6912 байт за 119 мс, а луч за это время проходит около
    шести кадров: на анимации возможен горизонтальный шов. Синхронизации с лучом у отладочного
    канала нет - tearing-free КВМ будет по Ethernet (задача #18).</small>
  </div>
  <div><table id=r></table></div>
</div>
<script>
let prev={};
async function tick(){
  try{
    const t=await (await fetch('/regs?t='+Date.now())).text();
    let h='', age=null, paused=false;
    for(const l of t.split('\\n')){
      const i=l.indexOf('\\t'); if(i<0) continue;
      const k=l.slice(0,i), v=l.slice(i+1);
      if(k==='__age'){ age=parseFloat(v); continue; }
      if(k==='__paused'){ paused=(v==='1'); continue; }
      const ch=prev[k]!==undefined&&prev[k]!==v;
      const bad=((k.indexOf('ПОТЕРЯНО')>=0||k.indexOf('ПЕРЕПОЛНЕНИЕ')>=0)&&v!=='0'&&v!=='0/0'&&v!=='0x0');
      h+='<tr><td class=k>'+k+'</td><td class="v '+(bad?'bad':ch?'hot':'')+'">'+v+'</td></tr>';
      prev[k]=v;
    }
    document.getElementById('r').innerHTML=h;
    const a=document.getElementById('age');
    if(paused){ a.textContent='ПАУЗА: идёт прошивка или тест, опрос отпустил JTAG'; a.className='stale'; }
    else if(age!==null){ a.textContent='кадр обновлён '+age.toFixed(1)+' с назад'; a.className=(age>4?'stale':''); }
    if(!paused) document.getElementById('s').src='/scr.png?t='+Date.now();
  }catch(e){}
}
tick();setInterval(tick,700);
</script>
"""

class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a):
        pass
    def send_bytes(self, data, ctype):
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
    def do_GET(self):
        p = urllib.parse.urlparse(self.path)
        if p.path == "/":
            self.send_bytes(PAGE.encode(), "text/html; charset=utf-8")
        elif p.path == "/scr.png":
            try:
                with open(D + "/scr.bin", "rb") as f:
                    buf = f.read()
                self.send_bytes(zx_to_png(buf), "image/png")
            except Exception:
                self.send_bytes(png(1, 1, [bytearray(b"\x00\x00\x00")]), "image/png")
        elif p.path == "/regs":
            body = []
            try:
                with open(D + "/ts", "r") as f:
                    body.append("__age\t%.1f" % (time.time() - float(f.read().strip())))
            except Exception:
                body.append("__age\t999")
            body.append("__paused\t%d" % (1 if os.path.exists(D + "/pause") else 0))
            for k, v in regs():
                body.append("%s\t%s" % (k, v))
            self.send_bytes(("\n".join(body) + "\n").encode(), "text/plain; charset=utf-8")
        else:
            self.send_response(404); self.end_headers()

class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True

if __name__ == "__main__":
    os.makedirs(D, exist_ok=True)
    S(("0.0.0.0", 8088), H).serve_forever()
