#!/usr/bin/env python3
"""Юнит-тест Wi-Fi логики из panel/admin.lua (без роутера).

Извлекает блок функций (uci_set .. set_wifi), подменяет uci/exec/os
заглушками и проверяет сценарии: именованные секции, другие имена,
анонимные секции, отсутствие конфига, ошибка uci, валидация.
"""
import pathlib
import sys

from lupa import LuaRuntime

ROOT = pathlib.Path(__file__).resolve().parents[1]
SRC = (ROOT / "panel" / "admin.lua").read_text(encoding="utf-8")

start = SRC.find("local function uci_set")
end = SRC.find("local function kill_proc")
if start < 0 or end < 0 or end <= start:
    sys.exit("не найдены функции Wi-Fi в panel/admin.lua")
wifi_block = SRC[start:end]

STUBS = r"""
-- ---- заглушки окружения OpenWrt ----
local commands = {}
local uci = {}
local exec_returns = nil

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end
local function shq(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function wifi_info()
  return { essid = "", mode = "", channel = 0, txpower = 0, stations = {}, clients = 0 }
end

local function uci_get(key)
  return trim(uci[key] or "")
end

local function uci_show()
  local lines = {}
  local seen = {}
  for k in pairs(uci) do
    local sec = k:match("^(wireless%.[^%.]+)%.")
    if sec and not seen[sec] then
      seen[sec] = true
      local typ = uci[sec .. ".type"] or ""
      if typ ~= "" then
        lines[#lines + 1] = sec .. "=" .. typ
      end
    end
  end
  table.sort(lines)
  return table.concat(lines, "\n")
end

local function exec(cmd)
  if cmd:find("uci %-q show wireless") then return uci_show() end
  if cmd:find("uci %-q get ") then
    local key = cmd:match("uci %-q get ([^ ]+)")
    return uci[key] or ""
  end
  if cmd:find("iwinfo") then return "" end
  return ""
end

local os = {
  execute = function(cmd)
    commands[#commands + 1] = cmd
    -- shq() цитирует и ключ, и значение: uci set 'key'='value'
    local key, val = cmd:match("^uci set \'([^\']+)\'=\'(.-)\'")
    if not key then key, val = cmd:match("^uci set ([^=]+)=\'(.-)\'") end
    if key then
      -- имитация ошибки uci set по флагу
      if uci.__fail_key == key then return 1 end
      uci[key] = val
      return 0
    end
    if cmd:find("^uci commit wireless") then return 0 end
    if cmd:find("^wifi config") then
      if not next(uci) then
        uci["wireless.radio0.type"] = "wifi-device"
        uci["wireless.radio0.channel"] = "11"
        uci["wireless.radio0.disabled"] = "1"
        uci["wireless.default_radio0.type"] = "wifi-iface"
        uci["wireless.default_radio0.ssid"] = "OpenWrt"
      end
      return 0
    end
    return 0
  end
}
"""

