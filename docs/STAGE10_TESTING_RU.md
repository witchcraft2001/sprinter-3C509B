# Ручная приёмка Stage 10 в MAME

До ручного сеанса выполните автоматический gate:

```sh
make clean
make test-host package image
```

Stage 10 использует один DHCP/DNS/NTP/UDP/TFTP responder и один непрерывный
сеанс MAME. По умолчанию responder работает на `feth1`, а MAME — на `feth0`.

Подготовьте отдельный DHCP-образ и детерминированные TFTP fixtures:

```sh
tools/stage10-mame.sh prepare
```

`prepare` запускается без `sudo`. Если каталог `build/stage10-mame` ранее был
создан от `root`, один раз исправьте владельца командой, которую напечатает
скрипт, затем повторите `prepare` без `sudo`.

В терминале 1 запустите fault-профиль и дождитесь строки `READY`:

```sh
sudo tools/stage10-mame.sh responder faults
```

В терминале 2 запустите MAME:

```sh
tools/stage10-mame.sh mame
```

Другие имена интерфейсов задаются отдельно для двух процессов:

```sh
sudo env STAGE10_RESPONDER_INTERFACE=<responder-if> \
  tools/stage10-mame.sh responder faults
STAGE10_MAME_INTERFACE=<mame-if> tools/stage10-mame.sh mame
```

После загрузки DSS последовательно выполните в окне MAME:

Сначала переключитесь на проверочную дискету, которую launcher смонтировал как
второй floppy (`-flop2`). В обычной конфигурации DSS это `B:`. Выполните `B:`,
затем `DIR S9PUT.BIN` и продолжайте только если fixture виден. Так TFTP читает
и пишет подготовленный образ, а не старые одноимённые файлы на HDD.

После баннера TFTP не должно быть искусственной секундной паузы: клиент
использует заранее рассчитанный для 21 МГц `CYCLES21`-таймер. Esc или Ctrl+C
в любом сетевом ожидании должны завершить программу с `RESULT FAIL code=23` и
вернуть управление DSS.

```text
NETCFG -i
IFUP
NETCFG
IFUP -r
NSLOOKUP echo.stage10.test
PING -n 1 echo.stage10.test
UDPTEST -n 10 -l 1472 echo.stage10.test 7777
TFTP tftp.stage10.test:6969 GET S9GET.BIN -y
TFTP tftp.stage10.test PUT S9PUT.BIN
NTP
NSLOOKUP example.com 1.1.1.1
NTP pool.ntp.org
IFUP -d
NETCFG
```

Все штатные команды должны завершиться `RESULT OK`. После acquire и renewal
`NETCFG` должен показывать DHCP address, server, lease и DNS. Локальные имена
должны разрешаться в `192.168.7.44`; UDP и оба TFTP-направления должны пережить
детерминированные `DROP`, `RETRY`, duplicate, stale port/ID и malformed replies.

При `TZ=+5:45` локальный NTP возвращает фиксированное
`2025-01-01 17:44:59 UTC+05:45`; только после полной проверки ответа программа
вызывает `DSS_SETTIME`. Публичные DNS и NTP запросы проходят через UDP proxy
responder без изменения host NAT/PF. Их фактические ответы зависят от внешней
сети, поэтому сохраните и вывод DSS, и строки `PROXY`.

После `IFUP -d` повторный `NETCFG` не должен содержать динамические IP, DNS,
DHCP server и lease. В responder-логе должна присутствовать строка `RELEASE`.
Повторный `IFUP -d` допустимо дополнительно проверить: он завершается успешно и
не создаёт новый DHCP frame.

Закройте MAME и responder. Затем проверьте TFTP и classic pcap без FCS:

```sh
tools/stage10-mame.sh verify
tools/stage10-mame.sh pcap-check evidence/stage10/stage10-faults.pcap
```

Ожидаются `VERIFY OK` и `PCAP OK` с DHCP, DNS, NTP, RELEASE, UDP echo и TFTP.
Сохраните полный responder log, pcap, screenshots всех DSS-команд и SHA-256
IMG/EXE по шаблону `docs/evidence/STAGE10_TEST_TEMPLATE.md`. Только после этого
создайте `STAGE10_MAME_YYYY-MM-DD.md` и отметьте MAME gate. Проверка на реальном
Sprinter/3C509B остаётся отдельным открытым пунктом.
