#!/bin/sh
# gl-autorate-ctl.sh {on|off|status} -- one command to turn adaptive shaping
# on or off.
#
# cake-autorate only ADJUSTS an existing cake qdisc; it never creates one. So
# turning it on means provisioning an SQM queue on the live WAN as well, which
# is the step that makes this a two-part operation rather than a single toggle.

CONF=cake-autorate
SECTION=wan

current_wan_dev() {
	ip route show default 2>/dev/null | awk '
		{ d = ""; m = 0
		  for (i = 1; i <= NF; i++) {
			if ($i == "linkdown") next
			if ($i == "dev")      d = $(i+1)
			if ($i == "metric")   m = $(i+1)
		  }
		  if (d == "") next
		  if (d ~ /^(wg|tun|ovpn|tailscale|ipsec|gre|sit)/) next
		  # Never shape a Qualcomm modem interface. rmnet devices sit on the
		  # IPA hardware data path and use rmnet_sch; replacing the root qdisc
		  # and adding an IFB ingress redirect on one takes the link down.
		  # Shaping such a WAN needs a different approach (see README).
		  if (d ~ /^(rmnet|wwan|usb|qmimux|ccmni)/) next
		  if (best == "" || m+0 < bm+0) { best = d; bm = m }
		}
		END { print best }'
}

ifb_name() { printf 'ifb4%s' "$1" | cut -c1-15; }

case "$1" in
on)
	dev="$(current_wan_dev)"
	[ -n "$dev" ] || { echo "no usable WAN (no default route)"; exit 1; }

	uci -q set ${CONF}.${SECTION}=cake_autorate
	uci -q set ${CONF}.${SECTION}.ul_if="$dev"
	uci -q set ${CONF}.${SECTION}.dl_if="$(ifb_name "$dev")"
	uci -q set ${CONF}.${SECTION}.enabled=1
	uci -q set ${CONF}.${SECTION}.wan_follow=1
	# The tuner derives the bounds from the rates actually applied, which are
	# only written to the log when this is on.
	[ "$(uci -q get ${CONF}.${SECTION}.auto_tune)" = "1" ] && \
		uci -q set ${CONF}.${SECTION}.output_cake_changes=1
	uci -q commit ${CONF}

	uci -q set sqm.autorate=queue
	uci -q set sqm.autorate.interface="$dev"
	uci -q set sqm.autorate.enabled=1
	uci -q set sqm.autorate.qdisc=cake
	uci -q set sqm.autorate.script=piece_of_cake.qos
	uci -q set sqm.autorate.qdisc_advanced=0
	uci -q set sqm.autorate.linklayer=none
	uci -q set sqm.autorate.download="$(uci -q get ${CONF}.${SECTION}.base_dl_shaper_rate_kbps)"
	uci -q set sqm.autorate.upload="$(uci -q get ${CONF}.${SECTION}.base_ul_shaper_rate_kbps)"
	uci -q commit sqm

	/etc/init.d/sqm restart >/dev/null 2>&1
	/etc/init.d/cake-autorate enable >/dev/null 2>&1
	/etc/init.d/cake-autorate restart >/dev/null 2>&1
	echo "on: shaping ${dev}"
	;;
off)
	/etc/init.d/cake-autorate stop >/dev/null 2>&1
	/etc/init.d/cake-autorate disable >/dev/null 2>&1
	uci -q set ${CONF}.${SECTION}.enabled=0
	uci -q commit ${CONF}
	# Deleting the section is not enough: sqm-scripts leaves the qdisc and the
	# ifb device in place until it is restarted.
	if [ "$(uci -q get sqm.autorate)" = "queue" ]; then
		uci -q delete sqm.autorate
		uci -q commit sqm
		/etc/init.d/sqm restart >/dev/null 2>&1
	fi
	echo "off"
	;;
status)
	dev="$(uci -q get ${CONF}.${SECTION}.ul_if)"
	echo "enabled:   $(uci -q get ${CONF}.${SECTION}.enabled)"
	echo "wan:       ${dev:-none}"
	echo "running:   $(/etc/init.d/cake-autorate running 2>/dev/null && echo yes || echo no)"
	echo "sqm:       $(uci -q get sqm.autorate.enabled 2>/dev/null || echo absent)"
	[ -n "$dev" ] && echo "shaper up: $(tc qdisc show dev "$dev" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1)"
	[ -n "$dev" ] && echo "shaper dn: $(tc qdisc show dev "$(ifb_name "$dev")" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1)"
	;;
*)
	echo "usage: $0 {on|off|status}"; exit 1 ;;
esac
