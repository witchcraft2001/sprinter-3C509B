Sprinter 3C509B Network Kit 0.0.1

Доступные команды DSS:

  EL3INFO              Найти 3C509B и показать конфигурацию.
  EL3INFO -v           Показать дополнительные поля EEPROM.
  EL3EEP               Вывести все 64 слова EEPROM (диагностика).
  ISAPROBE             Без параметров показывает только справку.
  NETCFG               Показать опубликованное окружение NET_*.
  NETCFG -i -v         Проверить NET.CFG/карту и опубликовать настройки.
  IFUP                 Проверить static или получить новый DHCP lease.
  PING адрес           Отправить ограниченные IPv4 ICMP Echo Request.
  TFTP адрес GET файл  Скачать файл в TFTP octet mode.
  TFTP адрес PUT файл  Отправить файл в TFTP octet mode.
  ARP [-v] target      Ограниченная ARP-диагностика (только IMG).
  PINGALT адрес        Независимая polling-диагностика (только IMG).
  UDPTEST адрес порт   UDP echo/generator-диагностика (только IMG).

EL3EEP, ISAPROBE, ARP, PINGALT и UDPTEST находятся только в диагностическом образе.
ISAPROBE читает ISA только при явном указании слота, базы и длины:

  ISAPROBE -s 1 -b #0300 -n #0010

Скопируйте NETSMPL.CFG в NET.CFG рядом с NETCFG.EXE и отредактируйте до
NETCFG -i. NETCFG.TXT, IFUP.TXT, PING.TXT, TFTP.TXT, USAGE.TXT и HOWTO.TXT описывают настройку.
LICENSE.TXT содержит лицензию.

ВНИМАНИЕ: EEPROM доступна только для чтения. Эти команды не сохраняют
настройки карты. ISAPROBE ничего не записывает, но чтение неизвестного
устройства может иметь побочный эффект; используйте только заранее известный
диапазон.

IFUP поддерживает static и начальное получение DHCP lease. PING, UDPTEST и
TFTP принимают IPv4-адрес; DNS-имена, продление DHCP и RELEASE пока не
реализованы. При ошибке TFTP GET partial-файл закрывается и сохраняется.
