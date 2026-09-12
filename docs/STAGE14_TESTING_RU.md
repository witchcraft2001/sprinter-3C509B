# Ручная приёмка Stage 14 в MAME

`UNET509B.DLL` и `UNETTEST.EXE` проверяются иначе, чем предыдущие этапы:
`stage14_responder.py` — не симулятор сырых Ethernet-кадров (как
`stage7..stage13_responder.py`), а обычный TCP/UDP-пир поверх настоящего
хост-стека, потому что сама DLL говорит по-настоящему поднятым IPv4/TCP/UDP,
а не собирает кадры вручную для теста. Поэтому перед запуском MAME хостовому
интерфейсу нужен реальный IP-адрес:

```sh
sudo ifconfig feth1 192.168.7.44 netmask 255.255.255.0 up
```

(один раз на сессию стенда; `feth0`/`feth1` — та же пара, что и на остальных
этапах, см. `docs/MAME_NETWORK.md`). Sprinter получает статический
`192.168.7.21` из `config/STAGE14.CFG`.

Подготовьте образ и запустите MAME:

```sh
tools/stage14-mame.sh prepare
tools/stage14-mame.sh mame
```

В DSS сначала поднимите сеть, как для любой другой утилиты:

```text
NETCFG -i
IFUP
```

Ожидается `NET=509B`, опубликованные `NET_IP`/`NET_MAC`, и `RESULT OK`.

## Сценарий 0: использование и отсутствие DLL

```text
UNETTEST /?
UNETTEST -d MISSING.DLL
```

`/?`/без аргументов — печатает `Usage: UNETTEST [-d FILE.DLL] [-u UDPPORT
[SIZE]] [-2 DATAPORT]` и вторую строку продолжения, код возврата 1.
`-d MISSING.DLL` — `Cannot load DLL:` с причиной (`DLL file not found`),
подсказку про `-d DIR\FILE.DLL`, код возврата 2. Оба случая — до любого
обращения к ISA; сеть можно не поднимать.

## Сценарий A: обычный TCP CONNECT/SEND/RECV/CLOSE

Запустите на хосте, в отдельном терминале:

```sh
tools/stage14-mame.sh responder tcp-echo --port 8080
```

В DSS:

```text
UNETTEST 192.168.7.44 8080
```

