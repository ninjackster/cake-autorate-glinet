#!/bin/sh
# gl-autorate-httpd.sh -- expose the toggle endpoint on the tailnet only.
#
# Two mechanisms, BOTH required:
#
#   1. The listener binds to the router's Tailscale address, so it fails closed:
#      if Tailscale is down there is no address to bind and nothing comes up.
#   2. A source restriction to 100.64.0.0/10. Binding alone is NOT enough, and
#      this is the easy mistake: the router is the default gateway for its own
#      LAN, so a LAN client simply routes to the tailnet address and reaches the
#      listener. Measured HTTP 200 from a LAN host with Tailscale stopped.
#
# The firewall rules are therefore reconciled on EVERY run, never skipped
# because the binding happens to be unchanged. An earlier version returned early
# when listen_http already matched, which left the port open with no restriction
# if the rules were ever missing. Verified failing before the fix.

PORT="${PORT:-8099}"
SECTION=autorate

ts_ip() { tailscale ip -4 2>/dev/null | head -1; }

drop_firewall_rules() {
	changed=0
	[ -n "$(uci -q get firewall.autorate_allow)" ] && { uci -q delete firewall.autorate_allow; changed=1; }
	[ -n "$(uci -q get firewall.autorate_deny)" ]  && { uci -q delete firewall.autorate_deny;  changed=1; }
	[ "$changed" = "1" ] && { uci -q commit firewall; /etc/init.d/firewall reload >/dev/null 2>&1; }
}

ip="$(ts_ip)"

if [ -z "$ip" ]; then
	# No tailnet address: tear down the listener AND the rules, so nothing is
	# left half-configured.
	if [ -n "$(uci -q get uhttpd.${SECTION})" ]; then
		uci -q delete uhttpd.${SECTION}
		uci -q commit uhttpd
		/etc/init.d/uhttpd reload >/dev/null 2>&1
	fi
	drop_firewall_rules
	logger -t cake-autorate-httpd "no Tailscale address; endpoint torn down"
	exit 0
fi

# --- listener, every option reconciled --------------------------------------
# Gating the whole section on listen_http alone was a bug: changing any other
# option (max_requests, timeouts) would never be applied on a router whose
# binding already matched. Same failure shape as the firewall rules below.
want="${ip}:${PORT}"
uh_changed=0
uh_set() { # key, value
	[ "$(uci -q get uhttpd.${SECTION}.$1)" = "$2" ] && return 0
	uci -q set uhttpd.${SECTION}.$1="$2"
	uh_changed=1
}

if [ "$(uci -q get uhttpd.${SECTION})" != "uhttpd" ]; then
	uci -q set uhttpd.${SECTION}=uhttpd
	uh_changed=1
fi
if [ "$(uci -q get uhttpd.${SECTION}.listen_http)" != "$want" ]; then
	uci -q delete uhttpd.${SECTION}.listen_http
	uci -q add_list uhttpd.${SECTION}.listen_http="$want"
	uh_changed=1
fi
uh_set home '/usr/lib/cake-autorate/www'
uh_set cgi_prefix '/cgi-bin'
uh_set script_timeout '60'
uh_set network_timeout '30'
uh_set no_dirlists '1'
# Not 3. Three concurrent requests against a 60s script timeout is a trivial
# self-inflicted denial of service.
uh_set max_requests '20'

if [ "$uh_changed" = "1" ]; then
	uci -q commit uhttpd
	/etc/init.d/uhttpd reload >/dev/null 2>&1
	logger -t cake-autorate-httpd "listener reconciled on ${want}"
fi

# --- source restriction, reconciled unconditionally -------------------------
# fw4 emits rules in config order, so the accept must precede the drop.
fw_changed=0
want_rule() { # name, target, src_ip(optional)
	sec="$1"; nm="$2"; tgt="$3"; src="$4"
	[ "$(uci -q get firewall.${sec}.name)"      = "$nm" ] && \
	[ "$(uci -q get firewall.${sec}.target)"    = "$tgt" ] && \
	[ "$(uci -q get firewall.${sec}.dest_port)" = "$PORT" ] && \
	[ "$(uci -q get firewall.${sec}.src_ip)"    = "$src" ] && return 1
	uci -q delete firewall.${sec} 2>/dev/null
	uci -q set firewall.${sec}=rule
	uci -q set firewall.${sec}.name="$nm"
	uci -q set firewall.${sec}.src='*'
	uci -q set firewall.${sec}.proto='tcp'
	[ -n "$src" ] && uci -q set firewall.${sec}.src_ip="$src"
	uci -q set firewall.${sec}.dest_port="$PORT"
	uci -q set firewall.${sec}.target="$tgt"
	return 0
}

want_rule autorate_allow 'Allow-autorate-toggle-tailnet'   ACCEPT '100.64.0.0/10' && fw_changed=1
want_rule autorate_deny  'Block-autorate-toggle-elsewhere' DROP   ''              && fw_changed=1

if [ "$fw_changed" = "1" ]; then
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	logger -t cake-autorate-httpd "source restriction reconciled (tailnet only)"
fi
