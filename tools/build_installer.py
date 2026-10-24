#!/usr/bin/env python3
"""Сборка одного установочного файла dist/dir320-tui.sh.

Шаблон installer/dir320-tui.sh.in содержит маркеры-заполнители
(@@ADMIN_LUA@@ и т.п.). Скрипт подставляет вместо них содержимое
файлов из panel/ и проверяет, что маркеры-ограничители heredoc
встречаются ровно один раз (иначе heredoc «сломается»).
"""
import argparse
import os
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
TEMPLATE = ROOT / "installer" / "dir320-tui.sh.in"
DEFAULT_OUT = ROOT / "dist" / "dir320-tui.sh"

# токен -> файл
PAYLOADS = {
    "@@ADMIN_LUA@@": ROOT / "panel" / "admin.lua",
    "@@PANEL_CONSOLE@@": ROOT / "panel" / "panel-console.sh",
    "@@ADMIN_INDEX@@": ROOT / "panel" / "index.html",
    "@@SITE_INDEX@@": ROOT / "panel" / "site-index.html",
    "@@README@@": ROOT / "panel" / "README-DIR320.txt",
}

# закрывающие строки heredoc в шаблоне
HEREDOC_MARKERS = [
    "__PANEL_ADMIN_EOF__",
    "__PANEL_CONSOLE_EOF__",
    "__PANEL_AINDEX_EOF__",
    "__PANEL_SITE_EOF__",
    "__PANEL_README_EOF__",
]


def fail(msg: str) -> None:
    print(f"build failed: {msg}", file=sys.stderr)
    sys.exit(1)


def main() -> None:
    ap = argparse.ArgumentParser(description="Собрать dir320-tui.sh")
    ap.add_argument("-o", "--output", default=str(DEFAULT_OUT),
                    help=f"куда писать (по умолчанию {DEFAULT_OUT})")
    args = ap.parse_args()

    if not TEMPLATE.is_file():
        fail(f"нет шаблона {TEMPLATE}")

    text = TEMPLATE.read_text(encoding="utf-8").replace("\r\n", "\n")

    for token, path in PAYLOADS.items():
        if token not in text:
            fail(f"в шаблоне нет токена {token}")
        if not path.is_file():
            fail(f"нет файла {path}")
        if text.count(token) != 1:
            fail(f"токен {token} встречается {text.count(token)} раз")
        payload = path.read_text(encoding="utf-8").replace("\r\n", "\n")
        text = text.replace(token, payload)

    lines = text.split("\n")
    for marker in HEREDOC_MARKERS:
        count = sum(1 for line in lines if line == marker)
        if count != 1:
            fail(f"маркер {marker} встречается {count} раз (в файлах панели есть такая строка?)")

    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    # пишем байтами: text-режим на Windows превратил бы LF в CRLF,
    # а busybox ash на роутере такой файл не разбирает
    data = text.encode("utf-8")
    if b"\r" in data:
        fail("в результате есть CR (CRLF): установщик на роутере не запустится")
    out.write_bytes(data)
    try:
        os.chmod(out, 0o755)
    except OSError:
        pass  # Windows
    print(f"built {out} ({out.stat().st_size} bytes, LF-only)")


if __name__ == "__main__":
    main()
