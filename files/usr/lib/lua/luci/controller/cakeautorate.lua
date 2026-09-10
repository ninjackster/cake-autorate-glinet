-- LuCI controller for the cake-autorate port.
module("luci.controller.cakeautorate", package.seeall)

function index()
	if not nixio.fs.access("/etc/config/cake-autorate") then
		return
	end
	entry({"admin", "network", "cakeautorate"},
		cbi("cakeautorate"), _("Cake Autorate"), 90).dependent = true
end