Ожидается баннер `3C509B UNETTEST v...`, строка `DLL: ... v... caps=0x023F
abi=0x0100`, `net: NETINIT ok`, `connect 192.168.7.44:8080`, `request sent`,
затем эхо запроса обратно (`--- reply ---` и те же байты), `--- closed ---` и
`RESULT OK`. В логе responder'а — `CONN from 192.168.7.44:...` и `echoed N
bytes, closing`.

## Сценарий B: отказ в соединении

```sh
tools/stage14-mame.sh responder tcp-refuse --port 8081
```

```text
UNETTEST 192.168.7.44 8081
```

Порт никто не слушает — ОС хоста сама отвечает RST. Ожидается `failed` на
строке `connect`, `lasterr: 509B hw=1 st=02 nerr=04 ...` и `RESULT FAIL
code=...`. Killите responder (Ctrl+C) — сообщение в консоли скрипта
подтверждает, что порт умышленно не был занят.

## Сценарий C: UDP echo

```sh
tools/stage14-mame.sh responder udp-echo --port 7777
```

```text
UNETTEST -u 7777
UNETTEST -u 7777 1472
UNETTEST -u 7777 1473
```

Первые два — `RESULT OK`, эхо совпадает с отправленным паттерном; второй —
пограничный размер (ровно 1472 байта, MTU). Третий — `NERR_PARAM` без единого
кадра на проводе (responder не должен показать `DATAGRAM from ...` в логе).

## Сценарий D: два канала (`-2`)

```sh
tools/stage14-mame.sh responder dual --control-port 9099 --data-port 9100
```

```text
UNETTEST -2 9100 192.168.7.44 9099
```

Ожидается `connect control ...`, `connect data ...`, `request sent`, строка
про совпадение/несовпадение последовательности счётчика (должна быть
"OK"-версия), число принятых байт больше нуля и `RESULT OK`. В логе
responder'а — `CONTROL received b'UNETTEST DUAL CONTROL\r\n'` и `DATA conn
..., streaming counter`.

## Сценарий E: пассивное открытие (`-l` / LISTEN)

```text
UNETTEST -l 9000
```

Сразу после строки `net: NETINIT ok` UNETTEST переходит в ожидание пира на
порту 9000 (Sprinter — сервер, роли обратные всем предыдущим этапам). Пока
DSS ждёт, на хосте:

```sh
tools/stage14-mame.sh responder listen-client --port 9000
```

Ожидается на экране DSS: `peer accepted` дважды подряд (скрипт по умолчанию
подключается 2 раза, чтобы проверить повторное вооружение LISTEN после
CLOSE), `unlisten done`, `RESULT OK`. В логе скрипта — `connected`, `sent N
bytes`, `reply (N bytes): ...` на каждой из двух попыток.

## Сценарий F: неблокирующий SEND (`-a` / ASYNCSEND)

```sh
tools/stage14-mame.sh responder tcp-stall --port 8080 --rcvbuf 700 --stall 1.0
```

```text
UNETTEST -a 192.168.7.44 8080
```

Responder намеренно не читает сокет `--stall` секунд после accept, схлопывая
окно приёма — это единственный надёжный способ заставить `SEND` вернуть
`NERR_AGAIN` хотя бы один раз. **На macOS отключите авто-тюнинг приёмного
буфера перед этим тестом**, иначе ядро игнорирует запрошенный `--rcvbuf` и
`SEND` никогда не приостановится:

```sh
sudo sysctl -w net.inet.tcp.doautorcvbuf=0
# ... тест ...
sudo sysctl -w net.inet.tcp.doautorcvbuf=1
```

Если лог responder'а показывает `WARNING: accepted rcvbuf (...) holds the
whole 1200-byte payload` — тюнинг всё ещё активен, результат теста
недостоверен, `resumes needed: 0` ничего не доказывает. При корректной
настройке ожидается `resumes needed: N` с `N >= 1` и `RESULT OK`.

## Реальный Sprinter

Здесь `HOST` — адрес хоста в том же физическом сегменте, что и карта, а
Sprinter получает свой адрес из `NET.CFG` на карте. Ниже команды идут
парами: сначала хост, потом DSS. Дожидайтесь строки `READY ...` в логе
скрипта, прежде чем запускать команду на Sprinter.

Перед первым запуском проверьте, что нужный порт свободен. `Address already
in use` чаще всего означает не «порт занят системой», а прежний responder,
приостановленный по Ctrl+Z: остановленный процесс держит сокет открытым.
`ps aux | grep responder` покажет такие процессы в состоянии `T`; если
скрипт был запущен через `sudo`, обычный `lsof -i` его не увидит.

### 1. TCP: запрос и ответ

```sh
python3 tools/host/stage14_responder.py tcp-echo --bind HOST --port 8080
```

```text
UNETTEST HOST 8080
```

`--- reply ---` с эхом запроса, `--- closed ---`, `RESULT OK`. Пауза перед
`--- closed ---` — это ожидание FIN: responder закрывает соединение только
после своего таймаута чтения (`--timeout`, по умолчанию 10 с), а DSS опрашивает
приём блоками по 4 с.

### 2. UDP: эхо и граница MTU

```sh
python3 tools/host/stage14_responder.py udp-echo --bind HOST --port 7777
```

```text
UNETTEST -u 7777 HOST
UNETTEST -u 7777 1472 HOST
UNETTEST -u 7777 1473 HOST
```

Первые два — `RESULT OK` и `udp echo ok`. Третий — `RESULT FAIL code=3`,
`NERR_PARAM`, и в логе responder'а **не должно** появиться `DATAGRAM from`.

### 3. Отказ в соединении

Ничего на хосте запускать не нужно, порт должен быть свободен.

```text
UNETTEST HOST 8081
```

`failed` на строке `connect`, `lasterr: ... nerr=04`, `RESULT FAIL code=3`.

### 4. Пассивное открытие: Sprinter как сервер

Сначала DSS, потом хост — Sprinter должен уже ждать пира.

```text
UNETTEST -l 9000
```

```sh
python3 tools/host/stage14_responder.py listen-client --host SPRINTER --port 9000
```

`peer accepted` дважды подряд, `unlisten done`, `RESULT OK`.

Это единственный сценарий, где Sprinter — сервер, и вторая попытка в нём
важнее первой: она проверяет, что после закрытия соединения слушатель
встаёт на тот же порт заново. Путь пассивного открытия существует только в
сборке DLL; до `tools/stage14_listen_vectors.asm` его не исполнял ни один
автоматический тест, и этот вектор нашёл в нём два отказа — привязку
слушателя к мусорному порту и отсутствие перевооружения, когда соединение
закрывает пир, а не мы. Если клиент всё же отваливается по тайм-ауту,
снимите на хосте картину провода, она сразу разделяет два разных отказа:

```sh
sudo tcpdump -ni any -e "arp or (tcp port 9000)"
```

Нет ответа на `who-has SPRINTER` — карта не отвечает на ARP, пока ждёт пира.
Есть ARP-ответ и `Flags [S]` без `Flags [S.]` в обратную сторону — SYN дошёл,
но пассивное открытие его не приняло. Приложите вывод к отчёту.

### 5. Неблокирующий SEND

```sh
sudo sysctl -w net.inet.tcp.doautorcvbuf=0
python3 tools/host/stage14_responder.py tcp-stall --bind HOST --port 8080 --rcvbuf 700 --stall 1.0
```

```text
UNETTEST -a HOST 8080
```

`resumes needed: N` с `N >= 1` и `RESULT OK`. Если в логе есть `WARNING:
accepted rcvbuf ...`, авто-тюнинг всё ещё включён и результат недостоверен.
После теста верните `sudo sysctl -w net.inet.tcp.doautorcvbuf=1`.

### 6. Разрешение имени через DNS

Единственный путь, который ещё ни разу не исполнялся на железе: кодек DNS
живёт в cold-оверлее и включается только когда аргумент — имя, а не
числовой адрес. Нужен работающий `NET_DNS1` в `NET.CFG` и шлюз.

```text
UNETTEST example.com 80
```

`resolve:` должен показать числовой адрес, дальше обычный обмен HTTP HEAD.
Ошибка на строке `resolve` — это отказ DNS, а не TCP.

### 7. Два канала и usage

```sh
python3 tools/host/stage14_responder.py dual --bind HOST --control-port 9099 --data-port 9100
```

```text
UNETTEST -2 9100 HOST 9099
UNETTEST /?
UNETTEST -d MISSING.DLL
```

Для `-2` — `data stream continuous`, ненулевое число байт, `RESULT OK`.
`/?` — код 1, `-d MISSING.DLL` — код 2.

Сохраните вывод `stage14_responder.py` и, если есть возможность захвата на
этом сегменте, pcap для тестов 1 и 5.

## Доказательства

Соберите для `docs/evidence/STAGE14_TEST_TEMPLATE.md`: скриншоты/транскрипты
сценариев 0 и A-F; логи `stage14_responder.py` для каждого сценария; sha256
образа, `UNET509B.DLL` и `UNETTEST.EXE`; для реального Sprinter — то же самое
плюс модель карты и сегмент сети. До появления этих файлов флажки MAME и
"Реальная карта" в сводной таблице `specs.md` остаются открытыми.

Оптимизированный RX DLL принимается тем же `DLSPEED`-замером, что дополнение
Stage 13: пять чередующихся успешных запусков `DLDIRECT`/`DLSPEED` на
release- и fast-образах, точные 4194304 байт, `RESULT OK`, валидные исходящие
checksum, FIN без RST, повторный запуск, консольный лог и pcap. Пороговые
медианы и признаки окна/накопительных ACK приведены в `docs/DLSPEED.md`.
Эти результаты нужны отдельно для MAME и реального Sprinter и до появления
фактических файлов не закрывают ни один флажок Stage 13/14.
