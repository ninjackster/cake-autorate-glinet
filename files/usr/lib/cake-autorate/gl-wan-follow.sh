#!/bin/sh
# gl-wan-follow.sh -- keep SQM and cake-autorate pointed at the right device as
# the uplink changes. GPL-2.0, matching cake-autorate itself.
#
# A travel router moves between repeater, ethernet, USB tether and cellular.
# The cellular device has no netifd network.interface, and cannot be shaped
# directly at all, so the target is resolved per uplink.

. /usr/lib/cake-autorate/gl-shape-lib.sh

log() { logger -t cake-wan-follow "$1"; }

[ "$(uci -q get ${CONF}.${SECTION}.wan_follow)" = "1" ] || exit 0
[ "$(uci -q get ${CONF}.${SECTION}.enabled)"    = "1" ] || exit 0

exec 9>"$LOCK_FILE"
take_lock 60 || exit 0

dev="$(wan_dev)"
if [ -z "$dev" ]; then
	if /etc/init.d/cake-autorate running 2>/dev/null 9>&-; then
		log "no default route; stopping"
		/etc/init.d/cake-autorate stop >/dev/null 2>&1 9>&-
	fi
	exit 0
fi

target="$(shape_target "$dev")"
resolve_shaping "$dev" "$target"

prev_wan="$(uci -q get ${CONF}.${SECTION}.active_wan)"
prev_ul="$(uci -q get ${CONF}.${SECTION}.ul_if)"
sqm_if="$(uci -q get sqm.autorate.interface)"

sqm_ok=1
if [ "$(uci -q get sqm.autorate)" = "queue" ] && [ "$SHAPE_IF" != "$sqm_if" ]; then
	sqm_ok=0
fi

# Compare against actual state, not the last value written. If an uplink drops
# and the same one returns, ul_if still matches while the service sits stopped.
if [ "$dev" = "$prev_wan" ] && [ "$CA_UL_IF" = "$prev_ul" ] && [ "$sqm_ok" = "1" ] \
   && /etc/init.d/cake-autorate running 2>/dev/null 9>&-
then
	exit 0
fi

# A modem renumbers itself (rmnet_data0 <-> rmnet_data1) without the link
# changing. In bridge mode the shaped device is br-lan either way, so record
# the new name for the tuner's memory key but do not tear the shaper down.
if [ "$dev" != "$prev_wan" ] && [ "$CA_UL_IF" = "$prev_ul" ] && [ "$sqm_ok" = "1" ] \
   && /etc/init.d/cake-autorate running 2>/dev/null 9>&-
then
	uci -q set ${CONF}.${SECTION}.active_wan="$dev"
	uci -q commit ${CONF}
	log "uplink renamed ${prev_wan} -> ${dev}; shaping ${SHAPE_IF} unchanged"
	exit 0
fi

if [ "$dev" != "$prev_wan" ] || [ "$CA_UL_IF" != "$prev_ul" ]; then
	log "uplink ${prev_wan:-none} -> ${dev}, shaping ${SHAPE_IF} (${target} mode)"
	uci -q set ${CONF}.${SECTION}.active_wan="$dev"
	uci -q set ${CONF}.${SECTION}.ul_if="$CA_UL_IF"
	uci -q set ${CONF}.${SECTION}.dl_if="$CA_DL_IF"

	# Bounds measured on this uplink previously. Keyed on the uplink, not the
	# shaped device, because capacity is a property of the link.
	if [ "$(uci -q get ${CONF}.${SECTION}.auto_tune)" = "1" ]; then
		key="learned_$(printf '%s' "$dev" | tr -c 'A-Za-z0-9' '_')"
		for d in dl ul; do
			p="$(uci -q get ${CONF}.${key}_${d})"
			[ -n "$p" ] || continue
			set_bounds "$d" $(( p * 120 / 100 ))
			log "restored ${d} bounds for ${dev} from observed peak ${p}k"
		done
		clamp_active_thr
	fi
	uci -q commit ${CONF}
fi

# cake-autorate adjusts an existing cake qdisc; it never creates one.
write_sqm
/etc/init.d/sqm restart >/dev/null 2>&1 9>&-
/etc/init.d/cake-autorate restart >/dev/null 2>&1 9>&-
log "now shaping ${SHAPE_IF} for uplink ${dev}"
