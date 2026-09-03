# Ручная приёмка Stage 11 в MAME

Stage 11 использует статический адрес клиента `192.168.7.20`, TCP echo-сервис
`192.168.7.44:7777`, интерфейс responder `feth1` и интерфейс MAME `feth0`.
Подготовьте отдельный Stage 11 образ и запустите fault responder, затем MAME.

```sh
tools/stage11-mame.sh prepare
sudo tools/stage11-mame.sh responder faults
```

Во втором терминале:

```sh
tools/stage11-mame.sh mame
```

После загрузки DSS переключитесь на проверочную дискету, смонтированную
launcher-ом как второй floppy (`-flop2`). В обычной конфигурации DSS это диск
`B:`. Выполните `B:` и затем `DIR`; DSS не поддерживает аргумент у `DIR`,
поэтому `DIR TCPTEST.EXE` ошибочно печатает `Invalid filename`. Продолжайте
только если в листинге виден `TCPTEST.EXE`. Это не позволит случайно запустить
старую копию программы с HDD.

В DSS последовательно выполните:

```text
NETCFG -i
IFUP
TCPTEST -n 2 -l 0 192.168.7.44 7777
TCPTEST -n 2 -l 1 192.168.7.44 7777
TCPTEST -n 2 -l 535 192.168.7.44 7777
TCPTEST -n 2 -l 536 192.168.7.44 7777
TCPTEST -n 2 -l 537 192.168.7.44 7777
TCPTEST -n 2 -l 2048 192.168.7.44 7777
TCPTEST -n 2 -l 4096 192.168.7.44 7777
```

Для каждой команды ожидаются строки `[E1] channel=0 bytes=N` и
`[E1] channel=1 bytes=N`, затем `RESULT OK`. В responder-логе должны быть два
разных client port, `ESTABLISHED`, `DATA` и `FIN`. SYN должен заявлять MSS 536,
а каждый data segment должен быть не длиннее 536 байт; буферы 537, 2048 и 4096
обязаны пройти за несколько сегментов.

Fault-профиль должен один раз потерять SYN и data ACK, затем передать duplicate
и out-of-order segment. Повторите `TCPTEST -n 2 -l 2048 ...`: оба канала должны
закрыться с `RESULT OK`, в журнале ожидаются `DROP`, `OUT-OF-ORDER` и
`DUPLICATE`.

Отдельными сеансами проверьте профили `zero` и `reset`. В `zero` должны быть
видны bounded однобайтовые persist probes и последующее успешное открытие окна
без лишнего байта в echo-потоке. В `reset`
первое соединение сбрасывается, после чего `TCPTEST` выполняет один reconnect;
если профиль продолжает сбрасывать соединение, программа обязана завершиться
`RESULT FAIL`, а не зависнуть. Во время ожидания отдельно нажмите Esc и Ctrl+C:
ожидается `RESULT FAIL` и возврат в DSS.

После каждого сеанса остановите MAME и responder. Classic pcap должен содержать
валидные IPv4/TCP checksums, минимум два client source port, data и FIN/RST.
Проверьте соответствующий pcap командой
`tools/stage11-mame.sh pcap-check evidence/stage11/stage11-PROFILE.pcap`.
Сохраните полный responder log, pcap, screenshots команд и SHA-256 IMG/TCPTEST
по шаблону `docs/evidence/STAGE11_TEST_TEMPLATE.md`. Проверка на реальном
Sprinter/3C509B остаётся отдельным открытым пунктом.
