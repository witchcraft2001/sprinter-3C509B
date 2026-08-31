# Проверка этапа 5: FIFO и внутренний loopback

## Ограничения безопасности

На реальном Sprinter сначала запишите slot, ID-порт, исходную базу и MAC.
Используйте только документированные порты и сначала выполните read-only
EL3INFO. Не запускайте blind scan. IRQ Sprinter не подключаются, EEPROM не
записывается. При timeout или неожиданном status программа обязана закрыть
ISA-окно, выключить loopback, выполнить DONE, освободить DSS-блок и вернуть
управление системе.

## Локальная проверка

    make clean
    make test-host package image
    bash -n tools/*.sh
    perl -c tools/*.pl
    git diff --check

Сохраните версии sjasmplus и z88dk-ticks, вывод Stage 5 ASM mock, списки IMG
и ZIP, размеры и SHA-256 файлов. EL3LB.EXE и EL3LB.TXT должны присутствовать
только в FAT12 IMG. В ZIP их быть не должно.

## MAME

Для каждого положительного запуска сохраните полный текст [L0]–[L6] и
RESULT OK. Burst-проверка использует различимый sequence-байт в каждом кадре;
любая потеря, перестановка или подмена дубликатом должна завершаться RESULT FAIL.

| ID | Slot | База | Повторы | Ожидание |
|---|---:|---|---:|---|
| L01 | 0 | AUTO | 1 | 40 matrix, 12 burst, 1 run |
| L02 | 1 | AUTO | 1 | 40 matrix, 12 burst, 1 run |
| L03 | 0 | #200 | 1 | PASS |
| L04 | 0 | #300 | 1 | PASS |
| L05 | 0 | #3E0 | 1 | PASS |
| L06 | 1 | #200 | 1 | PASS |
| L07 | 1 | #300 | 1 | PASS |
| L08 | 1 | #3E0 | 1 | PASS |
| L09 | выбранный | AUTO | 100 | 4000 matrix, 1200 burst, 100 run |
| L10 | пустой slot | AUTO | 1 | конечный NOT_FOUND |

Границы CLI: -n 0, -n 101, -s 2, -p #101, -b #3F0 должны вернуть parameter
error до доступа к ISA. После матрицы повторите Stage 4 smoke: EL3REG -n 1 и
EL3REG -n 100 на новом IMG.

Отдельного MAME fault injection для underrun, jabber и bad RX в выбранном scope
нет. Эти recovery-пути подтверждаются исполняемым mock-тестом, а отсутствие
fault injection остаётся открытым blocker и не отмечается как PASS.

## Реальный Sprinter

Повторите положительную матрицу сначала с -n 1, затем с -n 100. Запишите
модель карты, slot/base/MAC, частоту CPU, полный вывод и фото/лог. После ошибки
убедитесь, что DSS продолжает принимать команды и следующий EL3INFO работает.

Заполненный результат внесите в docs/evidence/STAGE5_TEST_TEMPLATE.md. Этап 5
не закрывается без file-backed MAME evidence и проверки реальной 3C509B-TPO.
