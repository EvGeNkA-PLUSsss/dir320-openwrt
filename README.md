# OpenWrt Universal Installer & Panel

[![build](https://github.com/EvGeNkA-PLUSsss/dir320-openwrt/actions/workflows/build.yml/badge.svg)](https://github.com/EvGeNkA-PLUSsss/dir320-openwrt/actions/workflows/build.yml)

Универсальный установщик для роутеров на OpenWrt: **один `.sh`-файл**, одно меню — **УСТАНОВИТЬ**. Установщик сам определяет модель, интерфейсы и секции конфигов (ничего не зашито под конкретное железо), максимально чистит систему от неиспользуемого и разворачивает:

- **сайт** на порту 80 (`/srv/www`);
- **панель управления** `/admin` на Lua CGI: обзор, метрики, файлы, консоль, Wi-Fi, логи, настройки;
- **FTP-сервер** (vsftpd), корень — папка сайта; **пароль FTP = пароль root** (синхронизируется автоматически);
- **Wi-Fi** — точка доступа настраивается (текущие SSID/пароль сохраняются, при отсутствии генерируются);
- **firewall** — правила для сайта, админки и FTP;
- **очистку системы** — удаление неиспользуемых пакетов по графу зависимостей, файлов без владельца, пустых каталогов и кешей.

> **English abstract.** A single-file, model-agnostic installer for OpenWrt routers. One menu item — INSTALL — which cleans unused packages/files and deploys a static site, a Lua CGI admin panel (`/admin`, authenticated against `/etc/shadow`), a vsftpd server rooted at the site directory (FTP password mirrors the root password), Wi-Fi AP settings and firewall rules. The panel can change Wi-Fi settings on any OpenWrt layout. MIT licensed.

---

## Быстрый старт

```sh
# собрать из исходников (нужен Python 3)
python3 tools/build_installer.py
# → dist/openwrt-installer.sh

# закинуть на роутер и запустить
scp -O -o HostKeyAlgorithms=+ssh-rsa dist/openwrt-installer.sh root@192.168.1.1:/tmp/
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sh /tmp/openwrt-installer.sh"
```

`-o HostKeyAlgorithms=+ssh-rsa` и `-O` нужны только для старых OpenWrt (Dropbear без sftp-server и с RSA/SHA-1 ключом). Подробнее — [docs/INSTALL.md](docs/INSTALL.md).

Без scp:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "cat > /tmp/openwrt-installer.sh" < dist/openwrt-installer.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "sh /tmp/openwrt-installer.sh"
```

### Меню

```
+-----------------------------------------------------------+
|  OpenWrt · УНИВЕРСАЛЬНЫЙ УСТАНОВЩИК  v3.0.0               |
|  <модель> · OpenWrt <версия> · флеш ... · RAM ...          |
+-----------------------------------------------------------+
|  1.  УСТАНОВИТЬ                                           |
|      полная очистка системы + сайт + панель /admin        |
|      + FTP + Wi-Fi                                        |
|                                                           |
|  0.  Выход                                                |
+-----------------------------------------------------------+
```

При выборе пункта показывается план, затем `Enter` — и всё выполняется автоматически. Повторный запуск безопасен (идемпотентно).

Неинтерактивные режимы:

```sh
sh openwrt-installer.sh --install   # очистка + установка без меню
sh openwrt-installer.sh --detect    # кандидаты на очистку (TSV)
sh openwrt-installer.sh --status    # краткий статус
```

---

## Что устанавливается

### Панель `/admin`
| Вкладка | Что умеет |
|---|---|
| **Обзор** | модель, версия OpenWrt, ядро, uptime, load, память, флеш, Wi-Fi, сеть, службы, DHCP-аренды |
| **Метрики** | графики CPU/памяти/сети/соединений, топ процессов по памяти, kill процесса |
| **Файлы** | просмотр `/srv/www`, скачивание, загрузка (до 4 МБ), удаление, создание папок |
| **Консоль** | команды с примерами и описанием (без лимита времени, вывод до 128 КБ) |
| **Wi-Fi** | SSID, WPA2-пароль, канал, вкл/выкл; работает на любой раскладке секций (`radio0`, `radio1`, анонимные `@wifi-device[0]`), при отсутствии конфигурации создаёт её |
| **Логи** | `logread`, фильтр |
| **Настройки** | порты сайта/админки/FTP, имя хоста, смена пароля root (он же FTP), службы, бэкап, перезагрузка |

Вход — **пароль root** (`/etc/shadow`, тот же, что у LuCI и SSH). Отдельного пароля у панели нет.

### FTP
- vsftpd, chroot в `/srv/www`, passive 50000–50100;
- логин `ftpuser`, **пароль всегда равен паролю root**:
  - при установке в `/etc/shadow` копируется хеш root;
  - смена пароля через панель обновляет оба;
  - `/usr/libexec/owinst-sync-ftp.sh` + cron раз в 2 минуты чинят расхождение.

### Универсальная очистка
Никаких списков «под модель»:
1. строится граф зависимостей по `/usr/lib/opkg/info/*.control`;
2. кандидаты — «листья», от которых никто не зависит;
3. защищаются: базовые пакеты, пакеты **запущенных процессов**, **включённых служб**, **загруженных модулей ядра**, владельцы критичных файлов (интерпретатор Lua, веб-сервер, Wi-Fi-утилиты, dropbear, netifd, dnsmasq…), а также `luci*`/`rpcd*`;
4. считается реальный размер **в overlay** (что освободится, а не размер из ROM);
5. удаляются файлы без владельца в `/overlay/upper` (кроме `/etc`, `/srv`, `/root`), пустые каталоги, кеши opkg;
6. в конце показывается, сколько освободилось.

При необходимости очистку можно пропустить для теста: `OWINST_SKIP_CLEAN=1 sh openwrt-installer.sh`.

---

## Требования

- OpenWrt (uci/procd/busybox). Тестировалось на 19.07; на 21.02+ должно работать, но не гарантируется;
- root-доступ по SSH;
- для установки `vsftpd`/Lua-модулей — интернет на роутере (или заранее установленные пакеты);
- для панели нужны `lua` и `nixio` (`luci-lib-nixio`) — установщик проверит и попробует поставить;
- ~4 МБ свободного overlay для страниц/панели и пакетов (зависит от модели).

---

## Структура репозитория

```
.
├── panel/                     # файлы, которые ставятся на роутер
│   ├── admin.lua              # панель (Lua CGI) — /srv/www/cgi-bin/admin
│   ├── panel-console.sh       # обёртка консоли — /usr/libexec/panel-console.sh
│   ├── index.html             # редирект /admin/ → /cgi-bin/admin
│   ├── site-index.html        # главная сайта — /srv/www/index.html
│   └── README-ROUTER.txt      # памятка на роутере — /root/README-ROUTER.txt
├── installer/
│   └── openwrt-installer.sh.in  # шаблон установщика (меню, очистка, установка)
├── tools/
│   ├── build_installer.py     # сборка dist/openwrt-installer.sh (Python 3)
│   ├── build_installer.ps1    # то же для PowerShell
│   └── test_wifi.py           # юнит-тесты Wi-Fi-логики панели (lupa)
├── docs/
│   ├── INSTALL.md             # способы передачи файла и установка
│   ├── ARCHITECTURE.md        # как устроены uhttpd/CGI/Lua/панель
│   └── CLEANUP.md             # алгоритм очистки
├── .github/workflows/build.yml
├── CHANGELOG.md
├── LICENSE                    # MIT
└── README.md
```

Сборка подставляет содержимое `panel/*` в heredoc-маркеры шаблона, проверяет маркеры и пишет результат **только с LF** (иначе busybox ash не разберёт файл). Тест Wi-Fi: `pip install lupa && python tools/test_wifi.py`.

---

## Настройки и пароли

- После установки: `/root/README-ROUTER.txt` — краткая памятка.
- Параметры Wi-Fi и порты меняются в панели (вкладки «Wi-Fi» и «Настройки»).
- Пароль root = пароль LuCI/SSH/панели/FTP; меняется в панели → Настройки.

---

## Безопасность

- Панель и CGI выполняются **от root** — не выставляйте их в интернет и не давайте доступ посторонним.
- FTP без TLS: пароль и файлы идут открытым текстом, используйте только в доверенной сети.
- Панель слушает LAN; на WAN правила firewall открывают только выбранные порты.
- Очистка удаляет пакеты: обычный запуск защищает запущенные службы, но всегда проверяйте `--detect` перед удалением на нестандартной сборке.

---

## Лицензия

[MIT](LICENSE). Проект не включает код OpenWrt/LuCI: используется системный `uhttpd`, `vsftpd`, `lua`, `nixio` со своими лицензиями.
