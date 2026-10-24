#!/bin/sh
# Оболочка консоли панели: без ограничения по времени (uhttpd оборвёт запрос
# по своему script_timeout), вывод ограничен 128 КБ.

cmd="$1"
out=/tmp/panel_console.out
: > "$out"

sh -c "$cmd" </dev/null >"$out" 2>&1

head -c 131072 "$out" 2>/dev/null
rm -f "$out"
