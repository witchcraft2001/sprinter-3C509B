# Ручная приёмка Stage 8 в MAME

Автоматический gate выполняется разработчиком заранее. Для ручной проверки
нужны два терминала и именованные интерфейсы: MAME - `feth0`, responder -
`feth1`. Подготовить отдельный static-образ один раз:

```sh
tools/stage8-mame.sh prepare
```

Для каждого сценария сначала дождитесь `READY` в терминале responder-а:

```sh
sudo tools/stage8-mame.sh responder echo
tools/stage8-mame.sh mame echo
```

После каждого перезапуска MAME в DSS заново выполните `NETCFG -i` и `IFUP`:
это применяет статический адрес к новой сессии DSS. Перезапуск только responder
не требует повторного `NETCFG`/`IFUP`. В DSS уже установлен адрес
`192.168.7.20/24`, шлюз `192.168.7.1`. Выполните:

```text
NETCFG -i
IFUP
PING -n 1 192.168.7.44
PING -n 1 192.168.7.1
PING -n 1 203.0.113.10
PING -n 1 -l 0 -i 1 192.168.7.44
PING -n 1 -l 1 -i 255 192.168.7.44
PING -n 1 -l 32 192.168.7.44
PING -n 1 -l 1472 192.168.7.44
PINGALT -n 1 192.168.7.44
PINGALT -n 1 203.0.113.10
```

Повторите запуск responder/MAME для негативных сценариев:

```sh
sudo tools/stage8-mame.sh responder noise
tools/stage8-mame.sh mame noise
# в DSS: PING -n 1 192.168.7.44

sudo tools/stage8-mame.sh responder unreachable
tools/stage8-mame.sh mame unreachable
# в DSS: PING -n 1 203.0.113.10

sudo tools/stage8-mame.sh responder drop
tools/stage8-mame.sh mame drop
# в DSS: PING -n 1 192.168.7.44
```

`noise` должен закончиться корректным reply после unrelated reply и пакетов с
плохими checksum/payload; такие кадры намеренно не печатаются. `unreachable`
ожидает `RESULT FAIL code=24` и DSS exit 6. `drop` ожидает конечный `[E2]
TIMEOUT` и `RESULT FAIL code=14`, без зависания. Отдельно запустите
`PING -t 192.168.7.44` в `echo` и отмените его клавишей Esc или Ctrl+C;
ожидается `RESULT FAIL code=23` и DSS exit 7 (это штатная отмена Stage 8, не
успешное завершение). Для Ctrl+C фокус должен быть на окне MAME (зажмите
левый Ctrl и нажмите C), а не на терминале, в котором запущен MAME. Для
разумной ручной endurance-проверки выполните `PING -n 100 -l 0 192.168.7.44`;
автоматический actual-EXE gate отдельно проверяет 1000 запросов.

Проверка byte-exact classic pcap без FCS (используйте `echo.pcap`, поскольку
`noise.pcap` намеренно содержит повреждённые пакеты):

```sh
tools/stage8-mame.sh pcap-check evidence/stage8/echo.pcap
```

Сохраните screenshots полного вывода, pcap и SHA-256 IMG/PING/PINGALT по
шаблону `docs/evidence/STAGE8_TEST_TEMPLATE.md`. Эти данные закрывают только
MAME gate; реальный Sprinter/3C509B остаётся отдельным открытым пунктом.
