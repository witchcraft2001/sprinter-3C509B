# Stage 6 MAME network setup

Интерфейс нельзя зашивать в проект: сначала получите допустимые имена из той
же сборки MAME:

```sh
$MAME_BIN -networkprovider pcap -listnetwork
```

Launcher принимает имя через `MAME_NETWORK_INTERFACE`, проверяет его по этому
списку, переводит в индекс MAME и записывает локальный `cfg/sprinter.cfg`.
Если provider не задан, при наличии interface автоматически выбирается pcap.

Для текущего macOS-стенда используется peer-пара `feth0/feth1`: MAME работает
через `feth0`, host helper и `tcpdump` — через `feth1`.

После запуска проверьте сгенерированный конфиг и сопоставьте числовой индекс с
тем же свежим выводом `mame -listnetwork`: список интерфейсов может меняться
(например, при появлении `utun`), поэтому индексы нельзя зашивать в отчёт или
переиспользовать без повторной проверки.

```sh
MAME_NETWORK_INTERFACE=feth0 MAME_NETWORK_PROVIDER=pcap tools/3com.sh
# Ограничьте capture кадрами теста: без BPF `-c 1` может завершиться
# на первом ARP/служебном пакете.
sudo tcpdump -i feth1 -e -nn -s 0 -c 1 \
  'ether proto 0x88b5 and ether src 02:60:8C:12:34:56' \
  -w stage06.pcap
sudo python3 tools/host/ethernet_helper.py send \
  --interface feth1 --destination 02:60:8C:12:34:56 \
  --source 02:00:00:00:00:01 --length 60 --pattern INC --count 10
python3 tools/host/ethernet_helper.py verify-pcap stage06.pcap \
  --destination 02:00:00:00:00:01 --source 02:60:8C:12:34:56 \
  --length 60 --pattern INC --count 10
```

`verify-pcap` принимает только classic pcap/Ethernet и проверяет destination,
source, EtherType, входную и wire длину, pattern, нулевой padding, burst order и
то, что capture/wire length не содержат четыре байта FCS.
