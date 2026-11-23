module("luci.controller.modemstatus", package.seeall)

require "luci.dispatcher"

local i18n = require "luci.i18n"

function index()
    -- 节点路径必须与 /usr/share/luci/menu.d/luci-proto-modemmanager.json 的菜单键一致
    -- (原来是 admin/status/modemmanager, 且 action.type=view 指向前端 JS 视图)
    entry({"admin", "status", "modemmanager"}, call("action_status"),
          _("Cellular Modem"), 85)
end

local DEVICE = "qcom-soc"

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
-- 键与冒号之间是多空格, 值在冒号后
local function kvparse(out)
    local t = {}
    if not out then return t end
    for line in out:gmatch("[^\n]+") do
        local k, v = line:match("^(%S+)%s*:%s*(.*)$")
        if k then t[k] = v end
    end
    return t
end

-- QMI 端口与 ModemManager 有 CID 争用(endpoint hangup), 需要多次重试
-- 只有出现 "Successfully" 才算成功, 避免把 -Warning 行当成结果
local function qmicli_retry(cmd, tries)
    tries = tries or 8
    for _ = 1, tries do
        local out = run(cmd)
        if out and out:find("Successfully") then
            return out
        end
    end
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
    { "modem.generic.access-technologies",            "accesstech" },
    { "modem.generic.manufacturer",                   "mfr" },
    { "modem.generic.model",                          "model" },
    { "modem.generic.revision",                       "rev" },
    { "modem.generic.device-identifier",              "did" },
    { "modem.generic.carrier-configuration",          "carrier_cfg" },
    { "modem.generic.own-numbers",                    "own_numbers" },
    { "modem.dbus-path",                               "dbus" },
}

local function collect()
    local d = {}
    local out = run(string.format("mmcli --modem=%s -K 2>/dev/null", DEVICE))
    if not out or out == "" then
        d.error = "ModemManager 未返回数据（modem 不可用或 MM 未运行）"
        return d
    end

    local kv = kvparse(out)
    for _, p in ipairs(FIELDS) do
        d[p[2]] = kv[p[1]] or "--"
    end

    local q = qmicli_retry(
        "timeout 8 qmicli -d /dev/wwan0qmi0 --nas-get-serving-system 2>/dev/null")
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

    local b = qmicli_retry(
        "timeout 8 qmicli -d /dev/wwan0qmi0 --nas-get-rf-band-info 2>/dev/null")
    if b then
        local cls = b:match("Active Band Class:%s+'([^']*)'")
        if cls then d.band = cls end
        local ch = b:match("Active Channel:%s+'([^']*)'")
        if ch then d.channel = ch end
    end

    return d
end

function action_status()
    luci.template.render("modemmanager/status", { d = collect() })
end
