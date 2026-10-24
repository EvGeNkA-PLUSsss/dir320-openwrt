# Архитектура

## Слои

```
Браузер ── HTTP :80 ──► uhttpd (site) ── CGI ──► /srv/www/cgi-bin/admin (Lua)
                                                   │
                                                   ├─ /etc/shadow          вход (nixio.crypt)
                                                   ├─ /tmp/panelsessions   сессии
                                                   ├─ /proc, df, iwinfo, uci, logread — данные
                                                   ├─ /usr/libexec/panel-console.sh — консоль
                                                   └─ /etc/init.d/*, uci   службы/порты/Wi-Fi
```

На роутере одновременно работают:

| Компонент | Где | Порт | Докрут |
|---|---|---|---|
| `uhttpd.main` (LuCI) | `/www` | 8080 | `lua_prefix=/cgi-bin/luci=...` — Lua выполняется внутри uhttpd |
| `uhttpd.site` (сайт+панель) | `/srv/www` | 80 | `cgi_prefix=/cgi-bin` — обычный CGI-процесс |
| `vsftpd` (procd) | `/srv/www` (chroot) | 21 | `ftpuser`, пароль = root |
| `crond` | — | — | синхронизация пароля FTP/root каждые 2 мин |

## Lua на роутере

`Lua 5.1.5` (`/usr/bin/lua`) + `nixio` (файлы, `crypt`, сокеты, процессы). LuCI целиком на Lua, но у него свой SGI-обработчик внутри uhttpd. Наша панель — самостоятельный Lua CGI, LuCI не использует.

Почему CGI, а не демон: демон панели занимал бы постоянную RAM, а CGI-процесс живёт только на время запроса (~1–2 МБ пиково) — критично на 28 МБ.

## Как uhttpd запускает панель

1. `GET /cgi-bin/admin?action=stats` → uhttpd видит `cgi_prefix=/cgi-bin`, берёт файл `/srv/www/cgi-bin/admin`.
2. Запускает его по shebang `#!/usr/bin/lua`; переменные окружения: `REQUEST_METHOD`, `QUERY_STRING`, `CONTENT_LENGTH`, `CONTENT_TYPE`, `HTTP_COOKIE`, `REMOTE_ADDR`; POST-тело — в stdin.
3. Скрипт пишет в stdout заголовки (`Status:`, `Content-Type:`) → пустая строка → тело. Так отдаются HTML, JSON и файлы на скачивание.
4. `uhttpd.site.script_timeout=0` — консоль/бэкап/скачивание не обрываются. У LuCI лимит 60 с.

## admin.lua

- **Роутер по `action=`**: `login`, `stats`, `metrics`, `top`, `files`, `download`, `upload`, `delete`, `mkdir`, `console`, `settings`, `setports`, `sethostname`, `setpassword`, `service`, `reboot`, `wifi_get`, `wifi_set`, `logs`, `killproc`, `backup`.
- **Вход**: хеш `root` из `/etc/shadow`, проверка `nixio.crypt(pass, hash) == hash` — тот же md5-crypt, что у `passwd`/LuCI. Отдельного пароля нет.
- **Сессии**: `/tmp/panelsessions/<sid>` (RAM), cookie `psid`; CSRF-токен в странице.
- **Пути**: единственный корень файлов — `/srv/www` (он же FTP-корень), защита от `..` и от удаления `/cgi-bin`, `/admin`.
- **Данные**: `/proc/loadavg`, `/proc/meminfo`, `/proc/uptime`, `/proc/stat`, `/proc/net/dev`, `df`, `iwinfo`, `uci show`, `logread`, `sysupgrade -b` (бэкап).
- **Консоль**: `io.popen("/usr/libexec/panel-console.sh '<cmd>'")`, обёртка делает `sh -c`, обрезает вывод до 128 КБ.

## Скрипты

| Файл | Роль |
|---|---|
| `panel-console.sh` | запуск команды из панели: `sh -c "$cmd" </dev/null`, вывод в `/tmp/panel_console.out`, `head -c 131072` |
| `/etc/init.d/vsftpd` | procd-инит: `procd_set_param command /usr/sbin/vsftpd`, respawn. Важно: `service_triggers` пишется в 3 строки — busybox ash не принимает функции в одну строку |
| `/etc/vsftpd.conf` | chroot, `allow_writeable_chroot`, passive 50000–50100, `check_shell=NO` |
| `/usr/libexec/dir320-sync-ftp.sh` | сравнивает хеши root/ftpuser; пишет flash только при расхождении; перезапускает vsftpd |
| `/etc/crontabs/root` | `*/2 * * * * /usr/libexec/dir320-sync-ftp.sh` |

## Установщик

`installer/dir320-tui.sh.in` — шаблон. `tools/build_installer.py` подставляет файлы из `panel/` в heredoc-маркеры (`@@ADMIN_LUA@@` и т.д.) и проверяет, что маркеры не встречаются в содержимом. Результат — один самодостаточный `sh`-файл (`dist/dir320-tui.sh`), который:

1. пишет файлы панели/сайта/README;
2. отключает лишние службы (odhcpd, cron, wan6) — cron затем включается, если нужна синхронизация FTP;
3. ставит vsftpd (`opkg install`, при неудаче — прямой `.ipk` релиза 19.07.10);
4. копирует хеш root в `ftpuser`, настраивает uhttpd (сайт :80, LuCI :8080);
5. настраивает Wi-Fi и firewall;
6. перезапускает службы и печатает адреса.

Псевдо-GUI: ANSI-цвета, заливка фона символами `░`, рамки, меню, чекбоксы. При выводе не в терминал (pipe/лог) автоматически включается plain-режим.

## Поток запроса (вход в панель)

```
POST /cgi-bin/admin?action=login      → uhttpd запускает admin.lua
  → nixio.crypt(pass, hash из /etc/shadow) == hash?
  → /tmp/panelsessions/<sid>, cookie psid, 302 на /cgi-bin/admin
GET /cgi-bin/admin (cookie)           → HTML с вкладками и CSRF
fetch ?action=stats / metrics / files → JSON
```
