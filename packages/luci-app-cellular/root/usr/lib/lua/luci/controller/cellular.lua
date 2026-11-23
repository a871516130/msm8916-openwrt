module("luci.controller.cellular", package.seeall)

require "luci.dispatcher"
require "luci.http"
require "luci.template"
require "luci.sys"
require "luci.util"
require "luci.model.uci"

local i18n = require "luci.i18n"

function index()
	-- 独立节点路径（不与 luci-proto-modemmanager 的菜单/控制器冲突）
	-- 标题由 _() 提供，经 po/zh_Hans 译为"蜂窝网络"
	entry({"admin", "status", "cellular"}, call("action_status"),
	      _("Cellular Network"), 10)
end

local DEVICE = "any"
local SIM_TOOL = "/usr/sbin/sim-select"
local IMEI_TOOL = "/usr/sbin/imei-tool"
local FORCE_CARRIER = "/etc/qcom-carrier-autocfg/force-carrier"

local function tr(s)
	if not s or s == "" or s == "--" or s == "-" then return s end
	return i18n.translate(s)
end

local function run(cmd)
	local f = io.popen(cmd, "r")
	if not f then return nil end
	local d = f:read("*a")
	f:close()
	return d
end

-- keyval 行: "modem.3gpp.imei            : 8684..."
local function kvparse(out)
	local t = {}
	if not out then return t end
	for line in out:gmatch("[^\n]+") do
		local k, v = line:match("^(%S+)%s*:%s*(.*)$")
		if k then t[k] = v end
	end
	return t
end

-- QMI 端口与 ModemManager 有 CID 争用(endpoint hangup), 需要多次重试。
-- QMI_FAILED: 一旦某次探测失败（端口阻塞/争用），后续探测直接跳过
-- （用缓存/-- 兜底），避免页面因多个 qmicli 调用串行超时而假死。
local qmi_failed = false
local function qmicli_retry(cmd, tries)
	if qmi_failed then return nil end
	tries = tries or 2
	for _ = 1, tries do
		local out = run(cmd)
		if out and out:find("Successfully") then
			return out
		end
	end
	qmi_failed = true
	return nil
end

