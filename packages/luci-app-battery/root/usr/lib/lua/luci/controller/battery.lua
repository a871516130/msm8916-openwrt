module("luci.controller.battery", package.seeall)

require "luci.dispatcher"

local i18n = require "luci.i18n"

function index()
    entry({"admin", "status", "battery"}, call("action_status"),
          _("Battery & Charge Limit"), 90)
    entry({"admin", "status", "battery", "data"}, call("action_data"))
end

local CHG     = "/sys/class/power_supply/pm8916-lbc-chgr"
local BATT    = "/sys/class/power_supply/pm8916-bms-vm"
local SESSION = "/etc/battery-session"

local function tr(s)
    if not s or s == "" or s == "-" then return s end
    return i18n.translate(s)
end

local function rd(p)
    local f = io.open(p, "r")
    if not f then return "-" end
    local v = f:read("*a")
    f:close()
    -- NOTE: the extra parentheses truncate gsub()'s second return value;
    -- without them callers like tonumber(rd(p)) receive (value, count).
    return ((v or ""):gsub("%s+$", ""))
end

-- Human-friendly units: sysfs gives uV and uA; the BMS temp is tenths of C.
local function fmt_v(ustr)
    local n = tonumber(ustr)
    if not n then return ustr end
    return string.format("%.3f V", n / 1000000)
end

local function fmt_temp(raw)
    local n = tonumber(raw)
    if not n then return raw end
    return string.format("%.1f C", n / 10)
end

local function fmt_cur(ustr)
    local n = tonumber(ustr)
    if not n then return ustr end
    local ma = n / 1000
    if ma >= 1000 then return string.format("%.2f A", ma / 1000) end
    return string.format("%.0f mA", ma)
end

local function fmt_cap(uah)
    local n = tonumber(uah)
    if not n then return uah end
    local ma = n / 1000
    if ma >= 1000 then return string.format("%.2f Ah", ma / 1000) end
    return string.format("%.0f mAh", ma)
end

local function read_kv(path)
    local t = {}
    local f = io.open(path, "r")
    if not f then return t end
    for line in f:lines() do
        local k, v = line:match("^([%w_]+)=(.*)$")
        if k then t[k] = v end
    end
    f:close()
    return t
end

local function fmt_dur(sec)
    sec = tonumber(sec)
    if not sec or sec < 0 then return "-" end
    local h = math.floor(sec / 3600)
    local m = math.floor((sec % 3600) / 60)
    if h > 0 then return string.format("%dh %02dm", h, m) end
    if m > 0 then return string.format("%d min", m) end
    return "under 1 min"
end

local function handle_actions()
    local http = require "luci.http"
    local uci  = require "luci.model.uci".cursor()
    local sys  = require "luci.sys"

    local act = http.formvalue("act")
    if act == "apply" then
        local limit   = http.formvalue("limit")
        local resume  = http.formvalue("resume")
        local enabled = http.formvalue("enabled")
        local ln = tonumber(limit)
        local rn = tonumber(resume)

        if not ln or not rn or ln < 1 or ln > 100 or rn < 1 or rn > 100 or rn >= ln then
            return "Invalid values, enter numbers between 1 and 100, resume below limit", true
        end

        uci:set("battery", "@charge[0]", "limit", limit)
        uci:set("battery", "@charge[0]", "resume", resume)
        uci:set("battery", "@charge[0]", "enabled",
                (enabled == "1") and "1" or "0")
        uci:commit("battery")
        sys.call("/etc/init.d/battery-charge-limit restart >/dev/null 2>&1")
        return "Settings saved"
    elseif act == "charge" then
        local v = http.formvalue("val")
        sys.call("echo " .. ((v == "1") and "1" or "0") ..
                 " > " .. CHG .. "/charge_enabled")
        return (v == "1") and "Charging enabled" or "Charging disabled"
    elseif act == "curr" then
        local ctrl = http.formvalue("cctrl")
        local ma = tonumber(http.formvalue("curr_ma"))
        if ctrl == "1" and ma and ma >= 90 and ma <= 1440 then
            sys.call(string.format("echo %d > %s/constant_charge_current",
                     math.floor(ma * 1000), CHG))
            uci:set("battery", "@charge[0]", "curr_ctrl", "1")
            uci:set("battery", "@charge[0]", "curr_ma", tostring(math.floor(ma)))
            uci:commit("battery")
            return "Charge current set"
        else
            -- Restore the device tree default (qcom,fast-charge-safe-current,
            -- 1000 mA on the MF32) rather than leaving the last custom value.
            sys.call(string.format("echo %d > %s/constant_charge_current",
                     1000000, CHG))
            uci:set("battery", "@charge[0]", "curr_ctrl", "0")
            uci:commit("battery")
            return "Charge current control off"
        end
    end
end

