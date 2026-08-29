# Быстрый старт Sprinter 3C509B Network Kit

Версия 0.0.1 является каркасом этапа 0. Сетевого драйвера и сетевых команд в
ней ещё нет: `HELLO.EXE` не обращается к ISA и карте 3C509B.

## Сборка на хосте

Установите `sjasmplus`, mtools, `zip`, `unzip`, `iconv` и Perl, затем выполните:

```sh
make clean
make build
make test-host
make package
make image
```

Файл `build/HELLO.EXE` можно скопировать на диск DSS и запустить командой:

```text
HELLO
```

Ожидаемый вывод:

```text
3C509B DEV HELLO v0.0.1
RESULT OK
```

Код возврата — `0`. Образ `distr/sprinter-3c509b.img` содержит тот же EXE,
документацию и пример будущей сетевой конфигурации `NETSMPL.CFG`. ZIP этапа 0
проверяет только упаковочный конвейер и намеренно не содержит тестовый EXE.

Проверка в MAME описана в developer-only файле `docs/MAME_STAGE0.md`. Этап 0
нельзя считать полностью закрытым, пока фактический вывод не подтверждён и в
MAME, и на реальном Sprinter.
