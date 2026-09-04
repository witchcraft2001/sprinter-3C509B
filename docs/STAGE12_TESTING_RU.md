# Ручная приёмка Stage 12 в MAME

Используется отдельный образ Stage 12 со статическим адресом `192.168.7.20`,
DNS/HTTP responder `192.168.7.44` и именем `wget.stage12.test`. До запуска MAME
подготовьте образ и запустите responder в том же host-only Ethernet-сегменте.
Сохраните его текстовый лог и pcap на протяжении всей проверки.

В DSS выполните по порядку:

```text
WGET /?
WGET http://wget.stage12.test/ZERO.BIN -y
WGET http://wget.stage12.test/SMALL.BIN -y
WGET http://wget.stage12.test/LARGE.BIN -y -d
WGET http://wget.stage12.test/CLOSE.BIN -y
WGET http://wget.stage12.test/redirect -o REDIR.BIN -y
WGET http://wget.stage12.test/absolute -o ABS.BIN -y
WGET http://wget.stage12.test/RANGE.BIN -r
WGET http://wget.stage12.test/404 -o ERR404.BIN -y
WGET http://wget.stage12.test/500 -o ERR500.BIN -y
```

Ожидается точный sibling-compatible баннер/CLI. Успешные операции печатают
`Resolved`, `Connecting ...ESTABLISHED.`, прогресс, `Done. N bytes received.`,
time/speed summary и `RESULT OK`. В режиме `-d` появляются точки по одной на
каждую 8-КиБ запись, но summary остаётся. Redirect печатает строку
`Redirect: HTTP/1.0 ...`. Обе ошибки HTTP печатают исходную status line и
`RESULT FAIL`, а `ERR404.BIN`/`ERR500.BIN` не остаются на диске.

Перед тестом `RANGE.BIN` должен содержать подготовленный префикс в 65536 байт.
После `-r` запрос содержит `Range: bytes=65536-`, ответ равен 206, а итоговый
файл побайтно совпадает с полным fixture. Проверьте также prompt без ключей:
повторите `SMALL.BIN`, по очереди выберите `O`, `R` и `C`; клавиша должна
отобразиться, а `C` — закончиться строкой `Aborted by user.`. Для уже полностью
загруженного `SMALL.BIN` выбор `R` закономерно получает HTTP 416 и сохраняет
исходный файл; успешный resume проверяется отдельно на подготовленном
`RANGE.BIN`.

Во время большой загрузки один раз нажмите Esc или Ctrl+C. Ожидаются сохранённый
partial-файл, `Aborted by user (Esc/Ctrl+C).`, `RESULT FAIL` и возврат в DSS без
зависания. Повторите этот файл с `-r` и убедитесь, что checksum восстановлен.

Соберите доказательства одного непрерывного gate: screenshots help, prompt,
full/resume, redirect и ошибок; responder log; pcap; checksum образа,
`WGET.EXE`, fixtures и файлов, извлечённых из FAT12. Заполните
`docs/evidence/STAGE12_TEST_TEMPLATE.md`. До наличия этих файлов MAME-флажок в
`specs.md` остаётся открытым; проверка реальной карты выполняется отдельно.
