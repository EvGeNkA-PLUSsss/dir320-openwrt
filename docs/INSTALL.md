# Установка и передача файла на роутер

## Требования

- OpenWrt (uci/procd/busybox), включённый SSH (Dropbear), пароль root.
- Установщик — обычный POSIX `sh`-скрипт; запускать от `root`.
- Для установки пакетов (`vsftpd`, `lua`, `luci-lib-nixio`) нужен интернет на роутере; без него FTP/панель могут не подняться.

## Особенности старых OpenWrt + современный OpenSSH

Если Dropbear предлагает только `ssh-rsa`, а OpenSSH ≥ 8.8 его запрещает:

```
Unable to negotiate with 192.168.1.1 port 22: no matching host key type found. Their offer: ssh-rsa
```

Решение — клиентский флаг:

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP
```

Для `scp` может понадобиться `-O` (в Dropbear нет sftp-server, новый scp по умолчанию идёт через SFTP):

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa file root@IP:/tmp/
```

Удобно прописать один раз в `~/.ssh/config` (Windows: `%USERPROFILE%\.ssh\config`):

```
Host <IP-роутера>
    HostKeyAlgorithms +ssh-rsa
    PubkeyAcceptedAlgorithms +ssh-rsa
    StrictHostKeyChecking accept-new
```

Если роутер перезаливали/сбрасывали — старый ключ в `known_hosts` устарел:

```sh
ssh-keygen -R <IP-роутера>
```

`-o HostKeyAlgorithms=+ssh-rsa` нужен только клиенту; на роутере ничего менять не надо.

## Способы передачи файла

### 1. scp (рекомендуется)

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa dist/openwrt-installer.sh root@IP:/tmp/
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "sh /tmp/openwrt-installer.sh"
```

### 2. PuTTY (pscp)

`pscp -scp -pw <пароль> dist\openwrt-installer.sh root@IP:/tmp/openwrt-installer.sh`

### 3. Без scp: `cat` через stdin

```sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "cat > /tmp/openwrt-installer.sh" < dist/openwrt-installer.sh
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "sh /tmp/openwrt-installer.sh"
```

Windows `cmd` (обычные кавычки, не двойные — `""путь""` ломает перенаправление):

```cmd
ssh -o HostKeyAlgorithms=+ssh-rsa root@IP "cat > /tmp/openwrt-installer.sh" < "C:\path\openwrt-installer.sh"
```

### 4. WinSCP

Режим **SCP** (не SFTP). Либо поставить на роутер `opkg install openssh-sftp-server` и использовать SFTP.

### 5. Роутер скачивает сам (HTTP)

Только `http://` — без TLS-библиотек HTTPS может не работать:

```sh
ssh root@IP "uclient-fetch -O /tmp/openwrt-installer.sh http://HOST:8000/openwrt-installer.sh && sh /tmp/openwrt-installer.sh"
```

### 6. Через панель `/admin` (если уже установлена)

Панель → «Файлы» → загрузить (файл ляжет в `/srv/www`) → по SSH `cp /srv/www/openwrt-installer.sh /tmp/ && sh /tmp/openwrt-installer.sh`.

### 7. IPv6 link-local

Если IPv4-адрес на LAN «съехал»:

```sh
scp -6 -O -o HostKeyAlgorithms=+ssh-rsa dist/openwrt-installer.sh "root@[fe80::xxxx:xxxx:xxxx:xxxx%IF]:/tmp/"
```

Индекс интерфейса смотрите в `ip -6 addr` (Windows: `ping -6 fe80::...%IF`).

## Проверка и запуск

```sh
ssh root@IP "sha256sum /tmp/openwrt-installer.sh"   # сравните с локальным
ssh root@IP "sh /tmp/openwrt-installer.sh"          # меню с единственным пунктом УСТАНОВИТЬ
```

Неинтерактивно:

```sh
sh /tmp/openwrt-installer.sh --install
```

`/tmp` — это RAM: после перезагрузки файл исчезнет. Установщик сам кладёт копию в `/root/openwrt-installer.sh`, так что повторный запуск возможен оттуда.

## Обновление только панели (без переустановки)

```sh
scp -O -o HostKeyAlgorithms=+ssh-rsa panel/admin.lua root@IP:/srv/www/cgi-bin/admin
```

Панель — обычный CGI, перезапуск uhttpd не требуется (обновите страницу с Ctrl+F5).

## Проверка после установки

- `http://IP/` — сайт;
- `http://IP/admin` — панель (пароль root);
- LuCI — порт смотрите в выводе установщика (`uci show uhttpd | grep listen_http`);
- FTP: `ftpuser` / пароль root, файлы сразу видны на сайте;
- Wi-Fi — SSID/пароль из вывода установщика или из панели.

## Другие проблемы

| Симптом | Решение |
|---|---|
| `no matching host key type found` | `-o HostKeyAlgorithms=+ssh-rsa` |
| `REMOTE HOST IDENTIFICATION HAS CHANGED` | `ssh-keygen -R <IP>` |
| `scp: Connection closed` / SFTP-ошибки | `scp -O`, либо `opkg install openssh-sftp-server` |
| `opkg install vsftpd` падает по памяти | освободите память (`sync; echo 3 > /proc/sys/vm/drop_caches`), повторите |
| Панель отдаёт 502/пустую страницу | `lua -e 'assert(loadfile("/srv/www/cgi-bin/admin"))'`, логи `logread | grep uhttpd` |
| Wi-Fi не поднялся | `iwinfo`, `logread | grep -i wlan`, проверьте канал/страну |
