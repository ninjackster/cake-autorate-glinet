#!/bin/sh
# gl-wan-follow.sh -- point SQM and cake-autorate at whichever WAN is currently active.
#
# Part of the cake-autorate port for GL.iNet routers. GPL-2.0, matching
# cake-autorate itself.
#
# GL's cake-autorate glue assumes one fixed WAN device. A travel router moves
# between repeater, ethernet, USB tether and cellular, and the cellular device
# (rmnet_dataN) has no netifd network.interface at all. This resolves the live
# WAN from the routing table instead, which covers every case uniformly.

CONF=cake-autorate
SECTION=wan
LOCK=/var/lock/cake-wan-follow.lock

log() { logger -t cake-wan-follow "$1"; }

# Lowest-metric default route wins: that is the route traffic actually takes.
current_wan_dev() {
	ip route show default 2>/dev/null | awk '
		{ d = ""; m = 0
		  for (i = 1; i <= NF; i++) {
			# A linkdown route is still in the table but is not a WAN.
			if ($i == "linkdown") next
			if ($i == "dev")      d = $(i+1)
			if ($i == "metric")   m = $(i+1)
		  }
		  if (d == "") next
		  # Never follow a tunnel. If a VPN client puts its default route in
		  # the main table we would shape the tunnel and silently unshape the
		  # physical uplink underneath it, which is the real bottleneck.
		  if (d ~ /^(wg|tun|ovpn|tailscale|ipsec|gre|sit)/) next
		  if (best == "" || m+0 < bm+0) { best = d; bm = m }
		}
		END { print best }'
}

# Byte-identical to ifb_name() in /usr/lib/sqm/functions.sh, which does
# echo -n "ifb4${IF}" | head -c 15. Verified against sqm-scripts 1.6.0.
ifb_name() { printf 'ifb4%s' "$1" | cut -c1-15; }

[ "$(uci -q get ${CONF}.${SECTION}.wan_follow)" = "1" ] || exit 0
[ "$(uci -q get ${CONF}.${SECTION}.enabled)" = "1" ]    || exit 0

exec 9>"$LOCK"
# Wait rather than drop. Two events can arrive close together during a failover
# and the second one carries the newer routing table, so discarding it would
# leave us pointed at the interface that just went away. This script is
# idempotent, so serializing is safe.
#
# busybox flock has only -s -x -u -n; there is no -w, so the bounded wait is
# a retry loop. Bounded rather than blocking because cron also calls this.
lock_wait=0
while ! flock -n 9
do
	lock_wait=$((lock_wait + 1))
	[ "$lock_wait" -ge 60 ] && exit 0
	sleep 1
done

dev="$(current_wan_dev)"
if [ -z "$dev" ]; then
	if /etc/init.d/cake-autorate running 2>/dev/null; then
		log "no default route; stopping"
		/etc/init.d/cake-autorate stop >/dev/null 2>&1 9>&-
	fi
	exit 0
fi

prev="$(uci -q get ${CONF}.${SECTION}.ul_if)"
sqm_if="$(uci -q get sqm.autorate.interface)"

# Only require the SQM device to match when SQM is actually configured here.
# Comparing unconditionally would never match while sqm.autorate is absent,
# so every cron tick would restart the service.
sqm_ok=1
if [ "$(uci -q get sqm.autorate)" = "queue" ] && [ "$dev" != "$sqm_if" ]; then
	sqm_ok=0
fi

# Compare against actual state, not against the last value we wrote. If an
# uplink drops and the same one returns, ul_if still matches while the service
# sits stopped, and comparing only ul_if would never restart it.
if [ "$dev" = "$prev" ] && [ "$sqm_ok" = "1" ] \
   && /etc/init.d/cake-autorate running 2>/dev/null
then
	exit 0
fi

if [ "$dev" != "$prev" ]; then
	log "WAN changed: ${prev:-none} -> ${dev}"
	uci -q set ${CONF}.${SECTION}.ul_if="$dev"
	uci -q set ${CONF}.${SECTION}.dl_if="$(ifb_name "$dev")"
	uci -q commit ${CONF}
fi

# cake-autorate adjusts an existing cake qdisc; it never creates one.
# SQM has to be shaping the same device or there is nothing to drive.
if [ "$(uci -q get sqm.autorate)" = "queue" ]; then
	if [ "$dev" != "$sqm_if" ]; then
		uci -q set sqm.autorate.interface="$dev"
		uci -q commit sqm
	fi
	/etc/init.d/sqm restart >/dev/null 2>&1 9>&-
fi

/etc/init.d/cake-autorate restart >/dev/null 2>&1 9>&-
log "now shaping ${dev}"
