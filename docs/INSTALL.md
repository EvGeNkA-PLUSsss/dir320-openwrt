# Установка и передача файла на роутер

## Требования

- OpenWrt 19.07.x на роутере, включённый SSH (Dropbear), пароль root.
- Установщик — обычный POSIX `sh`-скрипт; запускать от `root`.
- Для установки vsftpd нужен интернет на роутере (или локальный `.ipk`).

## Особенности OpenWrt 19.07 + современный OpenSSH

Dropbear 2019.78 предлагает только host key `ssh-rsa` (RSA/SHA-1), который OpenSSH ≥ 8.8 по умолчанию запрещает:

```
Unable to negotiate with 192.168.1.1 port 22: no matching host key type found. Their offer: ssh-rsa
```

Решение — добавить клиентский флаг:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1
```

А для `scp` ещё и `-O` (в dropbear нет sftp-server, новый scp по умолчанию идёт через SFTP):

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa file root@192.168.1.1:/tmp/
```

Удобно прописать один раз в `~/.ssh/config` (Windows: `%USERPROFILE%\.ssh\config`):

```
Host 192.168.1.1
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    StrictHostKeyChecking accept-new
```

Если роутер перезаливали/сбрасывали — старый ключ в `known_hosts` устарел:

```sh
ssh-keygen -R 192.168.1.1
```

`-o HostKeyAlgorithms=+ssh-rsa` нужен только клиенту; на роутере ничего менять не надо.

## Способы передачи файла

Все варианты проверены на DIR-320 B1 (OpenSSH на Windows 10/11, Linux/macOS).

### 1. scp (рекомендуется)

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa dist/dir320-tui.sh root@192.168.1.1:/tmp/install.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sh /tmp/install.sh"
```

### 2. scp через PuTTY (pscp)

`pscp -scp -pw <пароль> dist\dir320-tui.sh root@192.168.1.1:/tmp/install.sh`

### 3. Без scp: `cat` через stdin

Linux/macOS:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "cat > /tmp/install.sh" < dist/dir320-tui.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sh /tmp/install.sh"
```

Windows `cmd` (обратите внимание: **обычные** кавычки, не двойные — `""путь""` ломает перенаправление):

```cmd
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "cat > /tmp/install.sh" < "C:\path\to\dir320-tui.sh"
```

### 4. Через WinSCP

WinSCP в режиме **SCP** (не SFTP), либо ставим на роутер `opkg install openssh-sftp-server` и пользуемся SFTP.

### 5. Роутер скачивает сам (HTTP)

Только `http://` — в системах без `libustream-ssl` нет HTTPS:

```sh
ssh root@192.168.1.1 "uclient-fetch -O /tmp/install.sh http://192.168.1.1:8000/dir320-tui.sh && sh /tmp/install.sh"
```

(на компьютере поднять `python3 -m http.server 8000`; Windows Firewall должен разрешать входящие).

### 6. Через панель `/admin` (если уже установлена)

Панель → «Файлы» → «Загрузить файл» (файл ляжет в `/srv/www`) → по SSH `cp /srv/www/dir320-tui.sh /tmp/ && sh /tmp/install.sh`.

### 7. IPv6 link-local

Если IPv4-адрес на LAN «съехал» (типично для Windows с несколькими DHCP):

```sh
scp -6 -O -o HostKeyAlgorithms=+ssh-rsa dist/dir320-tui.sh "root@[fe80::xxxx:xxxx:xxxx:xxxx%19]:/tmp/install.sh"
```

Адрес интерфейса роутера смотрите в `ip -6 addr` (или в Windows: `ping -6 fe80::...%<ifindex>`).

## Проверка перед запуском

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@192.168.1.1 "sha256sum /tmp/install.sh"
# сравните с локальным
sha256sum dist/dir320-tui.sh
```

## Запуск установщика

```sh
sh /tmp/install.sh          # псевдо-GUI в терминале
```

Неинтерактивно:

```sh
sh /tmp/install.sh --install-auto
```

Учтите: `/tmp` — это RAM, после перезагрузки файл исчезнет. Если хотите оставить установщик на роутере:

```sh
cp /tmp/install.sh /root/
```

## Обновление только панели (без переустановки настроек)

Установщик перезаписывает файлы панели, конфиги uhttpd/vsftpd/Wi-Fi и firewall. Если нужно поменять только `admin.lua`:

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa panel/admin.lua root@192.168.1.1:/srv/www/cgi-bin/admin
```

Панель — обычный CGI, перезапуск uhttpd не требуется (но браузер лучше обновить через Ctrl+F5).

## Проверка после установки

```sh
ssh root@192.168.1.1 "sh /tmp/install.sh --status"
```

Ожидается:

- `http://192.168.1.1/` — 200;
- `http://192.168.1.1/admin` — форма входа, пароль root;
- `http://192.168.1.1:8080/` — LuCI;
- FTP: `ftpuser` / пароль root, файлы сразу видны на сайте;
- Wi-Fi: SSID из настроек.

## Другие проблемы

| Симптом | Решение |
|---|---|
| `no matching host key type found` | `-o HostKeyAlgorithms=+ssh-rsa` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R 192.168.1.1` |
| `scp: Connection closed` / SFTP-ошибки | `scp -O`, либо `opkg install openssh-sftp-server` |
| `opkg install vsftpd` падает по памяти | установщик пробует fallback на прямой `.ipk`; освободите память (`sync; echo 3 > /proc/sys/vm/drop_caches`) |
| Панель отдаёт 502/пустую страницу | `lua -e 'assert(loadfile("/srv/www/cgi-bin/admin"))'`, логи `logread | grep uhttpd` |
| Wi-Fi не поднялся | `iwinfo`, `logread | grep -i wlan`; проверьте канал/страну |
