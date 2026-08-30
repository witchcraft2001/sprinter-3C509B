# Быстрый старт Sprinter 3C509B Network Kit

Версия 0.0.1 является bootstrap этапа 3. Сетевых команд в ней ещё нет, но
добавлены read-only диагностики `EL3INFO`, `EL3EEP` и `ISAPROBE`.

## Сборка на хосте

Установите `sjasmplus`, mtools, `zip`, `unzip`, `iconv` и Perl, затем выполните:

```sh
make clean
make build
make test-host
make package
make image
```

Безопасную диагностику можно скопировать на диск DSS и запустить командой:

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

Код возврата — `0`. Образ содержит также `HELLO`, полный read-only EEPROM dump
`EL3EEP` и явно ограниченный read-only `ISAPROBE`; последние три программы не
входят в пользовательский ZIP. EEPROM никогда не записывается, а IRQ карты не
подключается и не используется.

Этапы 2 и 3 остаются открыты до полного прогона в MAME и проверки прибывшей
физической карты на реальном Sprinter. Найденные расхождения MAME записаны в
developer-only feature request `docs/MAME_3C509B_FEATURE_REQUEST.md`. Полная
матрица команд, ожидаемых результатов и evidence описана в
`docs/STAGE3_TESTING_RU.md`.
