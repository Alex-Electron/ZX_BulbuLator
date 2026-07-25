# MUST-PASS ФИКСТУРЫ — манифест (AI, 2026-07-21)

Недостающие форматные фикстуры для must-pass матрицы (WAV s16 + 48к; MP3 CBR/VBR).
Собраны **off-board**, детерминированно. Стейдж для the second agent: `thinkpad:/tmp/fixtures/{wav,mp3}` (SHA сверены после rsync).

## Принцип
Из ОДНОГО канонического PCM-мастера рендерится семейство, где меняется **только формат** —
чтобы в матрице отличить баг формат-тракта от проблемы контента.

## Источник (канонический)
- `dizzy_3.wav` — реальная кассетная запись игры (Dizzy 3), стандарт-ROM лоадер.
- Формат: PCM u8 / 44100 / mono, 391.99 s.
- Ведущий тон первых 1.5с ≈ **816 Гц** ⇒ настоящий ZX-пилот (2168T ≈ 807 Гц) присутствует → авто-детект лоадера сработает.
- SHA-256: `689da8263d033693bef7a7825ec92190bc5e548c2bbbc3c7c5ef57b31b56a00f`

## Инструменты
- ffmpeg 8.1.2 (soxr в сборке НЕТ → ресемпл 48к идёт через swr; verify показал сохранение фронтов).
- LAME 3.100.

## WAV-фикстуры (команды воспроизводимы 1:1)
```
ffmpeg -y -nostdin -i dizzy_3.wav -map_metadata -1 -c:a pcm_u8    -ac 1 -ar 44100 dizzy3.u8_44100.wav
ffmpeg -y -nostdin -i dizzy_3.wav -map_metadata -1 -c:a pcm_s16le -ac 1 -ar 44100 dizzy3.s16_44100.wav   # только битность, БЕЗ ресемпла
ffmpeg -y -nostdin -i dizzy_3.wav -map_metadata -1 -c:a pcm_u8    -ac 1 -ar 48000 dizzy3.u8_48000.wav
ffmpeg -y -nostdin -i dizzy_3.wav -map_metadata -1 -c:a pcm_s16le -ac 1 -ar 48000 dizzy3.s16_48000.wav
```
| Файл | Формат | SHA-256 |
|------|--------|---------|
| dizzy3.u8_44100.wav  | PCM u8 / 44.1k / mono  | `10af7a2632a437d97b0e7fa96f5242b04e643dfd86fb73ebf605c3407964b2e3` |
| dizzy3.s16_44100.wav | PCM s16le / 44.1k / mono | `a41eb610929805015babf2e21b86cf8dc05a8e3942ee3c78ed3ccb395563b8d1` |
| dizzy3.u8_48000.wav  | PCM u8 / 48k / mono    | `e1fa257370f10e055268fcb6cd6c6712a6f5079eef284b17f3a012f677605cd1` |
| dizzy3.s16_48000.wav | PCM s16le / 48k / mono | `62468e8a5d7f8159b01e23c1a2588ab17e0abd009f61dcda3c96849bf6125256` |

## MP3-фикстуры (с internal pilot = полный файл, пилот цел)
```
lame -S -m m --cbr -b 128 -q 2 dizzy3.s16_44100.wav dizzy3.cbr128_44100.pilot.mp3
lame -S -m m -V 2              dizzy3.s16_44100.wav dizzy3.vbr_v2_44100.pilot.mp3
```
| Файл | Формат | SHA-256 |
|------|--------|---------|
| dizzy3.cbr128_44100.pilot.mp3 | MP3 CBR 128k / mono | `6d2ea3cf261be132cc891cfae6d41608509eca24b22ba8a6e2c9840966ca63fc` |
| dizzy3.vbr_v2_44100.pilot.mp3 | MP3 VBR V2 / mono   | `8222dedbcd44295d455928be65eafe2dacb6abb712897e40e2302db233dc0235` |

## Verify (off-board)
- Все 4 WAV: **crossings=1061524, 2708.1/с — ИДЕНТИЧНО**. s16 тайминг-идентичен u8; 48к-ресемпл (swr) сохранил структуру фронтов точь-в-точь (crossings/с не изменился) → это валидные ленты, не «сглаженные».
- Оба MP3: лидер-тон после декода ≈ 816 Гц = пилот пережил lossy-кодирование → авто-детект найдёт пилот.

## Семантика internal pilot — ВЫВЕДЕНА ИЗ КОДА (loader_main.c:2551-2616, 21.07)
`qb_has_internal_pilot()` ищет ВТОРОЙ полный пилот(+2 синка) ВНУТРИ data-спана (спан кончается только
паузой ≥ QB_MAX_T=4096T ≈1.17мс или EOF). Т.е. «internal pilot» = сцепленные без паузы блоки.
Обнаружен → транзакционный RAW (qdbg[3]=3, qdbg[7]=1). Не обнаружен → quant-путь.

Итого пары для матрицы (обе из одного мастера):
- `dizzy3.cbr128/vbr_v2_44100.pilot.mp3` — нормальные паузы 2.06с × 5 ⇒ internal pilot НЕТ ⇒ ожидание: quant-путь, qdbg[7]=0.
- `dizzy3.cbr128/vbr_v2_44100.chained.mp3` — паузы вырезаны до 0.5мс (<1.17мс порога) ⇒ internal pilot ЕСТЬ ⇒ ожидание: RAW-fallback, qdbg[3]=3, qdbg[7]=1.

## MP3 chained-пара (internal pilot present)
Сплайс: пооконное DC-снятие (10мс), тихое окно = AC-пик<2000 (сигнал ~28700; тишина на DC-смещении!),
внутренние паузы ≥50мс → 0.5мс. Вырезано 5 пауз по ~2.06с (392.0s → 381.7s).
Промежуточный WAV: `dizzy3_chained.s16_44100.wav` SHA `1e588ba4…28d3dc`.
| Файл | SHA-256 |
|------|---------|
| dizzy3.cbr128_44100.chained.mp3 | `c8418a25…043212d` |
| dizzy3.vbr_v2_44100.chained.mp3 | `fb99a46f…738ef4` |

## Открыто
- Если для 48к нужен soxr вместо swr — пересоберу (на Маке soxr нет; можно поставить или взять другой ffmpeg).
- dizzy_3 длинный (392с/381.7с). Если для темпа матрицы нужна короткая стандарт-лента — подберу/подрежу по границе блока.