local FIELDS = {
	{ "modem.3gpp.imei",                              "imei" },
	{ "modem.3gpp.operator-name",                     "operator" },
	{ "modem.3gpp.operator-code",                     "opcode" },
	{ "modem.3gpp.registration-state",                "reg" },
	{ "modem.3gpp.packet-service-state",              "ps" },
	{ "modem.3gpp.network-rejection-error",           "reject" },
	{ "modem.3gpp.network-rejection-operator-id",     "reject_opid" },
	{ "modem.3gpp.network-rejection-operator-name",   "reject_opname" },
	{ "modem.3gpp.network-rejection-access-technology", "reject_rat" },
	{ "modem.3gpp.eps.initial-bearer.settings.apn",    "apn" },
	{ "modem.3gpp.eps.ue-mode-operation",             "ue_mode" },
	{ "modem.3gpp.5gnr.registration-settings.mico-mode", "mico" },
	{ "modem.3gpp.5gnr.registration-settings.drx-cycle", "drx" },
	{ "modem.generic.state",                           "state" },
	{ "modem.generic.state-failed-reason",            "state_reason" },
	{ "modem.generic.power-state",                    "power" },
	{ "modem.generic.signal-quality.value",           "signal" },
	{ "modem.generic.signal-quality.recent",          "signal_recent" },
	{ "modem.generic.current-bands",                  "current_bands" },
	{ "modem.generic.supported-bands",                "supported_bands" },
	{ "modem.generic.access-technologies",            "accesstech" },
	{ "modem.generic.manufacturer",                   "mfr" },
	{ "modem.generic.model",                          "model" },
	{ "modem.generic.revision",                       "rev" },
	{ "modem.generic.device-identifier",              "did" },
	{ "modem.generic.carrier-configuration",          "carrier_cfg" },
	{ "modem.generic.own-numbers",                    "own_numbers" },
	{ "modem.dbus-path",                               "dbus" },
}

	local function collect_sim()
	local d = {}
	local cur = run(SIM_TOOL .. " 2>/dev/null")
	d.select = (cur and cur:gsub("%s+$", "")) or "sim"

	-- ICCID / IMSI：用 mmcli 读主 SIM，放在最前（UIM qmicli 之前），
	-- 并带重试：QMI 命令的 endpoint hangup 会让 modem 短暂重枚举、丢失 SIM 路径，
	-- 主 SIM 路径索引也随重枚举变化，故每次重新获取。
	local function get_sim_ident()
		for _ = 1, 10 do
			local mpath = run("timeout 6 mmcli -m any 2>/dev/null")
			local simidx = mpath and mpath:match("SIM%/(%d+)")
			if simidx then
				local so = run("timeout 6 mmcli -m any --sim " .. simidx .. " -K 2>/dev/null")
				if so then
					local id = so:match("sim%.properties%.iccid%s*:%s*(%S+)")
					local imsi = so:match("sim%.properties%.imsi%s*:%s*(%S+)")
					if id or imsi then return id, imsi end
				end
			end
			run("sleep 1 2>/dev/null")
		end
		return nil, nil
	end
	local iccid, imsi = get_sim_ident()
	if iccid then d.iccid = iccid end
	if imsi then d.imsi = imsi end

	-- 卡槽信息：逐行解析，跟踪当前 Slot，读取 Card state / UPIN state
	local slots = {}
	local cs = qmicli_retry(
		"timeout 2 qmicli -d /dev/wwan0qmi0 --uim-get-card-status 2>/dev/null")
	if cs then
		local cur_slot
		for line in cs:gmatch("[^\n]+") do
			local sn = line:match("Slot %[([0-9]+)%]:")
			if sn then
				cur_slot = sn
				slots[#slots + 1] = { num = sn }
			elseif cur_slot then
				local st = line:match("Card state: '([^']*)'")
				if st then
					for _, s in ipairs(slots) do
						if s.num == cur_slot then s.state = st end
					end
				end
				local up = line:match("UPIN state: '([^']*)'")
				if up then
					for _, s in ipairs(slots) do
						if s.num == cur_slot then s.upin = up end
					end
				end
			end
		end
	end
	d.slots = slots

	return d
end

local function collect_signal(has_sim)
	local d = {}

	-- 服务/邻区信令：--nas-get-cell-location-info
	-- 无 SIM 无法注册/驻留，基站/信令读取没意义（qmicli CID 争用，白费）
	local cl
	if has_sim then
		cl = qmicli_retry(
			"timeout 2 qmicli -d /dev/wwan0qmi0 --nas-get-cell-location-info 2>/dev/null")
	end
	if cl then
		d.plmn = cl:match("PLMN:%s+'([^']*)'")
		d.tac = cl:match("Tracking Area Code:%s+'([^']*)'")
		d.gci = cl:match("Global Cell ID:%s+'([^']*)'")
		local earfcn = cl:match("EUTRA Absolute RF Channel Number:%s+'([^']*)'")
		if earfcn then d.earfcn = earfcn end
		d.earfcn_band = cl:match("E%-UTRA band ([0-9]+)")
		d.serving_cell = cl:match("Serving Cell ID:%s+'([^']*)'")

		-- 邻区/服务小区信号
		local cells = {}
		local cur
		for line in cl:gmatch("[^\n]+") do
			local cn = line:match("Cell %[([0-9]+)%]:")
			if cn then
				cur = { idx = cn }
				cells[#cells + 1] = cur
			elseif cur then
				local v
				v = line:match("Physical Cell ID:%s+'([^']*)'")
				if v then cur.pci = v end
				v = line:match("RSRP:%s+'([^']*)'")
				if v then cur.rsrp = v end
				v = line:match("RSRQ:%s+'([^']*)'")
				if v then cur.rsrq = v end
				v = line:match("RSSI:%s+'([^']*)'")
				if v then cur.rssi = v end
				v = line:match("EARSFCN:%s+'([^']*)'")
				if v then cur.earfcn = v end
				v = line:match("EARFCN:%s+'([^']*)'")
				if v then cur.earfcn = v end
				-- 退出当前 Cell 块：遇到下一个顶层字段
				if line:match("^%s+[A-Z][A-Za-z ]+:%s") and not line:match("Cell %[") then
					cur = nil
				end
			end
		end
		d.cells = cells
	end

	-- 信号强度：--nas-get-signal-info
	local si
	if has_sim then
		si = qmicli_retry(
			"timeout 2 qmicli -d /dev/wwan0qmi0 --nas-get-signal-info 2>/dev/null")
	end
	if si then
		d.sig_rssi = si:match("RSSI:%s+'([^']*)'")
		d.sig_rsrq = si:match("RSRQ:%s+'([^']*)'")
		d.sig_rsrp = si:match("RSRP:%s+'([^']*)'")
		d.sig_snr = si:match("SNR:%s+'([^']*)'")
	end

	-- 支持频段：优先 MM（已在 FIELDS 的 supported_bands），QMI 作 fallback
	-- 无 SIM 也跳过（0 次 qmicli；supported bands 仍由 MM 的
	-- modem.generic.supported-bands 提供，qmi_bands 只是 fallback）
	local bc
	if has_sim then
		bc = qmicli_retry(
			"timeout 2 qmicli -d /dev/wwan0qmi0 --dms-get-band-capabilities 2>/dev/null")
	end
	if bc then
		local bands = {}
		for b in bc:gmatch("Band class:%s+'([^']*)'") do
			bands[#bands + 1] = b
		end
		if #bands > 0 then d.qmi_bands = table.concat(bands, ", ") end
	end

	return d
end

-- 简易序列化/缓存：MM 瞬时未返回时用上次成功状态，避免整页报错
local CACHE = "/tmp/cell_status.lua"

local function ser(v)
	local t = type(v)
	if t == "string" then
		return ("%q"):format(v)
	elseif t == "number" or t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local parts = {}
		for k, val in pairs(v) do
			if type(k) == "number" and k >= 1 and k == math.floor(k) then
				parts[#parts + 1] = "[" .. k .. "]=" .. ser(val)
			else
				parts[#parts + 1] = "[" .. ("%q"):format(tostring(k)) .. "]=" .. ser(val)
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "nil"
end

local function fmt_age(sec)
	sec = math.max(0, sec or 0)
	if sec < 60 then return sec .. " 秒前"
	elseif sec < 3600 then return math.floor(sec / 60) .. " 分钟前"
	elseif sec < 86400 then return math.floor(sec / 3600) .. " 小时前"
	else return math.floor(sec / 86400) .. " 天前" end
end

local function write_cache(d)
	d._ts = os.time()
	local f = io.open(CACHE, "w")
	if not f then return end
	f:write("return " .. ser(d))
	f:close()
end

local function read_cache()
	local f = io.open(CACHE, "r")
	if not f then return nil end
	local s = f:read("*a")
	f:close()
	if not s or s == "" then return nil end
	-- Lua 5.1 用 loadstring，5.2+ 用 load(string)
	local chunk
	if loadstring then
		chunk = loadstring(s)
	else
		chunk = load(s)
	end
	if not chunk then return nil end
	local ok, res = pcall(chunk)
	if ok and type(res) == "table" then return res end
	return nil
end

local function collect(has_sim)
	local d = {}
	-- 跟随 modem 重枚举：MM 瞬时无数据（索引变动/重枚举）时短重试，
	-- 期间 modem 重新出现则用新鲜数据（页面跟随 modem，不显示缓存警告）；
	-- 仍空才回退缓存 + 提示。
	local out = ""
	for _ = 1, 3 do
		out = run(string.format("timeout 4 mmcli --modem=%s -K 2>/dev/null", DEVICE)) or ""
		if out ~= "" then break end
		os.execute("sleep 2")
	end
	if not out or out == "" then
		-- MM 仍未返回（modem 长时间不可用）：用缓存 + 提示，不整页报错
		local cached = read_cache()
		if cached then
			local age = cached._ts and (os.time() - cached._ts) or nil
			cached.warning = "ModemManager 瞬时未返回数据，以下为上次缓存状态"
			if age ~= nil then
				cached.warning = cached.warning .. "（" .. fmt_age(age) .. "）"
			end
			return cached
		end
		d.error = "ModemManager 未返回数据（modem 不可用或 MM 未运行）"
		return d
	end

	local kv = kvparse(out)
	for _, p in ipairs(FIELDS) do
		d[p[2]] = kv[p[1]] or "--"
	end

	-- MM 的频段字段是数组形式（modem.generic.X-bands.value[N]），需聚合
	-- 注意：Lua 模式中 '-' 是量词，故用 '.-' 抓前缀后做字符串相等比较
	local function band_array(prefix)
		local vals = {}
		for k, v in pairs(kv) do
			local base, idx = k:match("^(.-)%.value%[([0-9]+)%]$")
			if base == prefix and idx then
				vals[#vals + 1] = { tonumber(idx), v }
			end
		end
		if #vals > 0 then
			table.sort(vals, function(a, b) return a[1] < b[1] end)
			local parts = {}
			for _, e in ipairs(vals) do parts[#parts + 1] = e[2] end
			return table.concat(parts, ", ")
		end
		return nil
	end
	local cb = band_array("modem.generic.current-bands")
	if cb then d.current_bands = cb end
	local sb = band_array("modem.generic.supported-bands")
	if sb then d.supported_bands = sb end

	-- 注册状态：需 SIM 才能注册
	local q
	if has_sim then
		q = qmicli_retry(
			"timeout 2 qmicli -d /dev/wwan0qmi0 --nas-get-serving-system 2>/dev/null")
	end
	if q then
		local s = q:match("Registration state:%s+'([^']*)'")
		if s then d.serving_reg = s end
		s = q:match("Roaming status:%s+'([^']*)'")
		if s then d.roaming = s end
		s = q:match("Current PLMN:") and q:match("MCC:%s+'([^']*)'")
		if s then d.plmn_mcc = s end
		s = q:match("MNC:%s+'([^']*)'")
		if s then d.plmn_mnc = s end
	end

	-- 频段/信道：需 SIM
	local b
	if has_sim then
		b = qmicli_retry(
			"timeout 2 qmicli -d /dev/wwan0qmi0 --nas-get-rf-band-info 2>/dev/null")
	end
	if b then
		local cls = b:match("Active Band Class:%s+'([^']*)'")
		if cls then d.band = cls end
		local ch = b:match("Active Channel:%s+'([^']*)'")
		if ch then d.channel = ch end
	end

	d.cell = collect_signal(has_sim)

	return d
end

function action_status()
	local act = luci.http.formvalue("act")
	local msg

	if act == "switch" then
		local sel = luci.http.formvalue("select")
		if sel and (sel == "sim" or sel == "esim1" or sel == "esim2") then
			local out = luci.sys.exec("%s %s 2>&1" % { SIM_TOOL, sel })
			msg = luci.util.urlencode("切卡: " .. (out:gsub("%s+$", "")))
		else
			msg = luci.util.urlencode("切卡失败: 无效的卡槽")
		end
		luci.http.redirect(luci.dispatcher.build_url("admin", "status", "cellular") .. "?msg=" .. msg)
		return
	end

	if act == "imei" then
		local imei = luci.http.formvalue("imei")
		if imei and imei:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") then
			local out = luci.sys.exec("%s set %s 2>&1" % { IMEI_TOOL, imei })
			msg = luci.util.urlencode("写入IMEI: " .. (out:gsub("%s+$", "")))
		else
			msg = luci.util.urlencode("写入IMEI失败: IMEI 必须为 15 位数字")
		end
		luci.http.redirect(luci.dispatcher.build_url("admin", "status", "cellular") .. "?msg=" .. msg)
		return
	end

	if act == "setcarrier" then
		local c = luci.http.formvalue("carrier")
		c = c and c:gsub("%s+", "") or ""
		if c == "" then c = "auto" end
		if c == "auto" or c:match("^%d%d%d%d%d$") then
			local f = io.open(FORCE_CARRIER, "w")
			if f then
				f:write(c .. "\n")
				f:close()
			end
			luci.sys.exec("/etc/init.d/qcom-carrier-autocfg restart >/dev/null 2>&1")
			msg = luci.util.urlencode("运营商配置: " .. c .. "（重新provision中）")
		else
			msg = luci.util.urlencode("运营商配置失败: 无效的值")
		end
		luci.http.redirect(luci.dispatcher.build_url("admin", "status", "cellular") .. "?msg=" .. msg)
		return
	end

	-- 先读 SIM：collect() 的 QMI 命令（endpoint hangup）会让 modem 短暂丢失
	-- SIM 路径，故在 QMI 命令之前抓取，配合 get_sim_ident 内的重试更稳。
	local sim = collect_sim()
	local has_sim = sim and (sim.iccid or sim.imsi) and true or false
	local d = collect(has_sim)

	if d.warning then
		-- collect 用了缓存（MM 瞬时未返回）。新鲜 sim 缺的字段从缓存补全。
		local fresh = sim or {}
		local cached_sim = d.sim or {}
		if fresh.select == nil then fresh.select = cached_sim.select end
		if fresh.iccid == nil or fresh.iccid == "" then fresh.iccid = cached_sim.iccid end
		if fresh.imsi == nil or fresh.imsi == "" then fresh.imsi = cached_sim.imsi end
		if (not fresh.slots or #fresh.slots == 0) and cached_sim.slots then
			fresh.slots = cached_sim.slots
		end
		d.sim = fresh
	else
		d.sim = sim
		if not d.error then
			write_cache(d)
		end
	end

	-- 无 SIM/eSIM：已跳过注册/基站读取，页面给出提示
	-- （用合并后的 d.sim，MM 瞬时失效时从缓存补全的 SIM 也算）
	local sim_final = d.sim or {}
	d.nosim = not (sim_final.iccid or sim_final.imsi)

	-- NV 550 存储的 IMEI（imei-tool），与 mmcli 报告的 modem.3gpp.imei 分开
	local im = run(IMEI_TOOL .. " get 2>&1")
	d.imei_nv = im and im:gsub("%s+$", "") or ""

	-- 当前强制运营商配置（运营商配置下拉），缺省 auto
	d.force_carrier = "auto"
	local fc = io.open(FORCE_CARRIER, "r")
	if fc then
		local v = fc:read("*l") or ""
		fc:close()
		v = v:gsub("%s+$", "")
		if v ~= "" then d.force_carrier = v end
	end

	d.msg = luci.util.urldecode(luci.http.formvalue("msg") or "")

	luci.template.render("cellular/status", { d = d })
end
