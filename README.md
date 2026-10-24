# DIR-320 OpenWrt: сайт, панель управления, FTP и установщик с псевдо-GUI

[![build](https://github.com/EvGeNkA-PLUSsss/dir320-openwrt/actions/workflows/build.yml/badge.svg)](https://github.com/EvGeNkA-PLUSsss/dir320-openwrt/actions/workflows/build.yml)

Готовый набор для старых роутеров на OpenWrt (проверено на **D-Link DIR-320 B1**, Ralink RT5350, OpenWrt 19.07.10):

- **веб-сайт** на `:80` (`/srv/www`);
- **панель управления** `/admin` на Lua CGI: обзор, метрики, файлы, консоль, Wi-Fi, логи, настройки;
- **FTP-сервер** (vsftpd), корень которого — та же папка, что у сайта: загрузил по FTP — сразу видно на сайте;
- **пароль FTP = пароль роутера** (синхронизируется автоматически, в том числе через cron);
- **один установочный `.sh`-файл** с псевдо-GUI в терминале: ставит всё «под ключ», настраивает Wi-Fi/FTP/порты и умеет **универсально** чистить неиспользуемые пакеты и файлы.

> **English abstract.** A self-contained site + admin panel + FTP setup for D-Link DIR-320 B1 on OpenWrt 19.07, plus a single-file terminal-installer with a pseudo-GUI (ANSI). The admin panel is a small Lua CGI that authenticates against `/etc/shadow` (the same password as LuCI/SSH), so the FTPS password always equals the router password. `bin/dir320-tui.sh` installs everything, configures the network and offers a dependency-graph based cleanup of unused packages and orphan files. MIT licensed.

---

## Возможности

### Панель `/admin`
| Вкладка | Что умеет |
|---|---|
| **Обзор** | модель, версия OpenWrt, ядро, uptime, load, память, флеш, Wi-Fi, сеть, службы, DHCP-аренды |
| **Метрики** | графики CPU/памяти/сети/соединений в реальном времени, топ процессов по памяти, kill процесса |
| **Файлы** | просмотр `/srv/www`, скачивание, загрузка (до 4 МБ), удаление, создание папок |
| **Консоль** | выполнение любых команд с примерами и описанием (без лимита времени, вывод до 128 КБ) |
| **Wi-Fi** | SSID, WPA2-пароль, канал, вкл/выкл |
| **Логи** | `logread`, фильтр |
| **Настройки** | порты сайта/LuCI/FTP, имя хоста, смена пароля root (он же FTP), службы, бэкап, перезагрузка |

Вход в панель — **пароль root** роутера (`/etc/shadow`, тот же, что у LuCI и SSH). Отдельного пароля у панели нет.

### FTP
- vsftpd 3.0.3, chroot в `/srv/www`, passive 50000–50100;
- логин `ftpuser`, **пароль всегда равен паролю root**:
  - при установке в `/etc/shadow` копируется хеш root;
  - смена пароля через панель/установщик обновляет оба;
  - `/usr/libexec/dir320-sync-ftp.sh` + cron раз в 2 минуты чинят расхождение, если пароль сменили через LuCI/SSH.

### Универсальная очистка (в установщике)
Без списков «ненужных пакетов» под конкретную модель:
1. строится граф зависимостей по `/usr/lib/opkg/info/*.control`;
2. кандидаты — «листья», от которых никто не зависит;
3. защищаются пакеты, владеющие **запущенными процессами** и **включёнными службами** (`/etc/rc.d/S*`), плюс минимальное ядро (base-files, libc, procd, netifd, dnsmasq, dropbear, uhttpd, vsftpd, Wi-Fi-стек…);
4. для каждого пакета считается реальный размер **в overlay** (сколько освободится, а не размер пакета из ROM);
5. отдельно находятся **файлы без владельца** в `/overlay/upper` и **пустые каталоги**;
6. экспертный режим показывает системные пакеты и `/etc`-файлы; удаление требует ввести `YES`.

### Установщик `dir320-tui.sh`
Один файл, внутри — файлы панели/сайта/README. Псевдо-GUI: ANSI-цвета, заливка фона символами, рамки, меню, чекбоксы.

```
1. Установить всё «под ключ»      4. Статус и диагностика
2. Настройки Wi-Fi / FTP / порты  5. Перезагрузить роутер
3. Очистка системы «под чистую»   0. Выход
```

Неинтерактивные режимы:

```sh
sh dir320-tui.sh --status        # информация о системе
sh dir320-tui.sh --detect        # кандидаты на очистку (TSV)
sh dir320-tui.sh --install-auto  # установка с настройками по умолчанию
```

---

## Быстрый старт

### 1. Собрать установщик

Нужен Python 3 (или `pwsh` — см. `tools/build_installer.ps1`):

```sh
python3 tools/build_installer.py
# → dist/dir320-tui.sh
```

### 2. Закинуть на роутер и запустить

С OpenWrt 19.07 (Dropbear) современный OpenSSH требует `-o HostKeyAlgorithms=+ssh-rsa`, а `scp` — ключ `-O` (в dropbear нет sftp-server):

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa dist/dir320-tui.sh root@192.168.1.1:/tmp/install.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sh /tmp/install.sh"
```

Или без scp:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "cat > /tmp/install.sh" < dist/dir320-tui.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sh /tmp/install.sh"
```

Подробно обо всех способах передачи (Windows `cmd`, PuTTY, WinSCP, HTTP, панель, IPv6 link-local) — в [docs/INSTALL.md](docs/INSTALL.md).

### 3. Открыть

- сайт: `http://192.168.1.1/`
- панель: `http://192.168.1.1/admin` (пароль root)
- LuCI: `http://192.168.1.1:8080/`
- FTP: `ftp://192.168.1.1/` — логин `ftpuser`, пароль = пароль root

---

## Требования

- роутер с OpenWrt 19.07.x (`mipsel_24kc`), желательно 8+ МБ RAM свободно в пике;
- LuCI (пакеты `lua`, `liblua`, `luci-lib-nixio`) — в стандартной сборке есть;
- `uhttpd` (стандартный веб-сервер OpenWrt);
- интернет на роутере для установки `vsftpd` (либо положить `.ipk` локально — установщик умеет fallback на URL релиза 19.07.10).

Скрипт рассчитан на OpenWrt 19.07 (uci/procd/busybox), на 21.02+ тоже должен работать, но не тестировался.

---

## Структура репозитория

```
.
├── panel/                    # файлы, которые ставятся на роутер
│   ├── admin.lua             # панель (Lua CGI) — /srv/www/cgi-bin/admin
│   ├── panel-console.sh      # обёртка консоли — /usr/libexec/panel-console.sh
│   ├── index.html            # редирект /admin/ → /cgi-bin/admin
│   ├── site-index.html       # главная сайта — /srv/www/index.html
│   └── README-DIR320.txt     # памятка на роутере — /root/README-DIR320.txt
├── installer/
│   └── dir320-tui.sh.in      # шаблон установщика (ANSI-меню, установка, очистка)
├── tools/
│   ├── build_installer.py    # сборка одного файла dist/dir320-tui.sh
│   └── build_installer.ps1   # то же для PowerShell
├── docs/
│   ├── INSTALL.md            # способы передачи файла и установка
│   ├── ARCHITECTURE.md       # как устроены uhttpd/CGI/Lua/панель
│   └── CLEANUP.md            # алгоритм универсальной очистки
├── .github/workflows/build.yml
├── LICENSE                   # MIT
└── README.md
```

Сборка одного файла: `tools/build_installer.py` подставляет содержимое `panel/*` в heredoc-маркеры шаблона и проверяет, что маркеры не встречаются в полезной нагрузке.

---

## Настройки

Установщик хранит параметры в `/etc/dir320.conf` на роутере (Wi-Fi SSID/пароль/канал, логин/пароль FTP, порты). Менять удобнее в меню установщика: **2) Настройки**.

По умолчанию:
- сайт/панель — порт 80, LuCI — 8080, FTP — 21;
- SSID `DIR-320`, WPA2, канал 11, страна RU;
- FTP-логин `ftpuser`, пароль = пароль root.

После установки: `/root/README-DIR320.txt` — краткая памятка по файлам и службам.

---

## Безопасность

- Панель, LuCI и SSH используют один пароль root. Меняйте его (`passwd` или панель → Настройки).
- Панель слушает только LAN/`rfc1918_filter=1`; на WAN порт 80 пробросится только если вы сами откроете firewall.
- FTP — **без TLS** (vsftpd без libssl): пароль и файлы идут по сети открытым текстом. Используйте только в доверенной сети.
- Загружаемые через панель/консоль команды выполняются от root — это ожидаемо для админ-панели, но не давайте к ней доступ посторонним.
- `--detect`/`cleanup` умеют удалять пакеты: обычный режим защищает запущенные службы и ядро системы, экспертный — снимает защиту (в нём подтверждение `YES`).

---

## Ограничения

- В RT5350 нет датчика температуры — панель честно пишет «не найден».
- Панель — CGI: на каждый запрос создаётся процесс `lua` (~1–2 МБ пиково). Для 28 МБ RAM это нормально, но не стоит держать открытыми десятки вкладок с метриками.
- В dropbear нет sftp-server, поэтому `scp` только с `-O`, а для SFTP нужно `opkg install openssh-sftp-server`.

---

## Лицензия

[MIT](LICENSE). Проект не включает код OpenWrt/LuCI: он устанавливается поверх и использует системные пакеты (`uhttpd`, `vsftpd`, `lua`, `nixio`), у которых свои лицензии (GPL-2.0, Apache-2.0 и т.д.).
