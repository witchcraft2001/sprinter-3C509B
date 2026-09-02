# Быстрый старт Sprinter 3C509B Network Kit

Версия 0.0.1 включает локальную реализацию этапов до Stage 10: polling-only
`NETDRV`, DHCP, ARP, PING, DNS, NTP и TFTP. Read-only диагностики `EL3INFO`,
`EL3EEP` и `ISAPROBE` сохранены; EEPROM writes и IRQ routing отсутствуют.

## Сборка на хосте

Установите `sjasmplus`, mtools, `zip`, `unzip`, `iconv` и Perl, затем выполните:

```sh
make clean
make build
make test-host
make package
make image
```

Перед первой настройкой на реальном Sprinter начните с безопасной диагностики:

```text
EL3INFO -s 1 -p #110 -b AUTO
```

Ожидаемый вывод:

```text
3C509B EL3INFO v0.0.1
[E0] SLOT=1 IDPORT=0110
[E1] PRODUCT=9550 IO=0300
[E2] MAC=...
[E3] IRQ=... (not used by Sprinter)
RESULT OK
```

Код возврата — `0`. Затем скопируйте `NETSMPL.CFG` в `NET.CFG`, задайте
`IP=DHCP` и выполните `NETCFG -i`, `IFUP`. Для проверки сервисов используйте
`NSLOOKUP`, `PING`, `NTP` и `TFTP`; `IFUP -r` продлевает lease, а `IFUP -d`
выполняет best-effort RELEASE и очищает динамическое окружение.

Автоматический harness не заменяет ручную MAME-приёмку и проверку физической
карты. Текущие открытые gates и ссылки на evidence перечислены в `specs.md`;
Stage 10 MAME-процедура описана в `docs/STAGE10_TESTING_RU.md`.
