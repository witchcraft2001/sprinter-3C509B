# Stage 5 evidence

- Дата/время:
- Исполнитель:
- Git commit:
- VERSION: 0.0.1
- Среда: MAME / реальный Sprinter
- CPU clock:
- Карта/ревизия:
- Slot:
- IDPORT:
- Base:
- MAC:
- Команда:
- IMG SHA-256:
- EL3LB.EXE SHA-256:
- sjasmplus --version:
- z88dk-ticks:

## Вывод

    [L0]
    [L1]
    [L2]
    [L3]
    [L4]
    [L5]
    [L6]
    RESULT

## Проверки

- [ ] matrix expected = 40 × runs
- [ ] burst expected = 12 × runs
- [ ] run expected = runs
- [ ] timeout/rxerr/txerr/drop = 0
- [ ] loopback выключен после завершения
- [ ] следующий EL3INFO/EL3REG работает
- [ ] IMG/EXE hashes записаны
- [ ] лог, screenshot или dump приложен

## Открытые ограничения

- MAME fault injection underrun/jabber/bad RX:
- Реальная карта:
- Примечания:
