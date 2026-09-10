-- Cake Autorate settings page.
--
-- Toggling Enable does more than write a UCI flag: cake-autorate can only
-- adjust an existing cake qdisc, so gl-autorate-ctl.sh also provisions or
-- tears down the SQM queue on the live WAN.
local sys  = require "luci.sys"
local uci  = require "luci.model.uci".cursor()

local m = Map("cake-autorate",
	translate("Cake Autorate"),
	translate("Latency-driven shaper that raises or lowers the CAKE bandwidth " ..
	          "in real time based on probe RTT. There is no active speed test, " ..
	          "only lightweight pings. Worth enabling when the WAN rate moves " ..
	          "underneath you (cellular, repeatered hotel or rental wifi). " ..
	          "Not needed on a stable wired link, where a fixed rate is better."))

local s = m:section(NamedSection, "wan", "cake_autorate", translate("WAN instance"))
s.addremove = false
s.anonymous = true

local o

o = s:option(Flag, "enabled", translate("Enable"),
	translate("Turns on adaptive shaping and provisions the SQM queue it needs."))
o.rmempty = false

o = s:option(Flag, "wan_follow", translate("Follow the active WAN"),
	translate("Re-point the shaper automatically when the uplink changes " ..
	          "(repeater, ethernet, USB tether, cellular)."))
o.default = "1"
o.rmempty = false

o = s:option(DummyValue, "_wan", translate("Currently shaping"))
o.rawhtml = true
o.cfgvalue = function()
	local dev = uci:get("cake-autorate", "wan", "ul_if") or "none"
	local run = sys.call("/etc/init.d/cake-autorate running >/dev/null 2>&1") == 0
	return string.format("<strong>%s</strong> &middot; service %s", dev,
		run and "running" or "stopped")
end

-- The live rate is the thing autorate actually moves. It is not stored in
-- UCI (cake-autorate only ever issues "tc qdisc change"), so without this
-- the page would show static config and give no sign the shaper is working.
o = s:option(DummyValue, "_rates", translate("Live shaper rate"))
o.rawhtml = true
o.cfgvalue = function()
	local dev = uci:get("cake-autorate", "wan", "ul_if") or ""
	if not dev:match("^[%w%.%-_]+$") then
		return "<em>not shaping</em>"
	end

	-- tc picks its own unit (40Mbit one moment, 52302Kbit the next), so
	-- normalise to a single scale and show bytes alongside bits.
	local function fmt(d)
		local r = sys.exec("tc qdisc show dev " .. d ..
			" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1") or ""
		r = r:gsub("bandwidth ", ""):gsub("%s+", "")
		if r == "" then return "-" end
		local n, unit = r:match("^([%d%.]+)(%a+)$")
		if not n then return r end
		n = tonumber(n)
		local u, kbit = unit:lower(), nil
		if     u == "bit"  then kbit = n / 1000
		elseif u == "kbit" then kbit = n
		elseif u == "mbit" then kbit = n * 1000
		elseif u == "gbit" then kbit = n * 1000000
		else return r end
		return string.format("%.1f Mbit/s <small>(%.1f MB/s)</small>",
			kbit / 1000, kbit / 8000)
	end

	local ifb = ("ifb4" .. dev):sub(1, 15)
	return string.format(
		"down <strong>%s</strong><br />up <strong>%s</strong>" ..
		"<br /><small>Adjusted continuously between the min and max below. " ..
		"The fields on this page are the bounds, not the live value.</small>",
		fmt(ifb), fmt(dev))
end

o = s:option(Value, "base_dl_shaper_rate_kbps", translate("Download base (kbit/s)"),
	translate("Where the shaper starts, and where it returns after an idle period. Set it near your normal measured rate."))
o.datatype = "uinteger"

o = s:option(Value, "min_dl_shaper_rate_kbps", translate("Download min (kbit/s)"))
o.datatype = "uinteger"

o = s:option(Value, "max_dl_shaper_rate_kbps", translate("Download max (kbit/s)"))
o.datatype = "uinteger"

o = s:option(Value, "base_ul_shaper_rate_kbps", translate("Upload base (kbit/s)"))
o.datatype = "uinteger"

o = s:option(Value, "min_ul_shaper_rate_kbps", translate("Upload min (kbit/s)"))
o.datatype = "uinteger"

o = s:option(Value, "max_ul_shaper_rate_kbps", translate("Upload max (kbit/s)"))
o.datatype = "uinteger"

o = s:option(Value, "connection_active_thr_kbps", translate("Idle threshold (kbit/s)"),
	translate("Must not exceed the upload minimum, or the service exits at startup."))
o.datatype = "uinteger"

o = s:option(Value, "dl_owd_delta_delay_thr_ms", translate("Download delay threshold (ms)"))
o = s:option(Value, "ul_owd_delta_delay_thr_ms", translate("Upload delay threshold (ms)"))

m.on_after_commit = function(self)
	local en = uci:get("cake-autorate", "wan", "enabled")
	if en == "1" then
		sys.call("/usr/lib/cake-autorate/gl-autorate-ctl.sh on >/dev/null 2>&1 &")
	else
		sys.call("/usr/lib/cake-autorate/gl-autorate-ctl.sh off >/dev/null 2>&1 &")
	end
end

return m
