#!/bin/sh
# gl-autorate-tune.sh -- derive the shaper bounds from what the link actually
# delivers, so they never have to be typed in per network.
#
# cake-autorate is a controller, not a discovery tool: it never probes above
# max, so max cannot simply be removed. This watches the rate it settles at and
# moves the bounds to match, keyed on the UPLINK rather than the shaped device,
# because capacity belongs to the link.

. /usr/lib/cake-autorate/gl-shape-lib.sh

STEP_UP=125         # percent, when the shaper is pinned at max
SLACK=120           # percent headroom above the observed peak
DEADBAND=10         # percent change required before rewriting anything

[ "$(uci -q get ${CONF}.${SECTION}.auto_tune)" = "1" ] || exit 0
[ "$(uci -q get ${CONF}.${SECTION}.enabled)"   = "1" ] || exit 0

# The follower writes the same UCI config and restarts the same service, from
# cron every minute and from hotplug. Without this the tuner could interleave a
# UCI commit or restart the service underneath it.
exec 9>"$LOCK_FILE"
take_lock 60 || exit 0

wan="$(uci -q get ${CONF}.${SECTION}.active_wan)"
[ -n "$wan" ] || exit 0
LOG="/var/log/cake-autorate.${SECTION}.log"
[ -f "$LOG" ] || exit 0

pct() { echo $(( $1 * $2 / 100 )); }

peak_for() {
	tail -4000 "$LOG" 2>/dev/null |
		grep -o "dev $1 cake bandwidth [0-9]*Kbit" |
		grep -o '[0-9]*' | sort -n | tail -1
}

changed=0
bounds_changed=0
for dir in dl ul; do
	iface="$(uci -q get ${CONF}.${SECTION}.${dir}_if)"
	[ -n "$iface" ] || continue

	peak="$(peak_for "$iface")"
	[ -n "$peak" ] || continue

	# Record what THIS uplink actually delivered. Recording the ceiling instead
	# would stamp the previous link's number onto a new one, which is how a
	# 60Mbit wifi ceiling once became the cellular "learned" value.
	if [ "$(uci -q get ${CONF}.$(mem_key "$wan")_${dir})" != "$peak" ]; then
		uci -q set ${CONF}.$(mem_key "$wan")_${dir}="$peak"
		changed=1
	fi

	cur_max="$(uci -q get ${CONF}.${SECTION}.max_${dir}_shaper_rate_kbps)"
	[ -n "$cur_max" ] || continue

	if [ "$peak" -ge "$(pct "$cur_max" 98)" ]; then
		new_max="$(pct "$cur_max" "$STEP_UP")"
	else
		new_max="$(pct "$peak" "$SLACK")"
	fi

	delta=$(( new_max - cur_max )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
	[ "$delta" -lt "$(pct "$cur_max" "$DEADBAND")" ] && continue

	set_bounds "$dir" "$new_max"
	changed=1; bounds_changed=1
	logger -t cake-autorate-tune \
		"${dir} on ${wan}: peak ${peak}k, max ${cur_max}k -> ${new_max}k"
done

if [ "$changed" = "1" ]; then
	clamp_active_thr
	uci -q commit ${CONF}
	[ "$bounds_changed" = "1" ] && /etc/init.d/cake-autorate restart >/dev/null 2>&1 9>&-
fi
