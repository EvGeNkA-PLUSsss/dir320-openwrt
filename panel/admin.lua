#!/usr/bin/lua
-- =====================================================================
--  DIR-320 B1 / OpenWrt 19.07 — контрольная панель (:80/admin)
--  Авторизация: логин/пароль из /etc/shadow (те же, что у LuCI),
--  проверка через nixio.crypt() — тот же механизм, что использует LuCI.
-- =====================================================================

local nixio = require "nixio"
local fs    = nixio.fs

local SESDIR  = "/tmp/panelsessions"
local CONSOLE = "/usr/libexec/panel-console.sh"
local ROOTS   = { www = "/srv/www" }
local MAX_UPLOAD = 4 * 1024 * 1024
local MAX_DOWNLOAD = 8 * 1024 * 1024
local SESSION_TTL = 8 * 3600

-- ============================ helpers ================================

local function env(k)
  local v = os.getenv(k)
  if v == nil then return "" end
  return v
end

local function shq(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function readfile(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local d = f:read("*a")
  f:close()
  return d
end

local function writefile(p, d)
  local f = io.open(p, "wb")
  if not f then return false end
  local ok = f:write(d)
  f:close()
  return ok ~= nil
end

local function exec(cmd)
  local f = io.popen(cmd, "r")
  if not f then return "" end
  local out = f:read("*a") or ""
  f:close()
  return out
end

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function urlencode(s)
  return (tostring(s):gsub("([^%w%.%-_~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function urldecode(s)
  s = tostring(s or ""):gsub("+", " ")
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

local function parse_qs(s)
  local t = {}
  for pair in tostring(s or ""):gmatch("[^&]+") do
    local k, v = pair:match("^([^=]*)=?(.*)$")
    if k and k ~= "" then t[urldecode(k)] = urldecode(v or "") end
  end
  return t
end

local function htmlesc(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;")
  s = s:gsub('"', "&quot;"):gsub("'", "&#39;")
  return s
end

local function json_escape(s)
  return (tostring(s):gsub('[%z\1-\31\\"]', function(c)
    if c == '"' then return '\\"'
    elseif c == "\\" then return "\\\\"
    elseif c == "\n" then return "\\n"
    elseif c == "\r" then return "\\r"
    elseif c == "\t" then return "\\t"
    else return string.format("\\u%04x", c:byte()) end
  end))
end

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" then return false end
    n = n + 1
  end
  return n == #t
end

local json_encode
json_encode = function(v)
  local t = type(v)
  if v == nil then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.14g", v)
  elseif t == "string" then return '"' .. json_escape(v) .. '"'
  elseif t == "table" then
    local parts = {}
    if is_array(v) then
      for i = 1, #v do parts[#parts + 1] = json_encode(v[i]) end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    for k, val in pairs(v) do
      if val ~= nil then
        parts[#parts + 1] = json_encode(tostring(k)) .. ":" .. json_encode(val)
      end
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end

local function send_headers(status, ctype, extra)
  io.write("Status: " .. status .. "\r\n")
  io.write("Content-Type: " .. ctype .. "\r\n")
  io.write("Cache-Control: no-store, no-cache, must-revalidate\r\n")
  io.write("X-Content-Type-Options: nosniff\r\n")
  if extra then
    for k, v in pairs(extra) do io.write(k .. ": " .. v .. "\r\n") end
  end
  io.write("\r\n")
end

local function respond(status, ctype, body, extra)
  send_headers(status, ctype, extra)
  if body and #body > 0 then io.write(body) end
end

local function json_out(tbl, extra)
  respond("200 OK", "application/json; charset=utf-8", json_encode(tbl), extra)
end

local function err_json(msg, status)
  respond(status or "400 Bad Request", "application/json; charset=utf-8",
          json_encode({ error = msg }))
end

local function rand_hex(nbytes)
  local f = io.open("/dev/urandom", "rb")
  if not f then return string.format("%08x%08x", os.time(), math.random(1, 2^31)) end
  local b = f:read(nbytes) or ""
  f:close()
  return (b:gsub(".", function(c) return string.format("%02x", c:byte()) end))
end

-- ============================ auth ===================================

local function shadow_hash(user)
  local data = readfile("/etc/shadow") or ""
  for line in data:gmatch("[^\n]+") do
    local u, h = line:match("^([^:]+):([^:]*):")
    if u == user then return h end
  end
  return nil
end

local function check_pass(user, pass)
  if not user or not pass then return false end
  if #user < 1 or #user > 32 or #pass < 1 or #pass > 128 then return false end
  local h = shadow_hash(user)
  if not h or h == "" or h == "*" or h == "!" or h:sub(1, 1) == "!" then return false end
  local ok, res = pcall(nixio.crypt, pass, h)
  return ok and res == h
end

local function ensure_sesdir()
  os.execute("mkdir -p " .. shq(SESDIR) .. " 2>/dev/null")
end

local function new_session(user)
  ensure_sesdir()
  local tok  = rand_hex(16)
  local csrf = rand_hex(16)
  writefile(SESDIR .. "/" .. tok,
            user .. "|" .. tostring(os.time() + SESSION_TTL) .. "|" .. csrf)
  return tok, csrf
end

local function current_session()
  local cookie = env("HTTP_COOKIE")
  local tok = cookie:match("panel=([%w]+)")
  if not tok then return nil end
  local data = readfile(SESDIR .. "/" .. tok)
  if not data then return nil end
  local user, exp, csrf = data:match("^([^|]*)|(%d+)|([%w]+)")
  if not user then return nil end
  if tonumber(exp or 0) < os.time() then
    os.remove(SESDIR .. "/" .. tok)
    return nil
  end
  return { token = tok, user = user, csrf = csrf }
end

local function drop_session(sess)
  if sess and sess.token then os.remove(SESDIR .. "/" .. sess.token) end
end

local function login_guard()
  local d = readfile("/tmp/panellogin") or "0|0"
  local f, w = d:match("^(%d+)|(%d+)$")
  f, w = tonumber(f) or 0, tonumber(w) or 0
  if os.time() - w > 120 then f, w = 0, os.time() end
  return f, w
end

-- ============================ data ===================================

local function ipairs4()
  local out = {}
  for line in exec("ip -4 -o addr show 2>/dev/null"):gmatch("[^\n]+") do
    local ifname = line:match("^%d+:%s+([%w%.%-]+)")
    local addr, prefix = line:match("inet%s+([%d%.]+)/(%d+)")
    if ifname and addr then out[#out + 1] = { iface = ifname, addr = addr, prefix = tonumber(prefix) } end
  end
  return out
end

local function meminfo()
  local t = {}
  local d = readfile("/proc/meminfo") or ""
  for k, v in d:gmatch("([%w_]+):%s+(%d+)") do t[k] = tonumber(v) end
  return t
end

local function disk_info()
  local sv = fs.statvfs("/")
  if not sv then return { total = 0, free = 0, used = 0 } end
  local total = sv.blocks * sv.bsize
  local free  = sv.bavail * sv.frsize
  return { total = total, free = free, used = total - free }
end

local function proc_count()
  local n = 0
  for name in fs.dir("/proc") do
    if name:match("^%d+$") then n = n + 1 end
  end
  return n
end

local function conntrack_count()
  local f = io.open("/proc/net/nf_conntrack")
  if not f then return 0 end
  local n = 0
  for _ in f:lines() do n = n + 1 end
  f:close()
  return n
end

local function uptime_sec()
  local d = readfile("/proc/uptime") or ""
  return tonumber(d:match("^(%d+%.?%d*)")) or 0
end

local function loadavg()
  local d = readfile("/proc/loadavg") or ""
  local a, b, c = d:match("(%S+)%s+(%S+)%s+(%S+)")
  return { tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0 }
end

local function ncpu()
  local n = 0
  for line in (readfile("/proc/stat") or ""):gmatch("[^\n]+") do
    if line:match("^cpu%d") then n = n + 1 end
  end
  if n == 0 then n = 1 end
  return n
end

local function netdev()
  local t = {}
  for line in (readfile("/proc/net/dev") or ""):gmatch("[^\n]+") do
    local name, rest = line:match("^%s*([%w%.%-_]+):%s*(.+)$")
    if name then
      local f = {}
      for v in rest:gmatch("%S+") do f[#f + 1] = tonumber(v) or 0 end
      t[name] = { rx = f[1] or 0, tx = f[9] or 0 }
    end
  end
  return t
end

local function wifi_info()
  local info = exec("iwinfo wlan0 info 2>/dev/null")
  local essid   = info:match('ESSID:%s*"(.-)"') or ""
  local mode    = trim(info:match("Mode:%s*(%S+)") or "")
  local channel = tonumber(info:match("Channel:%s*(%d+)") or 0)
  local txpower = tonumber(info:match("Tx%-Power:%s*(%d+)") or 0)
  local stations = {}
  local al = exec("iwinfo wlan0 assoclist 2>/dev/null")
  for mac, sig in al:gmatch("(%x%x:%x%x:%x%x:%x%x:%x%x:%x%x)%s+(-?%d+) dBm") do
    stations[#stations + 1] = { mac = mac, signal = tonumber(sig) }
  end
  return { essid = essid, mode = mode, channel = channel,
           txpower = txpower, stations = stations, clients = #stations }
end

local function dhcp_leases()
  local out = {}
  for line in (readfile("/tmp/dhcp.leases") or ""):gmatch("[^\n]+") do
    local exp, mac, ip, host = line:match("^(%d+)%s+(%S+)%s+(%S+)%s+(.-)%s*$")
    if exp then
      out[#out + 1] = { expires = tonumber(exp), mac = mac, ip = ip,
                        host = (host ~= "" and host or "-") }
    end
  end
  return out
end

local function service_list()
  local ps = exec("ps 2>/dev/null")
  local fw = exec("iptables -S 2>/dev/null")
  local fw_running = fw:find("fw3", 1, true) ~= nil
  local defs = {
    { name = "uhttpd",  label = "Веб-сервер",  pat = "uhttpd"  },
    { name = "vsftpd",  label = "FTP",         pat = "vsftpd"  },
    { name = "hostapd", label = "Wi-Fi",       pat = "hostapd" },
    { name = "dropbear",label = "SSH",         pat = "dropbear"},
    { name = "dnsmasq", label = "DHCP/DNS",    pat = "dnsmasq" },
    { name = "firewall",label = "Firewall",    pat = "fw3"     },
  }
  local out = {}
  for _, d in ipairs(defs) do
    local running
    if d.name == "firewall" then
      running = fw_running
    else
      running = ps:find(d.pat, 1, true) ~= nil
    end
    out[#out + 1] = { name = d.name, label = d.label, running = running }
  end
  return out
end

local function top_procs()
  local list = {}
  for name in fs.dir("/proc") do
    if name:match("^%d+$") then
      local statm = readfile("/proc/" .. name .. "/statm")
      if statm then
        local rss_pages = tonumber(statm:match("^%d+%s+(%d+)")) or 0
        local cmd = (readfile("/proc/" .. name .. "/cmdline") or ""):gsub("%z", " ")
        cmd = trim(cmd)
        if cmd ~= "" and rss_pages > 0 then
          list[#list + 1] = { pid = tonumber(name), rss = rss_pages * 4, cmd = cmd:sub(1, 70) }
        end
      end
    end
  end
  table.sort(list, function(a, b) return a.rss > b.rss end)
  local out = {}
  for i = 1, math.min(#list, 10) do out[i] = list[i] end
  return out
end

local function uci_get(key)
  return trim(exec("uci -q get " .. shq(key) .. " 2>/dev/null"))
end

local function settings_data()
  local site = uci_get("uhttpd.site.listen_http"):match(":(%d+)") or "80"
  local luci = uci_get("uhttpd.main.listen_http"):match(":(%d+)") or "8080"
  local ftp  = (readfile("/etc/vsftpd.conf") or ""):match("listen_port=(%d+)") or "21"
  return {
    site = tonumber(site), luci = tonumber(luci), ftp = tonumber(ftp),
    hostname = uci_get("system.@system[0].hostname"),
    model = trim((readfile("/tmp/sysinfo/model") or ""):gsub("%z", "")),
    version = (readfile("/etc/openwrt_release") or ""):match("DISTRIB_DESCRIPTION='(.-)'") or "",
    kernel = trim(readfile("/proc/sys/kernel/osrelease") or ""),
  }
end

-- ============================ files ==================================

local function safe_path(rootkey, rel)
  local root = ROOTS[rootkey]
  if not root then return nil end
  rel = tostring(rel or "/"):gsub("\\", "/")
  if rel:find("%.%.") or rel:find("%z") then return nil end
  if rel:sub(1, 1) ~= "/" then rel = "/" .. rel end
  local full = root .. (rel == "/" and "" or rel)
  return full, (rel == "/" and "/" or rel)
end

local function human_size(n)
  n = tonumber(n) or 0
  local units = { "Б", "КБ", "МБ", "ГБ" }
  local i = 1
  while n >= 1024 and i < #units do n = n / 1024; i = i + 1 end
  if i == 1 then return string.format("%d %s", n, units[i]) end
  return string.format("%.1f %s", n, units[i])
end

-- ============================ wifi ==================================

local function uci_set(key, val)
  local rc = os.execute("uci set " .. shq(key) .. "=" .. shq(val) .. " 2>/dev/null")
  return rc == 0 or rc == true
end

-- Имена секций wifi-device / wifi-iface. Работает и с именованными
-- (radio0/default_radio0), и с анонимными (@wifi-device[0]) секциями.
local function wifi_sections()
  local out = exec("uci -q show wireless 2>/dev/null")
  if out == "" then return nil, nil end
  local dev, iface
  -- строки вида: wireless.radio0=wifi-device и wireless.radio0.channel='11'
  for line in out:gmatch("[^\n]+") do
    local sec, typ = line:match("^wireless%.([^%=]+)=([%w%-]+)$")
    if sec then
      if typ == "wifi-device" and not dev then dev = sec end
      if typ == "wifi-iface" and not iface then iface = sec end
    end
  end
  return dev, iface
end

-- Если /etc/config/wireless вообще нет (чистая прошивка) — генерируем его
local function ensure_wireless()
  if exec("uci -q show wireless 2>/dev/null") ~= "" then return true end
  os.execute("wifi config >/dev/null 2>&1")
  if exec("uci -q show wireless 2>/dev/null") == "" then
    os.execute("wifi detect > /etc/config/wireless 2>/dev/null")
  end
  return exec("uci -q show wireless 2>/dev/null") ~= ""
end

local function wifi_config()
  local inf = wifi_info()
  local dev, iface = wifi_sections()
  if not dev then
    return { present = false, enabled = false, ssid = inf.essid or "",
             key = "", channel = inf.channel or 0, encryption = "", info = inf }
  end
  local dis = uci_get("wireless." .. dev .. ".disabled")
  local ssid = iface and uci_get("wireless." .. iface .. ".ssid") or ""
  local key = iface and uci_get("wireless." .. iface .. ".key") or ""
  local enc = iface and uci_get("wireless." .. iface .. ".encryption") or ""
  return {
    present = true,
    enabled = (dis ~= "1"),
    ssid = ssid ~= "" and ssid or (inf.essid or ""),
    key = key,
    channel = tonumber(uci_get("wireless." .. dev .. ".channel")) or inf.channel or 0,
    encryption = enc,
    info = inf,
  }
end

local function set_wifi(f)
  local ssid = trim(f.ssid or "")
  local key = f.key or ""
  local ch = tonumber(f.channel) or 11
  local en = (f.enabled == "1" or f.enabled == "true")
  if ssid == "" or #ssid > 32 then return false, "неверный SSID (1..32 символа)" end
  if en and #key < 8 then return false, "пароль Wi-Fi от 8 до 63 символов" end
  if #key > 63 then return false, "пароль Wi-Fi длиннее 63 символов" end
  if ch < 1 or ch > 13 then return false, "канал должен быть 1..13" end
  if not ensure_wireless() then return false, "Wi-Fi не найден: нет /etc/config/wireless" end
  local dev, iface = wifi_sections()
  if not dev then return false, "в /etc/config/wireless нет wifi-device" end
  if not iface then
    os.execute("uci add wireless wifi-iface >/dev/null 2>&1")
    dev, iface = wifi_sections()
  end
  if not iface then return false, "не удалось создать wifi-iface" end

  local sets = {
    { "wireless." .. dev .. ".disabled", en and "0" or "1" },
    { "wireless." .. dev .. ".channel", tostring(ch) },
    { "wireless." .. iface .. ".mode", "ap" },
    { "wireless." .. iface .. ".network", "lan" },
    { "wireless." .. iface .. ".ssid", ssid },
  }
  if en and #key >= 8 then
    sets[#sets + 1] = { "wireless." .. iface .. ".encryption", "psk2" }
    sets[#sets + 1] = { "wireless." .. iface .. ".key", key }
  end
  for _, s in ipairs(sets) do
    if not uci_set(s[1], s[2]) then
      return false, "не удалось применить " .. s[1]
    end
  end
  os.execute("uci commit wireless")
  -- в фоне: ответ должен уйти раньше, чем перезапустится Wi-Fi
  os.execute("(sleep 1; /sbin/wifi reload) >/dev/null 2>&1 &")
  return true, "ok"
end

local function kill_proc(pid)
  pid = tonumber(pid)
  local me = tonumber((readfile("/proc/self/stat") or ""):match("^(%d+)"))
  if not pid or pid < 2 or pid > 65535 then return false, "неверный PID" end
  if pid == 1 then return false, "init убивать нельзя" end
  if me and pid == me then return false, "это процесс панели" end
  os.execute("kill -9 " .. pid .. " 2>/dev/null")
  return true, "ok"
end

local function do_backup()
  os.execute("rm -f /tmp/panel-backup.tar.gz; sysupgrade -b /tmp/panel-backup.tar.gz >/dev/null 2>&1")
  local d = readfile("/tmp/panel-backup.tar.gz")
  os.remove("/tmp/panel-backup.tar.gz")
  if not d or #d < 64 then
    respond("500 Internal Server Error", "text/plain", "backup failed")
    return
  end
  respond("200 OK", "application/gzip", d, {
    ["Content-Disposition"] = 'attachment; filename="dir320-backup.tar.gz"',
  })
end
-- ============================ actions ================================

local action = "page"
local q = {}
local form = {}
local raw_body = nil

local function api_guard(sess)
  if not sess then
    err_json("auth required", "401 Unauthorized")
    return false
  end
  return true
end

local function csrf_ok(sess)
  if not sess then return false end
  local token = form.csrf or q.csrf or ""
  return token == sess.csrf
end

local function api_stats()
  local mi = meminfo()
  local disk = disk_info()
  local wifi = wifi_info()
  local s = settings_data()
  return {
    hostname = s.hostname,
    model = s.model,
    version = s.version,
    kernel = s.kernel,
    time = os.time(),
    uptime = uptime_sec(),
    load = loadavg(),
    ncpu = ncpu(),
    mem = {
      total = (mi.MemTotal or 0) * 1024,
      free = (mi.MemFree or 0) * 1024,
      available = (mi.MemAvailable or mi.MemFree or 0) * 1024,
      buffers = (mi.Buffers or 0) * 1024,
      cached = (mi.Cached or 0) * 1024,
    },
    disk = disk,
    temp = (function()
      local t = readfile("/sys/class/thermal/thermal_zone0/temp")
      if t then return tonumber(t) / 1000 end
      return nil
    end)(),
    wifi = wifi,
    services = service_list(),
    ips = ipairs4(),
    leases = dhcp_leases(),
    procs = proc_count(),
    conns = conntrack_count(),
  }
end

local function api_metrics()
  local mi = meminfo()
  return {
    load = loadavg(),
    mem = { total = (mi.MemTotal or 0) * 1024,
            available = (mi.MemAvailable or mi.MemFree or 0) * 1024 },
    disk = disk_info(),
    net = netdev(),
    procs = proc_count(),
    conns = conntrack_count(),
    wifi = { clients = #wifi_info().stations },
    uptime = uptime_sec(),
  }
end

local function api_files(rootkey, rel)
  local full, relp = safe_path(rootkey, rel)
  if not full then return { error = "недопустимый путь" } end
  local st = fs.stat(full)
  if not st then return { error = "не найдено", path = relp } end
  if st.type ~= "dir" then
    return { error = "не каталог", path = relp }
  end
  local items = {}
  for name in fs.dir(full) do
    if name ~= "." and name ~= ".." then
      local p = (relp == "/" and "" or relp) .. "/" .. name
      local ist = fs.stat(full .. "/" .. name)
      local t = "file"
      if ist then
        if ist.type == "dir" then t = "dir"
        elseif ist.type == "lnk" then t = "link" end
      end
      items[#items + 1] = {
        name = name,
        path = p,
        type = t,
        size = ist and ist.size or 0,
        size_h = human_size(ist and ist.size or 0),
        mtime = ist and ist.mtime or 0,
      }
    end
  end
  table.sort(items, function(a, b)
    if a.type ~= b.type then
      if a.type == "dir" then return true end
      if b.type == "dir" then return false end
    end
    return a.name:lower() < b.name:lower()
  end)
  local sv = fs.statvfs(full)
  return {
    root = rootkey,
    path = relp,
    items = items,
    free = sv and (sv.bavail * sv.frsize) or 0,
    total = sv and (sv.blocks * sv.bsize) or 0,
  }
end

local function do_download(rootkey, rel)
  local full = safe_path(rootkey, rel)
  if not full then respond("400 Bad Request", "text/plain", "bad path") return end
  local st = fs.stat(full)
  if not st or st.type ~= "reg" then respond("404 Not Found", "text/plain", "not found") return end
  if st.size > MAX_DOWNLOAD then respond("413 Payload Too Large", "text/plain", "too large") return end
  local data = readfile(full)
  if not data then respond("403 Forbidden", "text/plain", "read error") return end
  local name = fs.basename(full):gsub('[^%w%.%_%-%(%)%[%] ]', "_")
  respond("200 OK", "application/octet-stream", data, {
    ["Content-Disposition"] = 'attachment; filename="' .. name .. '"',
  })
end

local function do_delete(rootkey, rel)
  local full = safe_path(rootkey, rel)
  if not full then return false, "недопустимый путь" end
  if rel:sub(1, 8) == "/cgi-bin" or rel:sub(1, 6) == "/admin" then
    return false, "системные файлы панели удалять нельзя"
  end
  if rel == "/" or full == ROOTS[rootkey] then return false, "нельзя удалить корень" end
  local st = fs.stat(full)
  if not st then return false, "не найдено" end
  if st.type == "dir" then
    for name in fs.dir(full) do
      if name ~= "." and name ~= ".." then return false, "каталог не пуст" end
    end
    local ok = os.remove(full)
    return ok ~= nil, ok and "ok" or "ошибка rmdir"
  end
  local ok = os.remove(full)
  return ok ~= nil, ok and "ok" or "ошибка удаления"
end

local function do_mkdir(rootkey, rel, name)
  local full, relp = safe_path(rootkey, rel)
  if not full then return false, "недопустимый путь" end
  if not name or name == "" or name:find("[/%z]") or name == "." or name == ".." then
    return false, "недопустимое имя"
  end
  local p = full .. "/" .. name
  local ok = os.execute("mkdir " .. shq(p) .. " 2>/dev/null")
  return ok == 0 or ok == true, (ok == 0 or ok == true) and "ok" or "не удалось создать"
end

local function do_upload(rootkey, rel, name)
  local full, relp = safe_path(rootkey, rel)
  if not full then return false, "недопустимый путь" end
  if not name or name == "" or name:find("[/%z]") or name == "." or name == ".." then
    return false, "недопустимое имя"
  end
  local len = #(raw_body or "")
  if len == 0 then return false, "пустой файл" end
  if len > MAX_UPLOAD then return false, "файл больше 4 МБ" end
  local sv = fs.statvfs(full)
  local free = sv and (sv.bavail * sv.frsize) or 0
  if len + 262144 > free then return false, "мало свободного места" end
  local p = full .. "/" .. name
  if not writefile(p, raw_body) then return false, "ошибка записи" end
  return true, "ok"
end

local function do_console(cmd)
  cmd = tostring(cmd or "")
  if #cmd == 0 then return "", "" end
  if #cmd > 2000 then return "", "команда слишком длинная" end
  local out = exec("/usr/libexec/panel-console.sh " .. shq(cmd) .. " 2>&1")
  if #out > 131072 then out = out:sub(1, 131072) .. "\n...[вывод обрезан]" end
  return out, ""
end

local function apply_ports(site, luci, ftp)
  if not (site and luci and ftp) then return false, "неверные порты" end
  if site < 1 or site > 65535 or luci < 1 or luci > 65535 or ftp < 1 or ftp > 65535 then
    return false, "порт вне диапазона 1..65535"
  end
  if site == luci or site == ftp or luci == ftp then
    return false, "порты должны различаться"
  end
  os.execute("uci -q delete uhttpd.site.listen_http")
  os.execute("uci set uhttpd.site.listen_http=" .. shq("0.0.0.0:" .. site))
  os.execute("uci add_list uhttpd.site.listen_http=" .. shq("[::]:" .. site))
  os.execute("uci -q delete uhttpd.main.listen_http")
  os.execute("uci set uhttpd.main.listen_http=" .. shq("0.0.0.0:" .. luci))
  os.execute("uci add_list uhttpd.main.listen_http=" .. shq("[::]:" .. luci))
  os.execute("uci commit uhttpd")
  os.execute("uci set firewall.Allow_Site_80.dest_port=" .. shq(tostring(site)))
  os.execute("uci set firewall.Allow_LuCI_8080.dest_port=" .. shq(tostring(luci)))
  os.execute("uci set firewall.Allow_FTP_21.dest_port=" .. shq(tostring(ftp)))
  os.execute("uci set firewall.Allow_Site_80.name=" .. shq("Allow_Site_" .. site))
  os.execute("uci set firewall.Allow_LuCI_8080.name=" .. shq("Allow_LuCI_" .. luci))
  os.execute("uci set firewall.Allow_FTP_21.name=" .. shq("Allow_FTP_" .. ftp))
  os.execute("uci commit firewall")
  local conf = readfile("/etc/vsftpd.conf") or ""
  if conf:match("listen_port=%d+") then
    conf = conf:gsub("listen_port=%d+", "listen_port=" .. ftp)
  else
    conf = conf .. "\nlisten_port=" .. ftp .. "\n"
  end
  writefile("/etc/vsftpd.conf", conf)
  os.execute("(sleep 6; /etc/init.d/uhttpd restart; /etc/init.d/firewall reload; /etc/init.d/vsftpd restart) >/dev/null 2>&1 &")
  return true, "ok"
end

local function set_password(pass)
  if not pass or #pass < 6 then return false, "пароль короче 6 символов" end
  if #pass > 128 then return false, "пароль слишком длинный" end
  local salt = rand_hex(4)
  local hash = nixio.crypt(pass, "$1$" .. salt)
  if not hash or #hash < 20 then return false, "ошибка хеширования" end
  local data = readfile("/etc/shadow") or ""
  local out = {}
  local changed, ftp_synced = false, false
  for line in data:gmatch("[^\n]+") do
    local u = line:match("^([^:]+):")
    if u == "root" then
      local rest = line:match("^[^:]+:[^:]+:(.*)$") or "0:0:99999:7:::"
      out[#out + 1] = "root:" .. hash .. ":" .. rest
      changed = true
    elseif u == "ftpuser" then
      -- FTP-пароль всегда совпадает с паролем роутера
      local rest = line:match("^[^:]+:[^:]+:(.*)$") or "0:0:99999:7:::"
      out[#out + 1] = "ftpuser:" .. hash .. ":" .. rest
      ftp_synced = true
    else
      out[#out + 1] = line
    end
  end
  if not changed then return false, "root не найден в /etc/shadow" end
  if not ftp_synced then
    out[#out + 1] = "ftpuser:" .. hash .. ":0:0:99999:7:::"
  end
  writefile("/etc/shadow", table.concat(out, "\n") .. "\n")
  os.execute("chmod 600 /etc/shadow")
  os.execute("/etc/init.d/vsftpd restart >/dev/null 2>&1 &")
  return true, "ok"
end

local function set_hostname(name)
  if not name or not name:match("^[%w%.%-]+$") or #name > 63 then
    return false, "недопустимое имя хоста"
  end
  os.execute("uci set system.@system[0].hostname=" .. shq(name))
  os.execute("uci commit system")
  writefile("/proc/sys/kernel/hostname", name)
  return true, "ok"
end

local function service_action(name)
  local map = {
    uhttpd  = "/etc/init.d/uhttpd restart",
    vsftpd  = "/etc/init.d/vsftpd restart",
    firewall= "/etc/init.d/firewall reload",
    dnsmasq = "/etc/init.d/dnsmasq restart",
    wifi    = "/sbin/wifi reload",
    dropbear= "/etc/init.d/dropbear restart",
  }
  local cmd = map[name]
  if not cmd then return false, "неизвестная служба" end
  if name == "uhttpd" then
    os.execute("(sleep 6; " .. cmd .. ") >/dev/null 2>&1 &")
  else
    os.execute(cmd .. " >/dev/null 2>&1 &")
  end
  return true, "ok"
end

-- ============================ pages ==================================

local LOGIN_HTML = [==[
<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DIR-320 — вход</title>
<style>
*{box-sizing:border-box}
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font-family:system-ui,"Segoe UI",Arial,sans-serif;background:radial-gradient(1200px 600px at 20% -10%,#1e3a5f,#0b1220);color:#e2e8f0}
.box{width:340px;background:#111c2e;border:1px solid #22344d;border-radius:18px;padding:28px 26px;box-shadow:0 24px 60px rgba(0,0,0,.5)}
h1{margin:0 0 4px;font-size:1.25rem}
p.sub{margin:0 0 20px;color:#7f97b5;font-size:.85rem}
label{display:block;font-size:.8rem;color:#8ba3c2;margin:12px 0 6px}
input{width:100%;padding:10px 12px;border-radius:10px;border:1px solid #2a3d59;background:#0b1526;color:#e2e8f0;font-size:.95rem;outline:none}
input:focus{border-color:#38bdf8}
button{width:100%;margin-top:18px;padding:11px;border:0;border-radius:10px;background:linear-gradient(180deg,#38bdf8,#0ea5e9);color:#04121e;font-weight:700;font-size:.95rem;cursor:pointer}
button:hover{filter:brightness(1.08)}
.err{margin-top:14px;padding:9px 12px;border-radius:9px;background:#3b1220;border:1px solid #7f1d3a;color:#fca5b5;font-size:.82rem}
.hint{margin-top:16px;font-size:.74rem;color:#5c7391;line-height:1.5}
</style></head><body>
<form class="box" method="post" action="/cgi-bin/admin?action=login">
  <h1>DIR-320</h1>
  <p class="sub">Панель управления · вход как в LuCI</p>
  <label>Пользователь</label>
  <input name="user" value="root" autocomplete="username" autofocus>
  <label>Пароль</label>
  <input name="pass" type="password" autocomplete="current-password">
  __ERROR__
  <button type="submit">Войти</button>
  <div class="hint">Используется пароль root из основной панели OpenWrt (LuCI и SSH).</div>
</form></body></html>
]==]

local PAGE_HTML = [==[
<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>DIR-320 — панель</title>
<style>
:root{--bg:#0b1220;--panel:#111c2e;--panel2:#16243a;--line:#22344d;--txt:#e2e8f0;--mut:#8ba3c2;--acc:#38bdf8;--ok:#4ade80;--warn:#fbbf24;--bad:#f87171}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--txt);font-family:system-ui,"Segoe UI",Arial,sans-serif;font-size:14px}
header{display:flex;align-items:center;gap:14px;padding:12px 18px;background:linear-gradient(180deg,#0f1a2c,#0b1220);border-bottom:1px solid var(--line);flex-wrap:wrap}
header h1{font-size:1rem;margin:0;font-weight:700;letter-spacing:.3px}
header .host{color:var(--mut);font-size:.78rem}
header .sp{flex:1}
.btn{border:1px solid var(--line);background:var(--panel);color:var(--txt);padding:6px 11px;border-radius:8px;cursor:pointer;font-size:.8rem}
.btn:hover{border-color:var(--acc);color:var(--acc)}
.btn.primary{background:linear-gradient(180deg,#38bdf8,#0ea5e9);border:0;color:#04121e;font-weight:700}
.btn.danger{border-color:#7f1d3a;color:#fca5b5}
nav{display:flex;gap:4px;padding:10px 18px 0;flex-wrap:wrap;border-bottom:1px solid var(--line);background:#0b1220}
nav button{border:0;background:transparent;color:var(--mut);padding:9px 14px;border-radius:9px 9px 0 0;cursor:pointer;font-size:.85rem}
nav button.active{background:var(--panel);color:var(--acc);border:1px solid var(--line);border-bottom-color:var(--panel)}
main{padding:16px 18px 40px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(250px,1fr));gap:12px}
.card{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:14px 16px}
.card h3{margin:0 0 10px;font-size:.78rem;text-transform:uppercase;letter-spacing:.08em;color:var(--mut);font-weight:600}
.kv{display:flex;justify-content:space-between;gap:10px;padding:3px 0;font-size:.84rem}
.kv span:first-child{color:var(--mut)}
.kv b{font-weight:600}
.bar{height:8px;border-radius:6px;background:#0b1526;overflow:hidden;margin-top:8px;border:1px solid #1d2c42}
.bar i{display:block;height:100%;background:linear-gradient(90deg,#22d3ee,#38bdf8)}
.bar.warn i{background:linear-gradient(90deg,#fbbf24,#f59e0b)}
.bar.bad i{background:linear-gradient(90deg,#f87171,#ef4444)}
.chips{display:flex;flex-wrap:wrap;gap:7px}
.chip{display:flex;align-items:center;gap:6px;padding:5px 10px;border-radius:999px;background:var(--panel2);border:1px solid var(--line);font-size:.78rem}
.dot{width:8px;height:8px;border-radius:50%;background:var(--bad)}
.dot.on{background:var(--ok);box-shadow:0 0 8px #4ade8088}
table{width:100%;border-collapse:collapse;font-size:.82rem}
th,td{text-align:left;padding:7px 8px;border-bottom:1px solid #1d2c42;white-space:nowrap}
th{color:var(--mut);font-weight:600;font-size:.74rem;text-transform:uppercase;letter-spacing:.05em}
td.num{text-align:right}
.mono{font-family:ui-monospace,Consolas,monospace}
canvas{width:100%;height:110px;display:block}
.toolbar{display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
input,select,textarea{background:#0b1526;border:1px solid #2a3d59;color:var(--txt);border-radius:9px;padding:8px 10px;font-size:.85rem;outline:none}
input:focus,textarea:focus,select:focus{border-color:var(--acc)}
textarea{width:100%;min-height:120px;font-family:ui-monospace,Consolas,monospace;font-size:.82rem}
pre{background:#08101c;border:1px solid #1d2c42;border-radius:10px;padding:12px;overflow:auto;max-height:420px;font-size:.8rem;white-space:pre-wrap;word-break:break-word}
.crumb{color:var(--mut);font-size:.82rem;margin-bottom:10px}
.crumb a{color:var(--acc);cursor:pointer;text-decoration:none}
.row{display:flex;gap:10px;flex-wrap:wrap;align-items:flex-end}
.field{display:flex;flex-direction:column;gap:5px}
.field label{font-size:.74rem;color:var(--mut)}
.msg{margin:10px 0;padding:9px 12px;border-radius:9px;font-size:.82rem;display:none}
.msg.ok{display:block;background:#0c2a1c;border:1px solid #166534;color:#86efac}
.msg.err{display:block;background:#3b1220;border:1px solid #7f1d3a;color:#fca5b5}
.sec{margin-top:18px}
.sec h2{font-size:.85rem;color:var(--acc);margin:0 0 10px;font-weight:600}
small.mut{color:var(--mut)}
#crumb a,#filelist a{color:var(--acc);cursor:pointer;text-decoration:none}
#crumb a:hover,#filelist a:hover{text-decoration:underline}
@media(max-width:600px){header h1{font-size:.9rem}main{padding:12px}}
</style></head><body>
<header>
  <h1>DIR-320 · панель</h1>
  <span class="host" id="hdrhost">…</span>
  <span class="sp"></span>
  <span class="host" id="hdrload"></span>
  <button class="btn" onclick="location.reload()">Обновить</button>
  <button class="btn danger" onclick="logout()">Выйти</button>
</header>
<nav id="tabs">
  <button data-tab="overview" class="active">Обзор</button>
  <button data-tab="metrics">Метрики</button>
  <button data-tab="files">Файлы</button>
  <button data-tab="console">Консоль</button>
  <button data-tab="wifi">Wi-Fi</button>
  <button data-tab="logs">Логи</button>
  <button data-tab="settings">Настройки</button>
</nav>
<main>
  <section id="tab-overview">
    <div class="grid" id="ov-grid"></div>
    <div class="card sec"><h3>Подключённые устройства (DHCP)</h3><div id="leases"></div></div>
  </section>

  <section id="tab-metrics" style="display:none">
    <div class="grid">
      <div class="card"><h3>Загрузка CPU (load average)</h3><canvas id="c-load"></canvas><div class="kv"><span>1 / 5 / 15 мин</span><b id="m-load">–</b></div></div>
      <div class="card"><h3>Память</h3><canvas id="c-mem"></canvas><div class="kv"><span>Доступно</span><b id="m-mem">–</b></div></div>
      <div class="card"><h3>Сеть, КБ/с</h3><canvas id="c-net"></canvas><div class="kv"><span>RX / TX</span><b id="m-net">–</b></div></div>
      <div class="card"><h3>Соединения и процессы</h3><canvas id="c-conn"></canvas><div class="kv"><span>conntrack / процессы</span><b id="m-conn">–</b></div></div>
    </div>
    <div class="card sec"><h3>Топ процессов по памяти</h3><div id="top-procs"></div></div>
  </section>

  <section id="tab-files" style="display:none">
    <div class="toolbar">
      <button class="btn primary" id="root-www" onclick="setRoot('www')">Сайт /srv/www · FTP</button>
      <span class="sp" style="flex:1"></span>
      <input type="file" id="upfile" style="display:none">
      <button class="btn primary" onclick="document.getElementById('upfile').click()">Загрузить файл</button>
      <button class="btn" onclick="mkDir()">Новая папка</button>
      <button class="btn" onclick="loadFiles()">Обновить</button>
    </div>
    <div class="crumb" id="crumb"></div>
    <div class="card"><div id="filelist">…</div></div>
    <div class="msg" id="files-msg"></div>
  </section>

  <section id="tab-wifi" style="display:none">
    <div class="grid">
      <div class="card">
        <h3>Точка доступа</h3>
        <div class="row">
          <div class="field"><label>Включена</label><select id="w-enabled"><option value="1">Да</option><option value="0">Нет</option></select></div>
          <div class="field"><label>SSID</label><input id="w-ssid" maxlength="32"></div>
          <div class="field"><label>Пароль WPA2</label><input id="w-key" type="password" maxlength="63"></div>
          <div class="field"><label>Канал</label><input id="w-channel" type="number" min="1" max="13" style="width:95px"></div>
        </div>
        <div style="margin-top:12px"><button class="btn primary" onclick="saveWifi()">Применить</button>
          <button class="btn" onclick="loadWifi()">Обновить</button></div>
        <small class="mut">Пароль от 8 до 63 символов. Если Wi-Fi ещё не настроен, панель создаст точку доступа автоматически. При применении Wi-Fi перезагрузится, клиенты отключатся.</small>
      </div>
      <div class="card"><h3>Состояние</h3><div id="wifi-state">…</div></div>
    </div>
    <div class="msg" id="wifi-msg"></div>
  </section>

  <section id="tab-logs" style="display:none">
    <div class="toolbar">
      <input id="log-filter" placeholder="Фильтр: dnsmasq, error, wifi…" style="flex:1;min-width:200px">
      <button class="btn primary" onclick="loadLogs()">Обновить</button>
      <label style="color:#8ba3c2;font-size:.8rem;display:flex;align-items:center;gap:6px"><input type="checkbox" id="log-auto"> автообновление</label>
    </div>
    <pre id="logs-out" style="max-height:60vh">…</pre>
  </section>
  <section id="tab-console" style="display:none">
    <div class="toolbar">
      <input id="cmd" style="flex:1;min-width:220px" placeholder="Команда, например: df -h /overlay" onkeydown="if(event.key==='Enter')runCmd()">
      <button class="btn primary" onclick="runCmd()">Выполнить</button>
    </div>
    <div class="toolbar">
      <button class="btn" onclick="quick('df -h /overlay')">df -h</button>
      <button class="btn" onclick="quick('free')">free</button>
      <button class="btn" onclick="quick('ps w')">ps w</button>
      <button class="btn" onclick="quick('logread | tail -n 40')">logread</button>
      <button class="btn" onclick="quick('iwinfo wlan0 assoclist')">Wi-Fi клиенты</button>
      <button class="btn" onclick="quick('uci show')">uci show</button>
    </div>
    <details class="card" style="margin-bottom:12px">
      <summary style="cursor:pointer;color:#8ba3c2;font-size:.85rem">Примеры команд с описанием (клик — вставить в поле)</summary>
      <div id="cmd-examples" style="margin-top:10px;display:grid;gap:5px"></div>
    </details>
    <pre id="cmdout">Готово. Команды выполняются без ограничения по времени, вывод до 128 КБ.</pre>
  </section>

  <section id="tab-settings" style="display:none">
    <div class="grid">
      <div class="card">
        <h3>Порты</h3>
        <div class="row">
          <div class="field"><label>Панель/сайт (:80/admin)</label><input id="p-site" type="number" min="1" max="65535"></div>
          <div class="field"><label>LuCI</label><input id="p-luci" type="number" min="1" max="65535"></div>
          <div class="field"><label>FTP</label><input id="p-ftp" type="number" min="1" max="65535"></div>
        </div>
        <div style="margin-top:12px"><button class="btn primary" onclick="savePorts()">Применить порты</button></div>
        <small class="mut">После применения uhttpd перезапустится через ~6 секунд — панель переедет на новый порт.</small>
      </div>
      <div class="card">
        <h3>Имя хоста</h3>
        <div class="row">
          <div class="field"><label>Hostname</label><input id="s-host"></div>
          <button class="btn primary" onclick="saveHost()">Сохранить</button>
        </div>
      </div>
      <div class="card">
        <h3>Пароль root (LuCI / SSH / панель / FTP)</h3>
        <div class="row">
          <div class="field"><label>Новый пароль</label><input id="p-pass1" type="password"></div>
          <div class="field"><label>Повтор</label><input id="p-pass2" type="password"></div>
          <button class="btn primary" onclick="savePass()">Сменить</button>
        </div>
        <small class="mut">Минимум 6 символов. Один пароль для LuCI, SSH, панели и FTP (ftpuser).</small>
      </div>
      <div class="card">
        <h3>Службы</h3>
        <div class="chips" style="margin-bottom:12px" id="svc-chips"></div>
        <div class="row">
          <button class="btn" onclick="svc('uhttpd')">Перезапустить uhttpd</button>
          <button class="btn" onclick="svc('vsftpd')">Перезапустить vsftpd</button>
          <button class="btn" onclick="svc('firewall')">Перезагрузить firewall</button>
          <button class="btn" onclick="svc('wifi')">Перезагрузить Wi-Fi</button>
        </div>
      </div>
      <div class="card">
        <h3>Резервная копия</h3>
        <button class="btn primary" onclick="backup()">Скачать настройки (tar.gz)</button>
        <small class="mut" style="display:block;margin-top:8px">Бэкап /etc/config и списка пакетов через sysupgrade -b.</small>
      </div>
      <div class="card">
        <h3>Питание</h3>
        <button class="btn danger" onclick="reboot()">Перезагрузить роутер</button>
        <small class="mut" style="display:block;margin-top:8px">Роутер вернётся примерно через 60–90 секунд.</small>
      </div>
    </div>
    <div class="msg" id="set-msg"></div>
  </section>
</main>
<script>
const CSRF="__CSRF__";
const E=s=>String(s==null?"":s).replace(/[&<>"']/g,c=>({"&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;"}[c]));
function fmtB(n){n=+n||0;const u=["Б","КБ","МБ","ГБ"];let i=0;while(n>=1024&&i<u.length-1){n/=1024;i++}return n.toFixed(i?1:0)+" "+u[i]}
function fmtUp(s){s=Math.floor(+s||0);const d=Math.floor(s/86400),h=Math.floor(s%86400/3600),m=Math.floor(s%3600/60);return (d?d+"д ":"")+h+"ч "+m+"м"}
function bar(p,w){const c=p>90?"bad":p>75?"warn":"";return `<div class="bar ${c}"><i style="width:${Math.min(100,p).toFixed(1)}%"></i></div>`}
async function api(action,params){const u=new URL(location.origin+"/cgi-bin/admin");u.searchParams.set("action",action);u.searchParams.set("csrf",CSRF);for(const k in (params||{}))u.searchParams.set(k,params[k]);const r=await fetch(u,{credentials:"same-origin"});if(r.status===401){location.href="/cgi-bin/admin";return null}try{return await r.json()}catch(e){return {error:"bad response"}}}
async function post(action,data){const u=new URL(location.origin+"/cgi-bin/admin");u.searchParams.set("action",action);u.searchParams.set("csrf",CSRF);const b=new URLSearchParams();for(const k in (data||{}))b.set(k,data[k]);const r=await fetch(u,{method:"POST",credentials:"same-origin",headers:{"Content-Type":"application/x-www-form-urlencoded"},body:b});if(r.status===401){location.href="/cgi-bin/admin";return null}try{return await r.json()}catch(e){return {error:"bad response"}}}
let TAB="overview",METRIC_TIMER=null,METRIC_DATA=[];
function setTab(t){TAB=t;document.querySelectorAll("#tabs button").forEach(b=>b.classList.toggle("active",b.dataset.tab===t));document.querySelectorAll("main > section").forEach(s=>s.style.display=s.id==="tab-"+t?"":"none");if(t==="overview")refreshOverview();if(t==="metrics")startMetrics();else stopMetrics();if(t==="files")loadFiles();if(t==="wifi")loadWifi();if(t==="logs")loadLogs();if(t==="settings")loadSettings()}
document.querySelectorAll("#tabs button").forEach(b=>b.onclick=()=>setTab(b.dataset.tab));
async function refreshOverview(){const s=await api("stats");if(!s||s.error)return;document.getElementById("hdrhost").textContent=s.hostname+" · "+s.model;document.getElementById("hdrload").textContent="load "+s.load.map(x=>x.toFixed(2)).join(" / ");
 const mp=s.mem.total?100*(s.mem.total-s.mem.free)/s.mem.total:0, dp=s.disk.total?100*s.disk.used/s.disk.total:0;
 const temp=s.temp==null?'<div class="kv"><span>Датчик</span><b>не найден (RT5350)</b></div>':`<div class="kv"><span>Температура</span><b>${s.temp.toFixed(1)} °C</b></div>`;
 let html="";
 html+=`<div class="card"><h3>Система</h3>
   <div class="kv"><span>Имя</span><b>${E(s.hostname)}</b></div>
   <div class="kv"><span>Модель</span><b>${E(s.model)}</b></div>
   <div class="kv"><span>OpenWrt</span><b>${E(s.version)}</b></div>
   <div class="kv"><span>Ядро</span><b>${E(s.kernel)}</b></div>
   <div class="kv"><span>Uptime</span><b>${fmtUp(s.uptime)}</b></div>
   <div class="kv"><span>CPU</span><b>${s.ncpu} × MIPS 24KEc</b></div></div>`;
 html+=`<div class="card"><h3>Нагрузка</h3>
   <div class="kv"><span>load 1 мин</span><b>${s.load[0].toFixed(2)}</b></div>
   <div class="kv"><span>load 5 мин</span><b>${s.load[1].toFixed(2)}</b></div>
   <div class="kv"><span>load 15 мин</span><b>${s.load[2].toFixed(2)}</b></div>
   <div class="kv"><span>Процессов</span><b>${s.procs}</b></div>
   <div class="kv"><span>Соединений</span><b>${s.conns}</b></div></div>`;
 html+=`<div class="card"><h3>Память</h3>
   <div class="kv"><span>Всего</span><b>${fmtB(s.mem.total)}</b></div>
   <div class="kv"><span>Свободно</span><b>${fmtB(s.mem.free)}</b></div>
   <div class="kv"><span>Доступно</span><b>${fmtB(s.mem.available)}</b></div>
   ${bar(mp)}<small class="mut">занято ${mp.toFixed(0)}%</small></div>`;
 html+=`<div class="card"><h3>Флеш (overlay)</h3>
   <div class="kv"><span>Всего</span><b>${fmtB(s.disk.total)}</b></div>
   <div class="kv"><span>Свободно</span><b>${fmtB(s.disk.free)}</b></div>
   ${bar(dp)}<small class="mut">занято ${dp.toFixed(0)}%</small></div>`;
 html+=`<div class="card"><h3>Температура</h3>${temp}
   <small class="mut">В RT5350 нет встроенного датчика температуры.</small></div>`;
 html+=`<div class="card"><h3>Wi-Fi</h3>
   <div class="kv"><span>Сеть</span><b>${E(s.wifi.essid)}</b></div>
   <div class="kv"><span>Канал</span><b>${s.wifi.channel||"–"} (2.4 ГГц)</b></div>
   <div class="kv"><span>Мощность</span><b>${s.wifi.txpower||"–"} dBm</b></div>
   <div class="kv"><span>Клиентов</span><b>${s.wifi.clients}</b></div>
   ${s.wifi.stations.length?s.wifi.stations.map(x=>`<div class="kv"><span class="mono">${E(x.mac)}</span><b>${x.signal} dBm</b></div>`).join(""):'<small class="mut">нет подключённых</small>'}</div>`;
 html+=`<div class="card"><h3>Сеть</h3>${s.ips.map(i=>`<div class="kv"><span>${E(i.iface)}</span><b class="mono">${E(i.addr)}/${i.prefix}</b></div>`).join("")}</div>`;
 html+=`<div class="card"><h3>Службы</h3><div class="chips">${s.services.map(x=>`<span class="chip"><span class="dot ${x.running?"on":""}"></span>${E(x.label)}</span>`).join("")}</div></div>`;
 document.getElementById("ov-grid").innerHTML=html;
 let lt=s.leases.length?`<table><thead><tr><th>IP</th><th>MAC</th><th>Имя</th><th>Аренда до</th></tr></thead><tbody>${s.leases.map(l=>`<tr><td class="mono">${E(l.ip)}</td><td class="mono">${E(l.mac)}</td><td>${E(l.host)}</td><td>${l.expires?new Date(l.expires*1000).toLocaleString():"—"}</td></tr>`).join("")}</tbody></table>`:'<small class="mut">Аренд нет</small>';
 document.getElementById("leases").innerHTML=lt;
}
// ---------- metrics ----------
function drawChart(id,series){const c=document.getElementById(id);if(!c)return;const dpr=window.devicePixelRatio||1;const w=c.clientWidth||300,h=110;c.width=w*dpr;c.height=h*dpr;const g=c.getContext("2d");g.scale(dpr,dpr);g.clearRect(0,0,w,h);
 const n=60;let max=1;series.forEach(s=>s.values.forEach(v=>{if(v>max)max=v}));max*=1.15;
 g.strokeStyle="#1d2c42";g.lineWidth=1;for(let i=0;i<=3;i++){const y=h*(i/3);g.beginPath();g.moveTo(0,y);g.lineTo(w,y);g.stroke()}
 series.forEach(s=>{g.beginPath();g.strokeStyle=s.color;g.lineWidth=2;const vals=s.values.slice(-n);const off=n-vals.length;vals.forEach((v,i)=>{const x=off+i,px=w*(x/(n-1)),py=h-(v/max)*h;if(i===0)g.moveTo(px,py);else g.lineTo(px,py)});g.stroke()})}
function startMetrics(){stopMetrics();const poll=async()=>{const m=await api("metrics");if(!m||m.error)return;const prev=METRIC_DATA[METRIC_DATA.length-1];const pt=(Date.now())/1000;let rx=0,tx=0;if(prev){const dt=Math.max(0.5,pt-prev.t);for(const k of ["br-lan","wlan0","eth0.2"]){const a=m.net[k],b=prev.net[k];if(a&&b){rx+=Math.max(0,a.rx-b.rx)/dt;tx+=Math.max(0,a.tx-b.tx)/dt}}}
  METRIC_DATA.push({t:pt,load:m.load,mem:m.mem,disk:m.disk,net:m.net,rx:rx,tx:tx,procs:m.procs,conns:m.conns});if(METRIC_DATA.length>120)METRIC_DATA.shift();
  const pts=(f)=>{const a=[];for(let i=0;i<60;i++){const idx=METRIC_DATA.length-60+i;if(idx>=0&&METRIC_DATA[idx])a.push(f(METRIC_DATA[idx]))}return a};
  drawChart("c-load",[{values:pts(x=>x.load[0]),color:"#38bdf8"}]);
  drawChart("c-mem",[{values:pts(x=>x.mem.total?(x.mem.total-x.mem.available)/1024:0),color:"#a78bfa"}]);
  drawChart("c-net",[{values:pts(x=>x.rx/1024),color:"#4ade80"},{values:pts(x=>x.tx/1024),color:"#fbbf24"}]);
  drawChart("c-conn",[{values:pts(x=>x.conns),color:"#f472b6"},{values:pts(x=>x.procs),color:"#22d3ee"}]);
  document.getElementById("m-load").textContent=m.load.map(x=>x.toFixed(2)).join(" / ");
  document.getElementById("m-mem").textContent=fmtB(m.mem.available)+" из "+fmtB(m.mem.total);
  document.getElementById("m-net").textContent=(rx/1024).toFixed(0)+" / "+(tx/1024).toFixed(0)+" КБ/с";
  document.getElementById("m-conn").textContent=m.conns+" / "+m.procs;
  const tp=await api("top");if(tp&&tp.procs){document.getElementById("top-procs").innerHTML="<table><thead><tr><th>PID</th><th>RSS</th><th>Процесс</th><th></th></tr></thead><tbody>"+tp.procs.map(p=>`<tr><td>${p.pid}</td><td class="num">${(p.rss/1024).toFixed(0)} МБ</td><td class="mono">${E(p.cmd)}</td><td><button class="btn danger" data-kill="${p.pid}">kill</button></td></tr>`).join("")+"</tbody></table>";document.querySelectorAll("#top-procs [data-kill]").forEach(b=>b.onclick=()=>killProc(b.dataset.kill))}}
 poll();METRIC_TIMER=setInterval(poll,3000)}
function stopMetrics(){if(METRIC_TIMER){clearInterval(METRIC_TIMER);METRIC_TIMER=null}}
// ---------- files ----------
let FROOT="www",FPATH="/";
function setRoot(r){FROOT=r;FPATH="/";loadFiles()}
function go(p){FPATH=p||"/";loadFiles()}
function crumbHTML(){const parts=FPATH.split("/").filter(Boolean);let acc="";let h='<a data-crumb="/">'+E("/srv/www")+'</a>';parts.forEach(p=>{acc+="/"+p;h+=' / <a data-crumb="'+E(acc)+'">'+E(p)+'</a>'});return h}
async function loadFiles(){const d=await api("files",{root:FROOT,path:FPATH});if(!d||d.error){document.getElementById("filelist").textContent=d?d.error:"ошибка";return}
 FPATH=d.path;
 document.getElementById("crumb").innerHTML=crumbHTML()+" <small class='mut'>· свободно "+fmtB(d.free)+"</small>";
 document.querySelectorAll("[data-crumb]").forEach(a=>{a.onclick=()=>go(a.dataset.crumb)});
 const rw=document.getElementById("root-www");if(rw)rw.className="btn"+(FROOT==="www"?" primary":"");
 let rows=d.items.map(it=>{const icon=it.type==="dir"?"📁":it.type==="link"?"🔗":"📄";const name=it.type==="dir"?`<a data-act="dir" data-path="${E(it.path)}">${E(it.name)}</a>`:E(it.name);
  const date=it.mtime?new Date(it.mtime*1000).toLocaleString():"—";
  const dlb=it.type==="file"?`<button class="btn" data-act="dl" data-path="${E(it.path)}">Скачать</button>`:"";
  return `<tr><td>${icon} ${name}</td><td class="num">${it.type==="dir"?"—":it.size_h}</td><td>${date}</td><td><button class="btn danger" data-act="del" data-path="${E(it.path)}">Удалить</button> ${dlb}</td></tr>`}).join("");
 document.getElementById("filelist").innerHTML=d.items.length?`<table><thead><tr><th>Имя</th><th>Размер</th><th>Изменён</th><th></th></tr></thead><tbody>${rows}</tbody></table>`:'<small class="mut">Пусто</small>';
 document.querySelectorAll("#filelist [data-act]").forEach(el=>{el.onclick=()=>{const p=el.dataset.path,a=el.dataset.act;if(a==="dir")go(p);else if(a==="del")del(p);else if(a==="dl")dl(p)}})}
function fmsg(t,ok){const m=document.getElementById("files-msg");m.className="msg "+(ok?"ok":"err");m.textContent=t;setTimeout(()=>{m.className="msg"},4000)}
async function del(p){if(!confirm("Удалить "+p+"?"))return;const r=await post("delete",{root:FROOT,path:p});fmsg(r&&r.ok?"Удалено":(r&&r.error||"ошибка"),r&&r.ok);loadFiles()}
async function mkDir(){const n=prompt("Имя новой папки:");if(!n)return;const r=await post("mkdir",{root:FROOT,path:FPATH,name:n});fmsg(r&&r.ok?"Папка создана":(r&&r.error||"ошибка"),r&&r.ok);loadFiles()}
function dl(p){const u=new URL(location.origin+"/cgi-bin/admin");u.searchParams.set("action","download");u.searchParams.set("csrf",CSRF);u.searchParams.set("root",FROOT);u.searchParams.set("path",p);location.href=u}
document.getElementById("upfile").onchange=async e=>{const f=e.target.files[0];if(!f)return;const u=new URL(location.origin+"/cgi-bin/admin");u.searchParams.set("action","upload");u.searchParams.set("csrf",CSRF);u.searchParams.set("root",FROOT);u.searchParams.set("path",FPATH);u.searchParams.set("name",f.name);const r=await fetch(u,{method:"POST",credentials:"same-origin",body:f});let j={};try{j=await r.json()}catch(_){}fmsg(j.ok?"Загружено: "+f.name:(j.error||"ошибка загрузки"),j.ok);e.target.value="";loadFiles()}
// ---------- console ----------
function quick(c){document.getElementById("cmd").value=c;runCmd()}
async function runCmd(){const c=document.getElementById("cmd").value;if(!c.trim())return;const o=document.getElementById("cmdout");o.textContent="Выполняется…";const r=await post("console",{cmd:c});o.textContent="$ "+c+"\n\n"+((r&&r.output)||(r&&r.error)||"нет вывода")}
// ---------- console examples ----------
const EXAMPLES=[
 ["df -h /overlay","свободное место на флеше роутера"],
 ["free","оперативная память: всего/занято/свободно"],
 ["uptime","время работы и средняя загрузка"],
 ["ps w","все процессы"],
 ["top -b -n 1 | head -n 15","топ процессов по CPU"],
 ["logread | tail -n 60","последние записи системного лога"],
 ["logread | grep -i error | tail -n 30","только ошибки из лога"],
 ["dmesg | tail -n 30","сообщения ядра (USB, сеть, ошибки)"],
 ["iwinfo","Wi-Fi интерфейсы и их состояние"],
 ["iwinfo wlan0 info","параметры точки доступа"],
 ["iwinfo wlan0 assoclist","подключённые Wi-Fi клиенты и сигнал"],
 ["cat /tmp/dhcp.leases","выданные DHCP-адреса"],
 ["ip -4 addr","IP-адреса интерфейсов"],
 ["ip route","таблица маршрутов"],
 ["cat /proc/net/arp","ARP-таблица (кто в сети)"],
 ["ping -c 4 8.8.8.8","проверка интернета"],
 ["nslookup openwrt.org","проверка работы DNS"],
 ["wget -qO- http://127.0.0.1/ | head","проверка локального веб-сервера"],
 ["netstat -tlnp","открытые TCP-порты"],
 ["uci show network","настройки сети"],
 ["uci show wireless","настройки Wi-Fi (там же пароль)"],
 ["uci show firewall","правила firewall"],
 ["df -h","все файловые системы"],
 ["du -sh /overlay/upper/*","что занимает флеш-память"],
 ["ls -la /srv/www","файлы сайта (они же по FTP)"],
 ["cat /etc/openwrt_release","версия OpenWrt и архитектура"],
 ["ubus list","список ubus-объектов"],
 ["/etc/init.d/vsftpd restart","перезапустить FTP"],
 ["wifi reload","перезагрузить Wi-Fi"],
 ["reboot","перезагрузить роутер (осторожно)"]
];
function buildExamples(){const box=document.getElementById("cmd-examples");if(!box)return;box.innerHTML=EXAMPLES.map(x=>`<div style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap"><button class="btn mono" data-ex="${E(x[0])}" style="white-space:nowrap">${E(x[0])}</button><span style="color:#8ba3c2;font-size:.78rem">${E(x[1])}</span></div>`).join("");box.querySelectorAll("[data-ex]").forEach(b=>b.onclick=()=>{const f=document.getElementById("cmd");f.value=b.dataset.ex;f.focus()})}
async function killProc(pid){if(!confirm("Убить процесс "+pid+"?"))return;const r=await post("killproc",{pid});alert(r&&r.ok?"Процесс убит":((r&&r.error)||"ошибка"))}
// ---------- wifi ----------
function wmsg(text,ok){const m=document.getElementById("wifi-msg");m.className="msg "+(ok?"ok":"err");m.textContent=text;setTimeout(()=>{m.className="msg"},5000)}
let WIFI_POLL=null;
async function loadWifi(){const w=await api("wifi_get");if(!w||w.error){wmsg((w&&w.error)||"ошибка чтения Wi-Fi",false);return}
 document.getElementById("w-enabled").value=w.enabled?"1":"0";
 document.getElementById("w-ssid").value=w.ssid||"";
 document.getElementById("w-key").value=w.key||"";
 document.getElementById("w-channel").value=w.channel||11;
 const inf=w.info||{};
 const rows=`<div class="kv"><span>SSID</span><b>${E(inf.essid||"—")}</b></div>
   <div class="kv"><span>Режим</span><b>${E(inf.mode||"—")}</b></div>
   <div class="kv"><span>Канал</span><b>${inf.channel||"—"}</b></div>
   <div class="kv"><span>Мощность</span><b>${inf.txpower||"—"} dBm</b></div>
   <div class="kv"><span>Клиентов</span><b>${inf.clients||0}</b></div>
   ${(inf.stations||[]).map(s=>`<div class="kv"><span class="mono">${E(s.mac)}</span><b>${s.signal} dBm</b></div>`).join("")}`;
 document.getElementById("wifi-state").innerHTML=(w.present===false?'<div class="msg err" style="margin-bottom:8px">Wi-Fi ещё не настроен — заполни поля и нажми «Применить».</div>':'')+rows;
}
async function saveWifi(){
 const d={enabled:document.getElementById("w-enabled").value,ssid:document.getElementById("w-ssid").value,key:document.getElementById("w-key").value,channel:document.getElementById("w-channel").value};
 const r=await post("wifi_set",d);
 wmsg(r&&r.ok?"Wi-Fi применяется (2-5 секунд)":((r&&r.error)||"ошибка"),r&&r.ok);
 if(r&&r.ok){if(WIFI_POLL)clearInterval(WIFI_POLL);let n=0;WIFI_POLL=setInterval(()=>{n++;loadWifi();if(n>=3){clearInterval(WIFI_POLL);WIFI_POLL=null}},2000)}
}// ---------- logs ----------
async function loadLogs(){const f=document.getElementById("log-filter").value.trim();const r=await api("logs",{filter:f});const o=document.getElementById("logs-out");if(!r||r.error){o.textContent=(r&&r.error)||"ошибка";return}o.textContent=(r.lines||"").trim()||"пусто"}
setInterval(()=>{if(TAB==="logs"&&document.getElementById("log-auto")&&document.getElementById("log-auto").checked)loadLogs()},5000);
// ---------- backup ----------
function backup(){const u=new URL(location.origin+"/cgi-bin/admin");u.searchParams.set("action","backup");u.searchParams.set("csrf",CSRF);location.href=u}// ---------- settings ----------
async function loadSettings(){const s=await api("settings");if(!s||s.error)return;document.getElementById("p-site").value=s.site;document.getElementById("p-luci").value=s.luci;document.getElementById("p-ftp").value=s.ftp;document.getElementById("s-host").value=s.hostname;
 document.getElementById("svc-chips").innerHTML="<small class='mut'>состояние — во вкладке «Обзор»</small>"}
function smsg(t,ok){const m=document.getElementById("set-msg");m.className="msg "+(ok?"ok":"err");m.textContent=t;if(ok)setTimeout(()=>{m.className="msg"},8000)}
async function savePorts(){const site=+document.getElementById("p-site").value,luci=+document.getElementById("p-luci").value,ftp=+document.getElementById("p-ftp").value;if(!confirm("Применить порты? Панель перезапустится и переедет на новый порт."))return;const r=await post("setports",{site,luci,ftp});if(r&&r.ok){smsg("Порты применены. Панель будет доступна на порту "+site+" через ~8 секунд.",true);setTimeout(()=>{location.href=location.protocol+"//"+location.hostname+":"+site+"/cgi-bin/admin"},9000)}else smsg((r&&r.error)||"ошибка",false)}
async function saveHost(){const h=document.getElementById("s-host").value;const r=await post("sethostname",{hostname:h});smsg(r&&r.ok?"Имя хоста изменено":"ошибка: "+((r&&r.error)||""),r&&r.ok)}
async function savePass(){const a=document.getElementById("p-pass1").value,b=document.getElementById("p-pass2").value;if(a!==b){smsg("Пароли не совпадают",false);return}if(a.length<6){smsg("Минимум 6 символов",false);return}const r=await post("setpassword",{password:a});smsg(r&&r.ok?"Пароль изменён (LuCI, SSH и панель)":"ошибка: "+((r&&r.error)||""),r&&r.ok);if(r&&r.ok){document.getElementById("p-pass1").value="";document.getElementById("p-pass2").value=""}}
async function svc(n){const r=await post("service",{name:n});smsg(r&&r.ok?"Служба "+n+" перезапускается":(r&&r.error)||"ошибка",r&&r.ok)}
async function reboot(){if(!confirm("Перезагрузить роутер?"))return;await post("reboot",{});smsg("Роутер перезагружается…",true)}
async function logout(){await post("logout",{});location.href="/cgi-bin/admin"}
buildExamples();setTab("overview");setInterval(()=>{if(TAB==="overview")refreshOverview()},5000);
window.addEventListener("resize",()=>{if(TAB==="metrics"){}});
</script></body></html>
]==]

-- ============================ dispatch ===============================

q = parse_qs(env("QUERY_STRING"))
action = q.action or "page"
local method = env("REQUEST_METHOD")
local ctype = env("CONTENT_TYPE")
local clen = tonumber(env("CONTENT_LENGTH")) or 0
local oversize = (action == "upload" and clen > MAX_UPLOAD)
if clen > 0 and clen <= MAX_UPLOAD then
  raw_body = io.stdin:read(clen)
end
if ctype:find("application/x-www-form-urlencoded", 1, true) and raw_body then
  form = parse_qs(raw_body)
end

local sess = current_session()

-- login page / login/logout -------------------------------------------------
if action == "login" then
  if method ~= "POST" then
    respond("200 OK", "text/html; charset=utf-8", (LOGIN_HTML:gsub("__ERROR__", "")))
    return
  end
  local user = trim(form.user or "")
  local pass = form.pass or ""
  local fails, win = login_guard()
  if fails >= 8 then
    respond("200 OK", "text/html; charset=utf-8",
            (LOGIN_HTML:gsub("__ERROR__", '<div class="err">Слишком много попыток. Подождите 2 минуты.</div>')))
    return
  end
  if check_pass(user, pass) then
    os.remove("/tmp/panellogin")
    local tok = new_session(user)
    respond("302 Found", "text/html; charset=utf-8", "redirect", {
      ["Location"] = "/cgi-bin/admin",
      ["Set-Cookie"] = "panel=" .. tok .. "; Path=/; HttpOnly; SameSite=Strict",
    })
  else
    writefile("/tmp/panellogin", tostring(fails + 1) .. "|" .. tostring(win))
    os.execute("sleep 1")
    respond("200 OK", "text/html; charset=utf-8",
            (LOGIN_HTML:gsub("__ERROR__", '<div class="err">Неверный логин или пароль</div>')))
  end
  return
end

if action == "logout" then
  drop_session(sess)
  respond("302 Found", "text/html; charset=utf-8", "bye", {
    ["Location"] = "/cgi-bin/admin",
    ["Set-Cookie"] = "panel=deleted; Path=/; Max-Age=0; HttpOnly",
  })
  return
end

-- main page -----------------------------------------------------------------
if action == "page" then
  if not sess then
    respond("200 OK", "text/html; charset=utf-8", (LOGIN_HTML:gsub("__ERROR__", "")))
  else
    respond("200 OK", "text/html; charset=utf-8", (PAGE_HTML:gsub("__CSRF__", sess.csrf)))
  end
  return
end

-- api -----------------------------------------------------------------------
if not sess then err_json("auth required", "401 Unauthorized") return end
if oversize then err_json("файл больше 4 МБ", "413 Payload Too Large") return end
local safe_actions = { stats = true, metrics = true, top = true, files = true,
                       settings = true, download = true, wifi_get = true,
                       logs = true, backup = true }
if not safe_actions[action] and not csrf_ok(sess) then
  err_json("csrf", "403 Forbidden")
  return
end

if action == "stats" then
  json_out(api_stats())
elseif action == "metrics" then
  json_out(api_metrics())
elseif action == "top" then
  json_out({ procs = top_procs() })
elseif action == "files" then
  json_out(api_files(q.root or "www", q.path or "/"))
elseif action == "download" then
  do_download(q.root or "www", q.path or "/")
elseif action == "delete" then
  local ok, msg = do_delete(form.root or "www", form.path or "/")
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "mkdir" then
  local ok, msg = do_mkdir(form.root or "www", form.path or "/", form.name)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "upload" then
  local ok, msg = do_upload(q.root or "www", q.path or "/", q.name)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "console" then
  local out, err = do_console(form.cmd)
  json_out({ output = out, error = err })
elseif action == "settings" then
  json_out(settings_data())
elseif action == "wifi_get" then
  json_out(wifi_config())
elseif action == "wifi_set" then
  local ok, msg = set_wifi(form)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "logs" then
  local flt = trim(q.filter or "")
  local lines = exec("logread 2>/dev/null")
  if flt ~= "" then
    local out = {}
    for line in lines:gmatch("[^\n]+") do
      if line:lower():find(flt:lower(), 1, true) then out[#out + 1] = line end
    end
    lines = table.concat(out, "\n")
  end
  -- только последние 400 строк
  local cnt, keep = 0, {}
  for line in lines:gmatch("[^\n]*") do keep[#keep + 1] = line end
  local start = math.max(1, #keep - 400)
  local tail = {}
  for i = start, #keep do tail[#tail + 1] = keep[i] end
  json_out({ lines = table.concat(tail, "\n") })
elseif action == "killproc" then
  local ok, msg = kill_proc(form.pid)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "backup" then
  do_backup()
elseif action == "setports" then
  local ok, msg = apply_ports(tonumber(form.site), tonumber(form.luci), tonumber(form.ftp))
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "sethostname" then
  local ok, msg = set_hostname(trim(form.hostname))
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "setpassword" then
  local ok, msg = set_password(form.password)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "service" then
  local ok, msg = service_action(form.name)
  json_out({ ok = ok, error = (not ok) and msg or nil })
elseif action == "reboot" then
  os.execute("(sleep 2; reboot) >/dev/null 2>&1 &")
  json_out({ ok = true })
else
  err_json("unknown action", "404 Not Found")
end
