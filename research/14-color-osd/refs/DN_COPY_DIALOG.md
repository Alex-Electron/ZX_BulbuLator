# DN Copy dialog + directory tree — анализ для порта (FAT/SD, 80×25, CP866)

Источники (CP866, grep с `-a`): `refs/dn/DosNavigator/FILECOPY.PAS` (логика), `tree.pas` (дерево ChangeDir/TTreeView), `DNUTIL.PAS` (ExecTree), `histlist.pas` (история ▼), `RESOURCE/ENGLISH/dn.dnr` (раскладка), `dnhelp.htx` (семантика).

## Раскладка (dn.dnr:2514) DIALOG dlgCopyDialog 78×15 'Copy'
- InputLine 2,2,74,3 + история `hsFileCopyName` (это ▼).
- RadioButtons (индекс = код режима): Overwrite0 / Append1 / Resume2 / Skip3 / Refresh4 / Ask5.
- Label "All files with the same names:".
- CheckBoxes: Check free disk space / Verify disk writes / Copy descriptions / Copy access rights(WIN32) / Remove source files.
- Buttons: OK(default) / Cancel / Tree / Help. Заполнение через record {S3 path; WW radio; WW1 checkmask}.

## Радио-режимы (FILECOPY.PAS:139 cpm*)
- **Overwrite(0)**: FA_CREATE_ALWAYS, даже не проверяет существование.
- **Append(1)**: дописать источник в КОНЕЦ приёмника (слияние; порядок важен).
- **Resume(2)**: докачка. Если dst_size < src_size → пропустить первые dst_size байт источника (`f_lseek(src,dst_size)`), дописать остаток в конец dst. Содержимое НЕ сверяется, только длины. Если dst≥src → эквивалент Skip.
- **Skip(3)**: существующий не трогать.
- **Refresh(4)**: перезаписать только если src новее (сравнение mtime); новых-в-приёмнике это не касается — копируются как обычно.
- **Ask(5)**: подиалог на КАЖДЫЙ конфликт (dn.dnr:3261 dlgOverwriteQuery 64×13): чекбокс "Accept choice for all files" + кнопки Overwrite/Append/Resume/Rename/Skip/Cancel. Resume-кнопка гаснет если dst≥src. Rename → InputBox нового имени. "For all" фиксирует постоянный режим.

## Чекбоксы (FILECOPY.PAS:146 cpo*)
- **Check free($01)**: `SysDiskFreeLongX` (=f_getfree) — сумма по кластерам до старта (>1 файла) + перед каждым файлом (с учётом освобождаемого существующего). Диалог "нет места" Yes/No/All.
- **Verify($02)**: после BlockWrite перечитать и сверить CRC; несовпадение → отмена.
- **Copy descriptions($04)**: перенос строки из descript.ion/files.bbs. У НАС нет → убрать пункт.
- **Copy access rights($08, WIN32)**: NTFS ACL. На FAT/DOS пункта нет → убрать. (Базовые атрибуты R/H/S/A + время копируются ВСЕГДА через SetDateAttr, независимо от чекбокса.)
- **Remove source($10)=Move**: после успешной копии f_unlink(src). На одном томе оптимизируется в f_rename (фолбэк copy+delete при NOT_SAME_DEVICE).

## ▼ = история ввода (histlist.pas), НЕ комбобокс каталогов
Стандартный THistory: список последних уникальных введённых путей (MaxHistorySize=20), сгруппирован по Id. Раскрывается стрелкой ▼/вниз. Порт: список ~16-20 уникальных путей на контекст "copy dest", сохранять в ini.

## Кнопка Tree = дерево каталогов (tree.pas)
Всплывает в приложение (DNUTIL.PAS:2955 cmTree→ExecTree): забирает текст поля → ChangeDir(дерево) → пишет выбранный путь обратно в поле.
- **Модель (tree.pas:83 TDirRec)**: плоский список узлов в порядке pre-order (обход в глубину), глубина в `Level`. Биты Attr: bit0="есть следующий брат на уровне", trHasBranch="есть дети".
- **Сканирование ReadTree (tree.pas:1797/300)**: корень Level0; для каждого узла FindFirst/FindNext (=f_opendir/f_readdir), подкаталоги вставляются сразу после родителя (AtInsert, Level+1), файлы суммируются в Size/NumFiles родителя; рестарт → pre-order. Второй проход: Number, агрегаты, биты Attr. **Кэш по буквам диска** DrvTrees[]; инвалидация cmRereadTree (после копий).
- **Отрисовка Draw (tree.pas:1653), CP866**: ├=195 (есть брат ниже) / └=192 (последний) / ─=196 (ветка "├──── ") / ┬=194 (есть дети, полный режим) / │=179 (вертикаль предка если у него есть братья ниже). Отступ 3 колонки/уровень; массив Levels[] хранит "нужна ли │" на каждом уровне-предке. Полный (не partial) режим в ChangeDir.
- **Путь узла GetDirName (tree.pas:1025)**: ходьба назад к первому предку с меньшим Level, склейка имён.
- Диалог TTreeDialog 50×18: TTreeView+скроллбар слева, info-строка (путь + "N files with M bytes"), кнопки OK/Drive/Reread/MkDir/Cancel. Навигация: скроллбар, QuickSearch (набор маски), Enter/OK→путь.

## Make directory (dn.dnr:2488 dlgMkDir 69×7)
Label "Directory name" + InputLine(+история hsMakeDir) + OK/Cancel/Help. Вложенные пути Dir1\Dir2\Dir3 создаются целиком; несколько через `;`. Запрещённые: `> < [ ] ? * + / %`.

## Приоритет реализации на FAT/SD
- **P0**: диалог Copy (поле + 6 радио + OK/Cancel/Tree/Help); Overwrite/Skip/Ask(+Rename,+for all); Remove source=Move; история ▼ (простая).
- **P1**: Refresh (mtime), Resume (f_lseek), Append (FA_OPEN_APPEND), Check free (f_getfree), дерево каталогов (полный режим, кэш) + MkDir в нём.
- **Убрать из UI**: Copy descriptions (нет descript.ion), Copy access rights (нет ACL на FAT).
- **P2/опц**: Verify writes (перечитать+CRC, дорого на SD), Drive-кнопка (один том), wildcards.

## Таблица реализуемости
| Фича | FAT/SD | Как |
|---|---|---|
| Overwrite | да | FA_CREATE_ALWAYS |
| Append | да | FA_OPEN_APPEND, дописать весь src |
| Resume | да | dst<src → f_lseek(src,dst_size), дописать |
| Skip | да | f_stat существует → пропуск |
| Refresh | да | перезапись только если src.mtime>dst.mtime |
| Ask(+for all,+Rename) | да | подиалог на конфликт |
| Check free space | да | f_getfree (сумма кластеров) |
| Verify writes | частично | перечитать+CRC (дорого) |
| Copy descriptions | нет | убрать (нет descript.ion) |
| Copy access rights | нет | убрать (нет ACL) |
| Remove source (Move) | да | f_unlink(src); одном томе f_rename |
| ▼ история | да | ~16 уникальных путей, dropdown, ini |
| Tree дерево | да | плоский pre-order (Level), f_opendir/readdir, ├└─┬│ (195/192/196/194/179), кэш |
| Make dir | да | f_mkdir, вложенность по \ |
| атрибуты/время | да | f_utime + f_chmod (chmod у нас off→только время) |
