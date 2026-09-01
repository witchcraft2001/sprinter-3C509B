# Ручная приёмка Stage 9 в MAME

Автоматический gate выполняется заранее командой `make test-host package
image`. Ручная часть использует один responder и один сеанс MAME. По умолчанию
интерфейсы называются `feth1` для responder и `feth0` для MAME.

Подготовьте отдельный static-образ и детерминированные GET/PUT fixtures
(один раз, до запуска MAME):

```sh
tools/stage9-mame.sh prepare
```

Откройте два терминала. В терминале 1 запустите fault-профиль и оставьте
responder работать до конца сеанса:

```sh
sudo tools/stage9-mame.sh responder faults
```

Дождитесь в терминале 1 строки `READY`. Затем в терминале 2 запустите один
сеанс MAME:

```sh
tools/stage9-mame.sh mame
```

Команда `mame` запускает графическое окно MAME с образом
`build/stage9-mame/stage9-static.img`. Дождитесь загрузки DSS и появления
командной строки. Следующие команды вводятся **в окне MAME, в DSS**, а не в
shell-терминале. Responder продолжает работать в терминале 1.

Если имена интерфейсов отличаются от `feth1`/`feth0`, задайте переменные при
запуске соответствующего процесса:

```sh
sudo env STAGE9_RESPONDER_INTERFACE=<responder-if> \
  tools/stage9-mame.sh responder faults
```

Во втором терминале:

```sh
STAGE9_MAME_INTERFACE=<mame-if> \
tools/stage9-mame.sh mame
```

Повторно запускать responder или MAME между командами DSS не нужно. Перезапуск
требуется только для нового независимого прогона.

После загрузки DSS в окне MAME последовательно выполните:

```text
NETCFG -i
IFUP
UDPTEST -n 10 -l 1472 192.168.7.44 7777
TFTP 192.168.7.44:6969 GET S9GET.BIN
TFTP 192.168.7.44 PUT S9PUT.BIN
TFTP 192.168.7.44:6969 GET S9GET.BIN
N
TFTP 192.168.7.44:6969 GET S9GET.BIN -y
```

Первые три сетевые команды должны закончиться `RESULT OK`. Fault-профиль
детерминированно вносит потерю request/DATA/ACK, duplicate, reorder и пакет с
неверным TID; в responder-логе должны появиться `DROP`, `RETRY` и `TFTP`.
Первая повторная GET должна показать Y/N prompt; ответ `N` заканчивается
`RESULT FAIL code=23` и DSS exit 7, не меняя файл. GET с `-y` должна успешно
заменить его.

Закройте MAME и responder, затем выполните побайтную проверку обоих направлений
и strict classic-pcap без FCS:

```sh
tools/stage9-mame.sh verify
tools/stage9-mame.sh pcap-check evidence/stage9/stage9-faults.pcap
```

Ожидаются `VERIFY OK` и `PCAP OK`. Сохраните полный responder log, pcap,
screenshots каждой DSS-команды и SHA-256 IMG/UDPTEST/TFTP по шаблону
`docs/evidence/STAGE9_TEST_TEMPLATE.md`. Только после этого можно добавить
`STAGE9_MAME_YYYY-MM-DD.md` и отметить MAME gate. Проверка на реальном
Sprinter/3C509B остаётся отдельным открытым пунктом.
