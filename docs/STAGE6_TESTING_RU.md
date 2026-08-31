# Общая ручная приёмка Stage 5 и Stage 6

Это согласованный порядок исключения 5→6: сначала собирается финальный IMG с
`EL3LB`, `EL3TX` и `EL3RX`, после чего Stage 5 и Stage 6 проверяются одним
ручным сеансом MAME. До появления файлов evidence оба этапа остаются открыты.
Stage 7 не начинается до проверки реальной 3C509B-TPO.

Перед сеансом сохраните версии инструментов, вывод `mame -listnetwork`, точный
интерфейс, SHA-256 IMG и трёх EXE. Для текущей пары подключите MAME к `feth0`,
а `tcpdump`/helper к `feth1`; имена всё равно передаются параметрами.

Stage 5:

- оба ISA slot, AUTO и явные базы `#200/#300/#3E0`;
- `EL3LB -n 1` и representative `EL3LB -n 100`;
- no-card и invalid args;
- smoke повторного `EL3REG -n 1`/INIT/DONE.

Stage 6:

- TX unicast и broadcast, длины 14/60/61/1514, burst 10;
- RX individual и broadcast, длины 60/1514, burst 10;
- чужой unicast не принимается;
- link down даёт конечный диагностический code 20 и DSS exit code 3, после
  link up повтор проходит;
- classic pcap совпадает побайтно и не содержит FCS в captured/wire length.

Для TX используйте фильтр tcpdump по EtherType и MAC карты. Опция `-c 1`
без BPF может завершить захват на первом служебном ARP-пакете ещё до запуска
теста:

```sh
sudo tcpdump -i feth1 -e -nn -s 0 -c 1 \
  'ether proto 0x88b5 and ether src CARD_MAC' \
  -w evidence/stage56/tx.pcap
```

Для burst из десяти кадров замените `-c 1` на `-c 10`. Для RX фильтр должен
использовать `ether dst CARD_MAC`, поскольку кадры идут от host к карте.
Сначала запустите `EL3RX` и дождитесь строки `[R1] LINK=UP`, и только затем
отправляйте кадр helper-ом: окно ожидания ограничено `-w`, и заранее
отправленный кадр не является доказательством RX.

Для link-down в MAME не используйте `ifconfig feth0 down`: модель считает
carrier включённым, пока к карте подключён network backend. Запустите отдельный
экземпляр без `MAME_NETWORK_INTERFACE` (в новом `MAME_CFG_DIR`) и проверьте
`EL3TX -w 100` — ожидается `code=20`. После этого перезапустите MAME с
`MAME_NETWORK_INTERFACE=feth0`; повторный TX должен дать `RESULT OK`.

Полный console output, screenshots, pcap и команды занесите в
`docs/evidence/STAGE6_TEST_TEMPLATE.md`. MAME-флажки в `specs.md` разрешено
ставить только после этого совместного прогона. Реальная карта проверяется
отдельно и не заменяется harness/MAME.
