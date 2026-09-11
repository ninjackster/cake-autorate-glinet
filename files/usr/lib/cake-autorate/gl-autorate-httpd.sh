#!/bin/sh
# gl-autorate-httpd.sh -- (re)bind the toggle endpoint to the Tailscale address.
#
# Binding to the tailnet IP fails closed: if Tailscale is down there is no
# address to bind and the listener does not come up.
#
# Binding is NOT sufficient on its own, which is easy to get wrong. The router
# is the default gateway for its own LAN, so a LAN client can simply route to
# the tailnet address and reach the listener. Measured: a LAN host with
# Tailscale stopped got HTTP 200 from http://<tailnet-ip>:8099. So the source
# address is restricted too, and the two together are what make this
# tailnet-only.
#
# Run at boot and whenever the Tailscale address could have changed.

PORT="${PORT:-8099}"
SECTION=autorate

ts_ip() { tailscale ip -4 2>/dev/null | head -1; }

ip="$(ts_ip)"
if [ -z "$ip" ]; then
	logger -t cake-autorate-httpd "no Tailscale address; endpoint not started"
	uci -q delete uhttpd.${SECTION} && uci -q commit uhttpd
	/etc/init.d/uhttpd reload >/dev/null 2>&1
	exit 0
fi

want="${ip}:${PORT}"
have="$(uci -q get uhttpd.${SECTION}.listen_http)"
[ "$have" = "$want" ] && exit 0

uci -q set uhttpd.${SECTION}=uhttpd
uci -q delete uhttpd.${SECTION}.listen_http
uci -q add_list uhttpd.${SECTION}.listen_http="$want"
uci -q set uhttpd.${SECTION}.home='/usr/lib/cake-autorate/www'
uci -q set uhttpd.${SECTION}.cgi_prefix='/cgi-bin'
uci -q set uhttpd.${SECTION}.script_timeout='60'
uci -q set uhttpd.${SECTION}.network_timeout='30'
uci -q set uhttpd.${SECTION}.no_dirlists='1'
uci -q set uhttpd.${SECTION}.max_requests='3'
uci -q commit uhttpd
/etc/init.d/uhttpd reload >/dev/null 2>&1

# Source restriction. 100.64.0.0/10 is the CGNAT range Tailscale allocates
# from; a LAN client cannot use a source address in it and still receive the
# reply. Order matters: fw4 emits rules in config order, so the accept has to
# precede the drop.
uci -q delete firewall.autorate_allow 2>/dev/null
uci -q set firewall.autorate_allow=rule
uci -q set firewall.autorate_allow.name='Allow-autorate-toggle-tailnet'
uci -q set firewall.autorate_allow.src='*'
uci -q set firewall.autorate_allow.proto='tcp'
uci -q set firewall.autorate_allow.src_ip='100.64.0.0/10'
uci -q set firewall.autorate_allow.dest_port="$PORT"
uci -q set firewall.autorate_allow.target='ACCEPT'

uci -q delete firewall.autorate_deny 2>/dev/null
uci -q set firewall.autorate_deny=rule
uci -q set firewall.autorate_deny.name='Block-autorate-toggle-elsewhere'
uci -q set firewall.autorate_deny.src='*'
uci -q set firewall.autorate_deny.proto='tcp'
uci -q set firewall.autorate_deny.dest_port="$PORT"
uci -q set firewall.autorate_deny.target='DROP'

uci -q commit firewall
/etc/init.d/firewall reload >/dev/null 2>&1
logger -t cake-autorate-httpd "toggle endpoint bound to ${want}, tailnet-only"
