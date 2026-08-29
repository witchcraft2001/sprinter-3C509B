# Этап 1: аудит 3C509B и clean-room контракт драйвера

Дата аудита: 2026-08-29. Целевая карта: 3Com EtherLink III
3C509B-TPO, ISA8, 10BASE-T, half duplex. Целевая среда: Sprinter DSS.

## 1. Результат и границы

Этот документ фиксирует аппаратный контракт до появления Z80-драйвера:

- classic ID-port discovery и EEPROM read;
- окна, регистры, команды, status bits и обязательные задержки;
- безопасные polling-последовательности INIT, TX, RX и recovery;
- различия руководства 3Com, Nestor, Linux и текущей модели MAME;
- части референсов, которые нельзя переносить в BSD-исходники.

Локальная документальная часть этапа 1 выполнена. Этап 1 не закрыт: product
ID, EEPROM, MAC, I/O base, PnP и resource settings физической карты ещё не
сняты внешними средствами. Этот отчёт также не разрешает переход к написанию
драйвера, пока обязательные runtime-проверки этапа 0 остаются открытыми.

## 2. Источники и воспроизводимость

Приоритет источников остаётся заданным в `specs.md`: руководство 3Com,
физическая карта, Nestor, Linux, затем MAME.

| Источник | Зафиксированная версия | SHA-256 проверенного файла | Роль |
|---|---|---|---|
| [3Com EtherLink III Drivers Technical Reference](https://www.ardent-tool.com/NIC/3c5x9b_Technical_Reference.pdf) | 09-0398-002B, August 1994, 142 PDF pages | `7f05d1245f58aaae575a32b7df63c8f3f978a396ac74bbed1cbb8b1270758681` | Авторитетный аппаратный контракт |
| [Nestor DOS packet driver](https://github.com/AzureCloudMonk/3Com-3C509B-nestor-DOS-driver/commit/20384c78615159b9c5162fb1b71d4a55940efbcc) | commit `20384c78615159b9c5162fb1b71d4a55940efbcc`, `3c509.asm` | `1186b53ab7f128a5caa13381e710c9271546b9db1064d06d3da5c1c931ce64fd` | Наблюдаемые ISA/XT-последовательности |
| [Linux 3c509 driver](https://github.com/torvalds/linux/blob/v6.6/drivers/net/ethernet/3com/3c509.c) | tag `v6.6`, `drivers/net/ethernet/3com/3c509.c` | `17eb08a50adf8c32cd465d041b7d6f8a72f0c25df02687fbff6cfc9a795eebc1` | Независимая проверка последовательностей |
| [Linux 3c509 documentation](https://www.kernel.org/doc/html/v6.6/networking/device_drivers/ethernet/3com/3c509.html) | kernel documentation v6.6 | N/A (HTML) | Ограничения Linux driver и PnP context |
| Локальная MAME model | base commit `0239c2b025597e2e54b18ee4e682ac63038a06b6`, dirty working tree | `3c509b.cpp`: `7590b6222974109105dbd511e922ee00ae5d4c1852224073de8703d22a15850a`; `3c509b.h`: `f12fb7b0acbe1d75c0e7723143a7720c3e821ed0bc5ae61018eb2e079120f6eb` | Проверяемая реализация, не источник истины |

Для Nestor проверялся только текст `3c509.asm`. Бинарные `3c509.com`,
`3C5X9CFG.EXE`, `3ccfg.exe` и архивы из репозитория не анализировались и не
включаются в проект. Linux проверялся на immutable tag `v6.6`, а не по
изменяемому `master`.

Локальный MAME на момент аудита содержит незакоммиченные соседние изменения:
`MAME_3C509B_ISA8.md`, `scripts/src/bus.lua`, `3c509b.cpp`, `3c509b.h` и
`isa_cards.cpp`. Их нельзя сбрасывать или переписывать без отдельного аудита.

## 3. Clean-room граница

Nestor содержит GPL-код Crynwr и дополнительное уведомление 3Com; Linux
`3c509.c` распространяется под GPL-2.0. Из этих файлов разрешено переносить
только наблюдаемое поведение на уровне операций: порядок команд, значения
регистров, ожидания и ветви ошибок. Запрещено переносить инструкции, labels,
структуру процедур, комментарии, macros или isomorphic control flow.

Правила будущей реализации:

1. Константы и семантика берутся из руководства 3Com.
2. Таблица ниже используется как cross-check практического порядка операций.
3. Z80-код пишется заново с интерфейсом Sprinter ISA8 и конечными timeout.
4. Любая коллизия референсов решается в пользу руководства и трассы реальной
   карты.
5. IRQ-код Nestor/Linux не переносится: у Sprinter IRQ ISA сознательно не
   подключены.
6. EEPROM остаётся read-only. Конфигурационные бинарники Nestor/3Com и команды
   erase/write не используются.

## 4. Аппаратный контракт 3C509B-TPO

### 4.1. Classic ISA activation

- Допустимые ID ports: `0x100..0x1F0`, шаг `0x10`; default проекта `0x110`.
- В выбранный ID port записываются два нуля. Первый выбирает порт, второй
  сбрасывает state machine.
- Затем записываются 255 LFSR bytes. Первый byte `0xFF`, feedback polynomial
  `0xCF`, последний byte `0x98`; ноль в последовательности не встречается.
- Неверный byte возвращает ожидаемое значение к `0xFF`.
- После 255 bytes карта входит в ID command state.
- `0x80..0xBF` выбирает EEPROM word `command & 0x3F`; после завершения read
  шестнадцать чтений ID port возвращают word MSB-first в bit 0.
- `0xC0..0xCF` выполняет global reset; карта невидима до окончания AUTOINIT.
- `0xD0..0xD7` задаёт tag, `0xD8..0xDF` выполняет tag test.
- `0xE0..0xFE` активирует карту и заменяет пять I/O-base bits значением
  `command & 0x1F`; `0xFF` активирует EEPROM base без замены.
- Base index `0x00..0x1E` кодирует
  `base = 0x200 + index * 0x10`; `0x1F` означает EISA и для Sprinter
  отклоняется.
- После global reset EEPROM/autoinit занимает 310 us. Драйвер использует
  более консервативную конечную задержку не менее 1 ms до нового доступа.

Версия 1 поддерживает одну карту. Contention/tag всё равно реализуются по
документации, но multi-adapter enumeration не является публичной функцией.

### 4.2. EEPROM read-only layout

| Word | Назначение | Проверка для 3C509B-TPO |
|:---:|---|---|
| `00..02` | Factory node address | Шесть MAC bytes, два последовательных network bytes на word |
| `03` | Product ID | Exact `0x9550`; семейная mask может использоваться только в диагностике |
| `04..06` | Manufacturing data | Записать как read-only evidence |
| `07` | Manufacturer ID | `0x6D50` |
| `08` | Address Configuration | XCVR/ROM/auto-select и пятибитный base index |
| `09` | Resource Configuration | IRQ и synchronous-ready; IRQ только показывается |
| `0A..0C` | OEM node address | Записать и сравнить с factory MAC |
| `0D` | Software Information | Link beat policy и maximum interrupt-disable hint |
| `0E` | Compatibility Word | Fail/warning levels |
| `0F` | Primary checksum | High/low XOR lanes для words `00..0E` |
| `10` | Capabilities | Документированный ISA default `0x2083` |
| `11` | Reserved | Ожидается `0x0000` |
| `12..13` | Internal Configuration | RAM size/partition и activation selection |
| `14` | Secondary Software Information | Low nibble `1` обозначает B revision |
| `15..16` | Reserved | Ожидается `0x0000` |
| `17` | Secondary checksums | Vital/configurable byte-XOR lanes |
| `18..3F` | ISA PnP resource data | Только read-only dump на этапе 3 |

Primary checksum high byte — XOR обоих bytes words `00..0E`, исключая
`08`, `09`, `0D`; low byte — XOR обоих bytes только words `08`, `09`, `0D`.
Secondary vital checksum покрывает `10..12` и `20..3F`; configurable checksum
покрывает `13..16`. Проверка не должна исправлять или перезаписывать EEPROM.

Обычное Window 0 EEPROM read:

1. Убедиться, что `EEPROM Command.EBY` (bit 15) равен нулю.
2. Записать read opcode `0x80 | address` в Window 0 offset `0x0A`.
3. Poll `EBY` с конечным timeout; документированное execution time — 162 us.
4. После снятия `EBY` прочитать word из offset `0x0C`.

ID-port read не предоставляет отдельный EBY bit: после команды драйвер ждёт
не менее 162 us с закрытым ISA window, затем читает 16 bits MSB-first.
Практический timeout должен допускать более медленные экземпляры; Linux v6.6
использует миллисекундный запас, но это policy Linux, а не timing hardware.

### 4.3. ISA8 access rules

Каждый обычный 16-bit register обслуживается двумя соседними ISA8 cycles:

```text
read16:  low  = read(base + even)
         high = read(base + even + 1) immediately

write16: write(base + even, low)
         write(base + even + 1, high) immediately; side effect occurs here
```

Между low/high запрещён любой другой доступ к карте. Command word в
`base+0x0E/0x0F` выполняется только при записи high byte.

Исключения — byte registers/streams:

- Window 1 Timer `+0x0A`;
- Window 1 TX Status `+0x0B`;
- Window 6 counters `+0x00..0x08`;
- RX/TX PIO FIFO через lower byte `+0x00` или `+0x02`.

Для FIFO byte access к `+0x01` и `+0x03` запрещён. Клиент использует только
`+0x00`; high-byte FIFO offsets не должны двигать stream.

На Sprinter пара low/high выполняется в одной короткой ISA critical section.
DSS calls, system pages и диагностика выполняются только после закрытия ISA
window. Длинное ожидание разбивается на короткие polls с закрытием окна между
итерациями.

### 4.4. Register windows

Все окна используют общий Command/Status word в offset `0x0E`. После reset
выбрано Window 0; steady-state datapath работает в Window 1.

| Window | Offset | Register | Размер/семантика |
|:---:|:---:|---|---|
| all | `0E` | Command / Status | write command; read status, CIP и current window |
| 0 | `00` | Manufacturer ID | 16-bit, `0x6D50` |
| 0 | `02` | Product ID | 16-bit, target `0x9550` |
| 0 | `04` | Configuration Control | POR capability bits; writable enable/reset fields |
| 0 | `06` | Address Configuration | XCVR, ROM, auto-select, base index |
| 0 | `08` | Resource Configuration | IRQ/SRDY; IRQ не используется Sprinter |
| 0 | `0A` | EEPROM Command | EBY + opcode/address |
| 0 | `0C` | EEPROM Data | read result; project never writes it |
| 1 | `00`,`02` | RX/TX PIO | byte/word stream; Sprinter uses lower byte only |
| 1 | `08` | RX Status | incomplete/error/type/remaining bytes |
| 1 | `0A` | Timer | byte; 3.2 us/tick, saturates at `0xFF` |
| 1 | `0B` | TX Status | byte; read-peek, write-pop |
| 1 | `0C` | TX Free | 16-bit, dword-rounded free space |
| 2 | `00..05` | Station Address | six consecutive bytes; must load before RX enable |
| 3 | `00`,`02` | Internal Configuration | low/high halves of 32-bit register |
| 3 | `05` | ROM Control | byte; boot ROM disabled in version 1 |
| 3 | `0A` | RX Free | exact FIFO free bytes |
| 3 | `0C` | TX Free | exact FIFO free bytes |
| 4 | `04` | FIFO Diagnostic | RX/TX overrun/underrun and FIFO state |
| 4 | `06` | Net Diagnostic | loopback, TX/RX state, ASIC revision |
| 4 | `08` | Ethernet Controller Status | controller state/errors |
| 4 | `0A` | Media Type and Status | TPO/link/jabber; bits 7/6 writable |
| 5 | `00` | TX Start Threshold | command readback |
| 5 | `02` | TX Available Threshold | command readback |
| 5 | `06` | RX Early Threshold | command readback |
| 5 | `08` | RX Filter | lower four bits |
| 5 | `0A` | Interrupt Mask | command readback |
| 5 | `0C` | Read Zero Mask | command readback |
| 6 | `00..08` | Statistics | byte, read-and-zero while disabled |
| 6 | `0A` | RX bytes OK | 16-bit, read-and-zero while disabled |
| 6 | `0C` | TX bytes OK | 16-bit, read-and-zero while disabled |

Window 2 byte order is literal: `+0=Address0`, `+1=Address1`, ...,
`+5=Address5`. A 16-bit little-endian pair therefore reads
`Address1 << 8 | Address0`.

### 4.5. Commands and status

Command word is `(opcode << 11) | argument`. Commands not marked asynchronous
by the manual finish in one I/O cycle; asynchronous commands are followed by
finite polling of Status.CIP.

| Opcode | Command | Use in stages 3–6 |
|:---:|---|---|
| `0` | Global Reset | Discovery/recovery; wait for AUTOINIT |
| `1` | Select Window | All configuration and diagnostics |
| `2` | Start Coax | Not used for TPO |
| `3`,`4` | RX Disable / Enable | INIT/DONE and recovery |
| `5` | RX Reset | Fatal RX recovery; empties FIFO and resets filter/threshold |
| `8` | RX Discard | Removes exactly one current RX packet; wait CIP |
| `9`,`10` | TX Enable / Disable | INIT/DONE and recovery |
| `11` | TX Reset | Jabber/underrun/timeout recovery; wait CIP |
| `12` | Request Interrupt | Not used by polling driver |
| `13` | Acknowledge Interrupt | Clear latch/acknowledgeable status where needed |
| `14` | Set Interrupt Mask | Always zero for Sprinter polling |
| `15` | Set Read Zero Mask | Set bits that must remain visible to polling |
| `16` | Set RX Filter | Individual/broadcast/group/promiscuous classes |
| `17` | Set RX Early Threshold | Normally disabled above 1792 in polling baseline |
| `18` | Set TX Available Threshold | Optional polling wake condition |
| `19` | Set TX Start Threshold | Underrun avoidance/tuning |
| `21`,`22` | Statistics Enable / Disable | Counter collection/readout |
| `23` | Stop Coax | Not used for TPO |
| `27..29` | Power Up / Down / Auto | Not used in version 1 baseline |

Common Status low-byte bits:

| Bit | Mask | Meaning |
|:---:|:---:|---|
| 0 | `0x0001` | Interrupt Latch |
| 1 | `0x0002` | Adapter Failure |
| 2 | `0x0004` | TX Complete / TX Status nonempty |
| 3 | `0x0008` | TX Available |
| 4 | `0x0010` | RX Complete |
| 5 | `0x0020` | RX Early |
| 6 | `0x0040` | Interrupt Requested |
| 7 | `0x0080` | Update Statistics |
| 12 | `0x1000` | Command in Progress |
| 13..15 | `0xE000` | Current Window |

Read Zero Mask semantics are positive-enable: each clear mask bit forces the
corresponding Status bit to zero. Interrupt Mask is independent: zero disables
all interrupt outputs while visible Status bits remain readable. Interrupt
Latch cannot be hidden by Read Zero Mask and clears only by acknowledgement.

Mandatory timing limits from 3Com:

| Operation | Hardware requirement | Driver rule |
|---|---:|---|
| Global reset/AUTOINIT visibility | 310 us | wait at least 1 ms, bounded |
| EEPROM read | 162 us | poll EBY or delay then read, bounded |
| TX reset while transmitting | CIP, normally no more than about 6 us for documented deferred case | poll CIP with generous finite timeout |
| RX Discard | CIP until packet advances | poll CIP; one command per packet |
| Timer | 3.2 us/tick | diagnostic only, never sole timeout clock |
| Start/stop coax | 800 us | not applicable to TPO |

### 4.6. TX contract

TX FIFO packet layout:

```text
word 0: bit15 Notify, bit13 Disable CRC Generation, bits10..0 Length
word 1: zero
data:   Length bytes
pad:    zero bytes through align4(Length); pad is not wire length
```

The hardware can wire-pad a frame shorter than 60 bytes, but this project
normalizes the effective data length to at least 60 before writing the
preamble. Required FIFO room is `4 + align4(effective_length)`. The driver
must not depend on exact empty `TX Free`, because the adapter consumes a small
implementation-dependent overhead.

TX Status is an independent 31-entry stack. Reading `+0x0B` only peeks;
writing `+0x0B` pops one entry and must occur only after reading a Complete
entry. Successful completion is reported only when preamble.Notify is set;
errors are reported regardless. TX Status bits used by the driver:

- `0x80` Complete;
- `0x40` interrupt-on-success requested;
- `0x20` jabber;
- `0x10` underrun;
- `0x08` maximum collisions;
- `0x04` status-stack overflow.

Any TX error disables the transmitter. Maximum collisions needs TX Enable.
Jabber or underrun needs `TX Reset` -> wait CIP -> `TX Enable`. Retry count is
finite and the frame must be recopied because completed/error packets leave
the TX FIFO.

### 4.7. RX contract

RX Status is a 16-bit ripple-through FIFO entry:

- bit 15 Incomplete;
- bit 14 Error;
- bits 13..11 error type;
- bits 10..0 byte count/remaining bytes.

Relevant error types are overrun, oversize, runt, framing/alignment and CRC.
The project rejects Error packets and lengths outside `60..1514`.

Reading packet bytes does not remove the RX Status entry. Packet data is read
through the lower FIFO byte port through its dword padding. Exactly one
`RX_DISCARD` then removes exactly one head packet and exposes the next entry;
the command's CIP must be polled. A successful high-level `READ_FRAME`
therefore already consumes the packet. Calling a second discard would remove
the following packet.

RX Early fires only while received bytes exceed the threshold; a value above
1792 disables it. RX Complete masks RX Early for a complete packet. Group
filter implies broadcast; promiscuous implies all filters.

## 5. Сравнительная таблица поведения

`N/A` означает неприменимость к polling Sprinter, а не отсутствие функции в
источнике. MAME observations относятся только к snapshot из раздела 2.

| Операция | 3Com | Nestor fixed commit | Linux v6.6 | MAME snapshot | Решение Sprinter |
|---|---|---|---|---|---|
| ID port choice | `0x100..0x1F0` | Default `0x110`, caller override | Scans from `0x110` by `0x10` | Full range decoded | Default `#110`, validated range |
| ID handshake | two zeros | two zeros | two zeros | implemented | two zeros in one short ISA section |
| LFSR | 255, `FF`, polynomial `CF`, ends `98` | same observed sequence | same observed sequence | implemented | generate independently from manual |
| ID global reset | `C0..CF`, AUTOINIT 310 us | issues `C0`, coarse 27.5 ms delay | not baseline discovery path | 300 us | use >=1 ms finite delay; MAME must become >=310 us |
| Tag/contention | `D0..DF` | clears tag to zero for one-card probe | tag/test used for enumeration | partial single-device implementation | implement documented semantics, support one selected card |
| ID EEPROM read | command, >=162 us, 16 MSB-first bits | coarse delay then 16 reads | 4 ms delay then 16 reads | timer exists but reads can shift stale data while busy | close ISA during delay; MAME busy gate is Stage 2 blocker |
| EEPROM validation | IDs/checksums from Chapter 7 | checks manufacturer, family product mask and primary XOR | checks manufacturer/MAC and config words | synthetic EEPROM/checksums | require exact `9550`, `6D50`, primary/secondary checksums |
| Activation | `E0..FE` override base, `FF` EEPROM base | `FF` | `E0 | base_index` | implemented | AUTO uses `FF`; explicit safe base uses `E0|index` |
| I/O base decode | `0x200 + index*0x10` | same | same | all 31 values implemented | accept `0x200..0x3E0`; reject index `1F` |
| ISA8 word access | low then high; command on high | x86 word I/O | x86 word I/O | byte latch implemented | explicit adjacent low/high byte cycles |
| FIFO byte offsets | lower byte only; dword pad | word I/O, dword accounting | dword I/O | `+00/+02` accepted, odd offsets rejected | use only `+00` byte stream |
| Station address | load Window 2 before RX | loads six bytes | loads six bytes | byte order implemented | load exact EEPROM MAC bytes |
| TPO media | enable link beat/jabber per EEPROM policy | enables both | enables both, selects half/full duplex | writable bits present, link behavior partial | half duplex, TPO, link beat/jabber on |
| IRQ setup | separate masks and status | interrupt-driven | interrupt-driven | generic ISA IRQ state exists | Interrupt Mask=0; no Sprinter IRQ routing |
| Read Zero Mask | set bit makes Status source visible | writes `0xFE` | writes `0xFF` | polarity is inverted in current code | visible polling sources set; MAME fix required |
| RX/TX reset | reset state and poll CIP when required | TX reset waits without bound | resets used, some waits omitted | state changes immediately and reset defaults are incomplete | every wait finite; restore filter/media after RX reset |
| TX FIFO room | account preamble/data/dword pad + overhead | finite TxFree wait | queues then uses TxFree threshold | undercounts pending preamble/pad | require `4+align4(max(len,60))` and timeout |
| TX preamble word 1 | must be zero | pinned source repeats length word | writes zero | parses but does not validate reserved word | always write zero; do not reproduce Nestor behavior |
| Short TX frame | hardware can pad to 60 | relies on hardware | relies on hardware | model pads to 60 | software pads data to 60 for deterministic behavior |
| TX Status pop | read-peek, write-pop | error handling present; pop path partly disabled in send path | read then byte-write pop | read/write-pop implemented | always read complete before one pop |
| TX Status success | Complete + Notify when requested | no success notify requested | usually treats TX Complete as error path | emits `0x80`, missing Notify bit `0x40` | set Notify and require `0xC0` success; MAME fix |
| TX Status overflow | depth 31, overflow disables TX | no explicit depth handling | no explicit depth model | drops oldest entry silently | preserve overflow status and recover; MAME fix |
| TX underrun/jabber | TX disabled; reset, CIP, enable | reset then enable, unbounded CIP wait | reset then enable | no fault/error path | bounded reset/retry and diagnostics |
| RX length/error | status supplies error and count | rejects errors/runt/giant | discards error entries | basic runt/oversize status | accept only error-free `60..1514` |
| RX data removal | data read does not pop | reads padded data then discard | reads padded data then discard | data persists until discard | one consuming READ_FRAME = data + one discard |
| RX Discard | one head, poll CIP | polls CIP without timeout | polls CIP without timeout | one head, 5 us CIP | finite wait; never double-discard |
| Back-to-back RX | each status remains until discard | loop handles another packet | loop handles another packet | fixed ring, not hardware-validated | mandatory 2/10 packet regression |
| RX Early vs Complete | Complete masks Early | interrupt-driven early path | early path unused | sets both for completed packet | baseline disables Early; MAME fix required |
| Statistics | disable before read; reads zero | definitions present | disable/read/enable | partial counters | diagnostic only after correct disable/read/enable |
| Timeout policy | poll asynchronous commands | several infinite busy loops | several unbounded polling loops | deterministic timers, no fault hold baseline | every loop deadline-bound; source loops are not copied |
| IRQ routing | platform-specific | DOS PIC ISR | Linux IRQ handler | ISA device can assert generic line | Sprinter callbacks remain disconnected |

## 6. Независимый псевдокод Sprinter

Это алгоритмический контракт, а не перевод Nestor/Linux. Имена операций
абстрактны и будут независимо отображены на Z80/Sprinter в следующих этапах.

### 6.1. Primitive access and finite waits

```text
READ16(base, even_offset):
    open ISA window
    low  = read8(base + even_offset)
    high = read8(base + even_offset + 1) immediately
    close ISA window
    return low | high << 8

WRITE16(base, even_offset, value):
    open ISA window
    write8(base + even_offset, value.low)
    write8(base + even_offset + 1, value.high) immediately
    close ISA window

WAIT_CIP_CLEAR(base, deadline):
    repeat:
        status = READ16(base, STATUS)
        if CIP is clear: return OK
        yield/advance DSS ticks with ISA closed
    until deadline expired
    return ERR_CIP_TIMEOUT
```

No public routine spins forever. Timeout result includes a stable status code
and diagnostic stage code.

### 6.2. ID sequence and EEPROM

```text
WRITE_ID_SEQUENCE(id_port):
    value = FF
    open ISA window
    write8(id_port, 00)
    write8(id_port, 00)
    repeat 255 times:
        write8(id_port, value)
        value = (value << 1) XOR CF only when old bit7 was one
    close ISA window
    require value returned to FF and last emitted byte was 98

ID_READ_WORD(id_port, address):
    require address in 00..3F
    write8_once(id_port, 80 | address)
    wait >= 162 us with ISA window closed, bounded by EEPROM deadline
    word = 0
    open ISA window
    repeat 16 times:
        word = (word << 1) | (read8(id_port) & 1)
    close ISA window
    return word

DISCOVER(id_port):
    validate id_port range/alignment
    WRITE_ID_SEQUENCE(id_port)
    write8_once(id_port, C0)             ; read-only global reset
    wait >= 1 ms with ISA closed
    WRITE_ID_SEQUENCE(id_port)
    write8_once(id_port, D0)             ; clear tag for one-card probe
    read EEPROM words 00..17
    require manufacturer == 6D50
    require product == 9550
    require valid primary and secondary checksums
    require valid unicast MAC
    return EEPROM snapshot without modifying it
```

If classic activation gets no valid response, return a bounded
`ERR_NOT_FOUND_OR_PNP` diagnostic. Do not start blind writes or EEPROM repair.

### 6.3. Activation and initialization

```text
ACTIVATE(snapshot, requested_base):
    if requested_base is AUTO:
        require EEPROM base index != 1F
        write8_once(id_port, FF)
        base = decode(snapshot.address_config)
    else:
        validate base in 200..3E0 and aligned to 10
        write8_once(id_port, E0 | encode(base))
    select Window 0
    require Manufacturer ID == 6D50 and Product ID == 9550
    return base

INIT(base, mac):
    Set Interrupt Mask = 0
    Set Read Zero Mask = polling status bits needed by driver
    RX Disable; TX Disable
    RX Reset; wait CIP with deadline
    TX Reset; wait CIP with deadline
    Window 2: write MAC bytes 0..5
    Window 4: enable TPO link beat and jabber guard; keep half duplex
    Window 6: Statistics Disable; read counters to clear
    Window 1
    Set RX Filter = Individual | Broadcast
    Set RX Early > 1792                    ; disabled baseline
    choose conservative TX Start threshold; record value
    Statistics Enable
    RX Enable; TX Enable
    acknowledge stale latch/status where documented
    return OK
```

The IRQ value read from EEPROM is displayed as `not used by Sprinter` and is
never programmed as a prerequisite for successful INIT.

### 6.4. Transmit and recovery

```text
SEND_FRAME(frame, input_length):
    require 14 <= input_length <= 1514
    effective_length = max(input_length, 60)
    required = 4 + align4(effective_length)
    poll TX Free >= required with deadline and ISA closed between polls
    build preamble word0 = Notify | effective_length
    write word0, zero word1, frame bytes, zero short-frame pad,
          then zero dword pad through lower FIFO byte port
    poll TX Status/general Status with deadline
    when TX Status Complete:
        read status once, then write TX Status once to pop it
        if success+Notify: return OK
        if max collisions: TX Enable; return bounded retry/error
        if jabber or underrun:
            TX Reset; WAIT_CIP_CLEAR; TX Enable
            retry only while retry budget remains
        otherwise return explicit TX error
    on deadline:
        TX Reset; WAIT_CIP_CLEAR; TX Enable
        return ERR_TX_TIMEOUT
```

### 6.5. Receive and recovery

```text
READ_FRAME(destination, capacity):
    rx_status = READ16(base, RX_STATUS)
    if Incomplete or FIFO empty: return NO_PACKET
    length = rx_status & 07FF
    if Error or length outside 60..1514 or length > capacity:
        RX_DISCARD; WAIT_CIP_CLEAR
        return explicit RX error
    open ISA window
    read align4(length) bytes from lower RX FIFO port
    store only first length bytes
    close ISA window
    RX_DISCARD exactly once
    WAIT_CIP_CLEAR
    return OK(length)

RECOVER_ADAPTER_FAILURE:
    capture Status, FIFO Diagnostic, RX Status and TX Status
    RX Disable
    RX Reset; WAIT_CIP_CLEAR
    restore station address, media and RX filter
    RX Enable
    return explicit recovered/fatal status
```

`DISCARD_FRAME` is only for a current packet that has not been consumed by
`READ_FRAME`. It sends one discard and waits once.

## 7. MAME findings for Stage 2

Положительные свойства snapshot: устройство зарегистрировано как `3c509b`,
декодирует все 31 base, имеет ID/LFSR, 170 us EEPROM timer, low/high latch,
запрет odd FIFO bytes, исправленный Window 2 order, dword TX padding,
31-entry storage, explicit RX Discard и save-state fields.

До использования модели как oracle остаются подтверждённые расхождения:

1. AUTOINIT задан 300 us вместо документированных 310 us.
2. ID-port read во время EEPROM timer может сдвигать предыдущее word; нет
   busy/not-ready gate перед публикацией нового word.
3. Read Zero Mask применён с обратной полярностью (`set bit` скрывает status),
   тогда как руководство требует скрывать status при clear bit.
4. Window 1 Timer всегда возвращает `0xFF`, а не моделирует 3.2 us counter.
5. RX/TX reset меняют часть state немедленно, а затем ставят generic CIP;
   RX Reset не восстанавливает все документированные filter/threshold/disable
   defaults, TX Reset не завершает все pending/error states.
6. Успешный notified TX Status записывается как `0x80`, без обязательного
   Notify bit `0x40`.
7. TX Status overflow молча удаляет oldest entry вместо overflow status и TX
   disable.
8. TX accounting после launch не включает весь preamble+dword allocation;
   multi-packet TX FIFO и error completions отсутствуют.
9. RX completion может одновременно оставить RX Early, хотя RX Complete
   должен его маскировать.
10. Configuration Control POR capability bits и реальная link/media state не
    подтверждены аппаратной трассой.
11. RX storage ограничено восемью fixed slots и не полностью соответствует
    byte-addressed 16 KiB partition; concurrent receive staging требует теста.
12. EEPROM erase/write paths существуют в модели, но не должны быть доступны
    или вызываться клиентом версии 1.

Generic ISA device может формировать IRQ state для других систем. Это не
нарушение, пока в `sprinter.cpp`/machine configuration нет подключения ISA
IRQ callback к CPU. На момент аудита такого подключения для карты не найдено.

## 8. Карта реального оборудования: частично заполненное evidence

Фотографии лицевой и обратной стороны сохранены в
[`docs/evidence`](evidence/README.md). На них подтверждены маркировка
`3C509B-TPO`, ревизионная наклейка `REV B`, PCB
`FAB 02-0020-000 REV A` и заводской EA/MAC `00:20:AF:5D:69:8B`.
На дату 2026-08-29 карта находится в пути и физически недоступна. Эти данные
не считаются EEPROM dump или проверкой карты в Sprinter.

На обеих фотографиях внешний разъём на footprint `J70` выглядит отсутствующим
или демонтированным; красные стрелки указывают на эту область. Это пока только
визуальное наблюдение. До подачи питания необходимо осмотреть footprint и
пайку, а до физического link/TX/RX — подтвердить исправный разъём 10BASE-T.

Оставшаяся карта evidence заполняется только read-only внешними средствами до
закрытия этапа 1.

```text
Adapter marking/revision: 3C509B-TPO / REV B (photograph)
Sprinter slot:           ______________________________
External tool/version:   ______________________________
Tool command:            ______________________________
Classic/PnP state:       ______________________________
ID port used:            ______________________________
EEPROM I/O base:         ______________________________
IRQ (informational):     ______________________________
MAC label (not EEPROM):  00:20:AF:5D:69:8B
Product word 03:         ______________________________
Manufacturer word 07:    ______________________________
Address config 08:       ______________________________
Resource config 09:      ______________________________
Primary checksum 0F:     ______________________________
Capabilities 10:         ______________________________
Internal config 12/13:   ______________________________
Secondary info/checksum: ______________________________
Full read-only dump/log:  ______________________________
```

Запрещено запускать configuration/save operation, менять PnP, IRQ, base, MAC
или EEPROM ради заполнения таблицы.

## 9. Приёмка локальной части

- [x] Окна, регистры, команды и timing извлечены из 3Com reference.
- [x] Nestor проверен на exact commit и отделён GPL clean-room границей.
- [x] Linux v6.6 проверен как независимый behavioral cross-check.
- [x] Составлена матрица `3Com / Nestor / Linux / MAME / Sprinter`.
- [x] Записан независимый псевдокод discovery, EEPROM, activation, INIT, TX,
  RX и recovery.
- [x] IRQ paths явно признаны неприменимыми к Sprinter.
- [x] Команды, необходимые этапам 3–6, имеют последовательность и error path.
- [ ] Сняты product ID и EEPROM физической 3C509B-TPO.
- [ ] Записаны исходные I/O, PnP, MAC и resource settings физической карты.

Пока последние два пункта пусты, этап 1 документирован локально, но не закрыт.
