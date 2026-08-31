# Ручная приёмка Stage 7 в MAME

Автоматический gate перед этим сеансом:

```sh
make clean
make test-host package image
```

Команды ниже используют имена интерфейсов, а не нестабильные числовые индексы.
MAME подключён к `feth0`, responder и tcpdump — к `feth1`.

```sh
mkdir -p evidence/stage7
../mame_images/mame_release_v306_25.05.2025/mame -networkprovider pcap -listnetwork \
  | tee evidence/stage7/mame-listnetwork.txt
sudo python3 tools/host/stage7_responder.py --interface feth1 \
  --pcap evidence/stage7/dhcp-arp.pcap
MAME_NETWORK_INTERFACE=feth0 MAME_3C509B_SLOT=1 \
  MAME_CFG_DIR="$PWD/evidence/stage7/mame-cfg-up" tools/3com.sh
```

Дождитесь строки `READY` responder до запуска сетевой команды. В DSS скопируйте
`NETSMPL.CFG` в `NET.CFG`, затем выполните и сохраните полный вывод:

```text
NETCFG -c -v
NETCFG -i -v
IFUP
ARP 192.168.77.1
ARP 192.168.78.1
ARP 255.255.255.255
ARP 192.168.77.255
ARP 192.168.77.254
```

Для каждой отдельной негативной ветки перезапустите responder и MAME, не меняя
номер интерфейса вручную:

NAK-тест выполняется строго в двух терминалах. В терминале 1 запустите responder
и оставьте его работающим:

```sh
sudo python3 tools/host/stage7_responder.py \
  --interface feth1 \
  --dhcp nak \
  --server-ip 192.168.7.1 \
  --offer-ip 192.168.7.150 \
  --router 192.168.7.1 \
  --pcap evidence/stage7/dhcp-nak.pcap \
  --count 2
```

В терминале 1 сначала должна появиться строка:

```text
READY interface=feth1 arp=reply dhcp=nak
```

Затем, в терминале 2, запустите отдельный MAME с новым каталогом конфигурации:

```sh
MAME_NETWORK_INTERFACE=feth0 \
MAME_NETWORK_PROVIDER=pcap \
MAME_3C509B_SLOT=1 \
MAME_CFG_DIR="$PWD/evidence/stage7/mame-cfg-nak" \
tools/3com.sh
```

В MAME скопируйте шаблон и запустите только:

```text
COPY NETSMPL.CFG NET.CFG
NETCFG -i -v
IFUP
```

В терминале 1 после `IFUP` должны появиться ровно:

```text
FRAME 1 DHCP
FRAME 2 DHCP
```

А в MAME:

```text
[I1] DHCP OFFER
[I2] DHCP NAK
RESULT FAIL code=6
```

После завершения NAK-responder-а запустите следующие сценарии отдельно:

```sh
sudo python3 tools/host/stage7_responder.py --interface feth1 --dhcp drop \
  --pcap evidence/stage7/dhcp-timeout.pcap
sudo python3 tools/host/stage7_responder.py --interface feth1 --arp drop \
  --pcap evidence/stage7/arp-timeout.pcap
```

Responder реактивный: до запуска `IFUP` он печатает только `READY` и ждёт
кадры. В NAK-сценарии после запуска `IFUP` обязательны две строки `FRAME 1
DHCP` и `FRAME 2 DHCP` (OFFER и NAK). Если `FRAME` нет, это не NAK-тест, а
отсутствие трафика между MAME и responder; `IFUP` закономерно завершится
`TIMEOUT stage=DHCP_OFFER ...` с `RESULT FAIL code=14`.

В NAK и timeout случаях `IFUP` должен закончиться `RESULT FAIL`, а `NET_IP`,
`NET_MASK`, `NET_GW`, `NET_DNS1`, `NET_DNS2`, `NET_DHCP_SRV` и
`NET_LEASE_SEC` после `NETCFG` должны оставаться пустыми.

Retry проверяется без ручной гонки по времени. Запустите новый responder до
`IFUP`; он захватит, но намеренно проигнорирует первый DISCOVER:

```sh
sudo python3 tools/host/stage7_responder.py --interface feth1 \
  --ignore-dhcp 1 --count 2 \
  --pcap evidence/stage7/dhcp-retry.pcap
```

После `IFUP` responder должен напечатать `DROP 1 DHCP`, затем `FRAME 1 DHCP` и
`FRAME 2 DHCP`. MAME должен получить OFFER только после повторного DISCOVER,
затем ACK и закончить `RESULT OK`. В pcap ожидается точная последовательность
`DISCOVER, DISCOVER, OFFER, REQUEST, ACK`.

Неизвестный ARP должен выполнить ровно три двухсекундные попытки.

Link-down проверяется отдельным MAME без backend; опускание `feth0` не меняет
carrier модели:

```sh
MAME_CFG_DIR="$PWD/evidence/stage7/mame-cfg-down" tools/3com.sh
```

После `IFUP` ожидается конечный link timeout. Затем снова запустите с
`MAME_NETWORK_INTERFACE=feth0`: link-up обязан пройти.

Classic pcap responder-а записывает captured/wire length, равные длине каждого
Ethernet кадра, без FCS. Проверить заголовки и длины можно одной командой:

```sh
python3 - evidence/stage7/dhcp-arp.pcap <<'PY'
import struct, sys
d=open(sys.argv[1],'rb').read(); o=24
while o < len(d):
    _,_,cap,wire=struct.unpack_from('<IIII',d,o); o+=16
    f=d[o:o+cap]; o+=cap
    assert cap == wire and len(f) == cap
    print(cap, f[:14].hex())
PY
```

В evidence сохранить console output/screenshots для static NETCFG/IFUP, DHCP
ACK/retry/NAK/timeout, ARP neighbor/gateway/broadcast/unknown и link down/up,
а также все pcap и SHA-256 IMG/EXE. Шаблон:
`docs/evidence/STAGE7_TEST_TEMPLATE.md`. Это ручной MAME gate Stage 8;
автоматические тесты его не заменяют.