TESTS = r"""
local function reset()
  commands = {}
  uci = {}
end

local function seed_named()
  reset()
  uci["wireless.radio0.type"] = "wifi-device"
  uci["wireless.radio0.channel"] = "11"
  uci["wireless.radio0.disabled"] = "1"
  uci["wireless.default_radio0.type"] = "wifi-iface"
  uci["wireless.default_radio0.ssid"] = "OldNet"
  uci["wireless.default_radio0.key"] = "oldpassword"
  uci["wireless.default_radio0.encryption"] = "psk2"
end

local function seed_renamed()
  reset()
  uci["wireless.radio1.type"] = "wifi-device"
  uci["wireless.radio1.channel"] = "1"
  uci["wireless.radio1.disabled"] = "1"
  uci["wireless.wl0.type"] = "wifi-iface"
  uci["wireless.wl0.ssid"] = "OldNet"
  uci["wireless.wl0.key"] = "oldpassword"
end

local function seed_anonymous()
  reset()
  uci["wireless.@wifi-device[0].type"] = "wifi-device"
  uci["wireless.@wifi-device[0].channel"] = "3"
  uci["wireless.@wifi-device[0].disabled"] = "0"
  uci["wireless.@wifi-iface[0].type"] = "wifi-iface"
  uci["wireless.@wifi-iface[0].ssid"] = "Anon"
end

local function joined() return table.concat(commands, "\n") end

-- 1. именованные секции
seed_named()
local ok, err = set_wifi({enabled="1", ssid="MyNet", key="password123", channel="6"})
assert(ok == true, "case1 set_wifi: " .. tostring(err))
assert(uci["wireless.radio0.disabled"] == "0", "case1 disabled")
assert(uci["wireless.radio0.channel"] == "6", "case1 channel")
assert(uci["wireless.default_radio0.ssid"] == "MyNet", "case1 ssid")
assert(uci["wireless.default_radio0.encryption"] == "psk2", "case1 enc")
assert(uci["wireless.default_radio0.key"] == "password123", "case1 key")
assert(joined():find("uci commit wireless"), "case1 commit")
assert(joined():find("/sbin/wifi reload"), "case1 reload")
print("ok named sections")

-- 2. другие имена секций
seed_renamed()
local cfg = wifi_config()
assert(cfg.present == true, "case2 present")
local ok2, err2 = set_wifi({enabled="1", ssid="Renamed", key="password123", channel="9"})
assert(ok2 == true, "case2 set_wifi: " .. tostring(err2))
assert(uci["wireless.radio1.disabled"] == "0", "case2 disabled")
assert(uci["wireless.radio1.channel"] == "9", "case2 channel")
assert(uci["wireless.wl0.ssid"] == "Renamed", "case2 ssid")
print("ok renamed sections")

-- 3. анонимные секции
seed_anonymous()
local ok3 = set_wifi({enabled="1", ssid="AnonNet", key="password123", channel="5"})
assert(ok3 == true, "case3 set_wifi")
assert(uci["wireless.@wifi-device[0].channel"] == "5", "case3 channel")
assert(uci["wireless.@wifi-iface[0].ssid"] == "AnonNet", "case3 ssid")
print("ok anonymous sections")

-- 4. конфига нет — должен сгенерироваться
reset()
local cfg4 = wifi_config()
assert(cfg4.present == false, "case4 present false")
local ok4, err4 = set_wifi({enabled="1", ssid="FreshNet", key="password123", channel="11"})
assert(ok4 == true, "case4 set_wifi: " .. tostring(err4))
assert(joined():find("wifi config"), "case4 wifi config")
assert(uci["wireless.radio0.ssid"] == nil, "case4 sanity")
assert(uci["wireless.default_radio0.ssid"] == "FreshNet", "case4 ssid")
print("ok missing config generated")

-- 5. ошибка uci set — не возвращать ok
seed_named()
uci.__fail_key = "wireless.radio0.channel"
local ok5, err5 = set_wifi({enabled="1", ssid="XNet", key="password123", channel="4"})
assert(ok5 == false, "case5 should fail")
assert(err5 and err5:find("channel"), "case5 error mentions channel: " .. tostring(err5))
print("ok uci failure reported")

-- 6. валидация
seed_named()
local ok6, err6 = set_wifi({enabled="1", ssid="", key="password123", channel="4"})
assert(ok6 == false and err6:find("SSID"), "case6 bad ssid")
local ok7, err7 = set_wifi({enabled="1", ssid="Net", key="123", channel="4"})
assert(ok7 == false and err7:find("8"), "case7 short password")
local ok8, err8 = set_wifi({enabled="1", ssid="Net", key="password123", channel="14"})
assert(ok8 == false and err8:find("канал"), "case8 bad channel")
print("ok validation")

-- 7. выключение Wi-Fi не требует пароля
seed_named()
local ok9 = set_wifi({enabled="0", ssid="OffNet", key="", channel="11"})
assert(ok9 == true, "case9 disable")
assert(uci["wireless.radio0.disabled"] == "1", "case9 disabled")
print("ok disable without password")

print("ALL WIFI TESTS PASSED")
"""

lua = LuaRuntime(unpack_returned_tuples=True)
# всё одним чанком: local-функции и заглушки должны быть видны тестам
source = "\n".join([STUBS, wifi_block, TESTS])
try:
    lua.execute(source)
except Exception as exc:  # noqa: BLE001
    print("TEST FAILED:", exc)
    sys.exit(1)