local function collect()
    local uci = require "luci.model.uci".cursor()

    local capraw  = rd(BATT .. "/capacity")
    local tempraw = rd(BATT .. "/temp")
    local capn    = tonumber(capraw)
    local tempn   = tonumber(tempraw)
    local rawst   = rd(BATT .. "/status")
    local rawhlth = rd(BATT .. "/health")

    -- The BMS driver returns -ENODATA (unreadable) when the batt-therm channel
    -- is absent or its VADC read fails, so the sysfs read fails and rd() yields
    -- "-" here.  A missing temperature is displayed as "-" rather than a fake
    -- 25 C: the OCV->capacity conversion still assumes 25 C internally, but the
    -- gauge must not present an unmeasured value as a real one.
    local tsensor = "bms"

    local d = {
        online  = rd(CHG .. "/online"),
        ce      = rd(CHG .. "/charge_enabled"),
        curr    = fmt_cur(rd(CHG .. "/constant_charge_current")),
        cvmax   = fmt_v(rd(CHG .. "/constant_charge_voltage_max")),
        cap     = capraw,
        vnow    = fmt_v(rd(BATT .. "/voltage_now")),
        temp    = fmt_temp(tempn),
        tsensor = tsensor,
        health  = tr(rawhlth),
        status  = tr(rawst),
        design  = fmt_cap(rd(BATT .. "/charge_full_design")),
        enabled = uci:get("battery", "@charge[0]", "enabled") or "1",
        limit   = uci:get("battery", "@charge[0]", "limit")  or "85",
        resume  = uci:get("battery", "@charge[0]", "resume") or "80",
    }

    -- ---- runtime on battery -------------------------------------------------
    -- The gauge exposes no current_now/power_now, so the discharge rate is
    -- derived from the capacity drop across the session recorded by
    -- /usr/sbin/battery-session (fed by battery-led-monitor).
    local ss   = read_kv(SESSION)
    local now  = os.time()
    local onbat = (d.online == "0")
    local elapsed = 0

    if onbat and tonumber(ss.start) then
        elapsed = now - tonumber(ss.start)
        if elapsed < 0 then elapsed = 0 end
    end

    local scap = tonumber(ss.start_cap)
    local rate, remain, full

    if onbat and elapsed >= 300 and capn and scap and scap > capn then
        rate = (scap - capn) / (elapsed / 3600)
        if rate >= 0.2 then
            remain = capn / rate * 3600
            full   = 100 / rate * 3600
        end
    end

    -- ---- charging estimate -------------------------------------------------
    -- Same gauge limitation as above: derive the charge rate from the capacity
    -- gain since the charger was attached (recorded by battery-session).
    local chg_start = tonumber(ss.chg_start)
    local chg_start_cap = tonumber(ss.chg_start_cap)
    local chgrate, chgfull

    if not onbat and chg_start and capn and chg_start_cap and capn > chg_start_cap then
        local celapsed = now - chg_start
        if celapsed < 0 then celapsed = 0 end
        if celapsed >= 120 then
            chgrate = (capn - chg_start_cap) / (celapsed / 3600)
            if chgrate >= 0.2 then
                chgfull = (100 - capn) / chgrate * 3600
            end
        end
    end

    -- The PM8916 BMS has no coulomb counter, so the kernel never exposes
    -- charge_full; fall back to the design capacity read from the device tree.
    local fullraw = rd(BATT .. "/charge_full")
    if not tonumber(fullraw) then
        fullraw = rd(BATT .. "/charge_full_design")
    end

    local sstart = tonumber(ss.start)
    local lstart = tonumber(ss.last_start)

    local currraw = rd(CHG .. "/constant_charge_current")
    local currn = tonumber(currraw)

    d.onbat    = onbat
    d.uptime   = onbat and fmt_dur(elapsed) or nil
    d.rate     = rate and string.format("%.1f %%/h", rate) or nil
    d.remain   = remain and fmt_dur(remain) or nil
    d.full     = full and fmt_dur(full) or nil
    d.chgrate  = chgrate and string.format("%.1f %%/h", chgrate) or nil
    d.chgfull  = chgfull and fmt_dur(chgfull) or nil
    d.startcap = scap
    d.starttime = (onbat and sstart) and os.date("%H:%M", sstart) or nil
    d.fullcap  = fmt_cap(fullraw)
    d.cctrl    = uci:get("battery", "@charge[0]", "curr_ctrl") or "0"
    d.currma   = currn and math.floor(currn / 1000) or 1000

    if tonumber(ss.last) then
        local dur = fmt_dur(ss.last)
        d.lastsess = lstart and (dur .. " \u00b7 " .. os.date("%H:%M", lstart)) or dur
    else
        d.lastsess = nil
    end

    if capn and capn < 15 then d.capclass = "bat-crit"
    elseif capn and capn < 40 then d.capclass = "bat-warn"
    else d.capclass = "bat-ok" end

    if capn then d.cappct = math.floor(capn) else d.cappct = 0 end

    if tempn and tempn >= 550 then d.tempclass = "bat-crit"
    elseif tempn and tempn >= 450 then d.tempclass = "bat-warn"
    else d.tempclass = "bat-ok" end

    d.chgclass = (d.online == "1") and "bat-ok" or "bat-warn"
    d.ceclass  = (d.ce == "1") and "bat-ok" or "bat-warn"
    d.chgtext  = (d.online == "1") and tr("Online") or tr("Offline")
    d.cetext   = (d.ce == "1") and tr("Yes") or tr("No")

    if rawst == "Charging" then d.stclass = "bat-ok"
    elseif rawst == "Full" then d.stclass = "bat-info"
    elseif rawst == "Not charging" and d.online == "1" then d.stclass = "bat-info"
    else d.stclass = "bat-warn" end

    local limitn = tonumber(d.limit)
    if d.enabled ~= "1" then
        d.lstate = tr("Disabled")
        d.lstateclass = "bat-info"
    elseif capn and limitn and capn >= limitn then
        d.lstate = tr("Active")
        d.lstateclass = "bat-warn"
    else
        d.lstate = tr("Standby")
        d.lstateclass = "bat-ok"
    end

    d.updated = os.date("%H:%M:%S")

    return d
end

function action_status()
    local flash, err = handle_actions()
    local d = collect()
    if flash then
        d.flash = tr(flash)
        if err then d.flashclass = "bat-crit" end
    end
    luci.template.render("battery/status", { d = d })
end

function action_data()
    local http = require "luci.http"
    local flash, err = handle_actions()
    local d = collect()
    if flash then
        d.flash = tr(flash)
        if err then d.flashclass = "bat-crit" end
    end
    http.prepare_content("application/json")
    http.write_json(d)
end
