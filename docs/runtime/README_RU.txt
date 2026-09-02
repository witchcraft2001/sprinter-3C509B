Sprinter 3C509B Network Kit 0.0.1

Доступные команды DSS:

  EL3INFO              Найти 3C509B и показать конфигурацию.
  EL3INFO -v           Показать дополнительные поля EEPROM.
  EL3EEP               Вывести все 64 слова EEPROM (диагностика).
  ISAPROBE             Без параметров показывает только справку.
  NETCFG               Показать опубликованное окружение NET_*.
  NETCFG -i -v         Проверить NET.CFG/карту и опубликовать настройки.
  IFUP                 Проверить static или получить новый DHCP lease.
  IFUP -r              Продлить активный DHCP lease.
  IFUP -d              Освободить и удалить активный DHCP lease.
  NSLOOKUP имя [dns]   Разрешить IPv4-адрес через DNS.
  NTP [сервер]         Установить часы DSS по NTP.
  PING адрес           Отправить ограниченные ICMP Echo Request.
  TFTP узел GET файл   Скачать файл в TFTP octet mode.
  TFTP узел PUT файл   Отправить файл в TFTP octet mode.
  ARP [-v] target      Ограниченная ARP-диагностика (только IMG).
  PINGALT адрес        Независимая polling-диагностика (только IMG).
  UDPTEST адрес порт   UDP echo/generator-диагностика (только IMG).

EL3EEP, ISAPROBE, ARP, PINGALT и UDPTEST находятся только в диагностическом образе.
ISAPROBE читает ISA только при явном указании слота, базы и длины:

  ISAPROBE -s 1 -b #0300 -n #0010

Скопируйте NETSMPL.CFG в NET.CFG рядом с NETCFG.EXE и отредактируйте до
NETCFG -i. NETCFG.TXT, IFUP.TXT, NSLOOKUP.TXT, NTP.TXT, PING.TXT,
TFTP.TXT, USAGE.TXT и HOWTO.TXT описывают настройку.
LICENSE.TXT содержит лицензию.

ВНИМАНИЕ: EEPROM доступна только для чтения. Эти команды не сохраняют
настройки карты. ISAPROBE ничего не записывает, но чтение неизвестного
устройства может иметь побочный эффект; используйте только заранее известный
диапазон.

IFUP поддерживает static, получение, продление и RELEASE DHCP lease. PING,
UDPTEST и TFTP принимают IPv4-адрес или DNS-имя. NTP повторно проверяет NET_TZ
с шагом 15 минут до установки часов. При ошибке TFTP GET partial-файл
закрывается и сохраняется.
