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

# Peak rate applied to a device SINCE THE LAST SERVICE START.
#
# Bounding it to this run matters on a travel router: device names are reused
# across completely different networks, so wlan4 at one rental is not wlan4 at
# the next. A stale peak from a fast link would inflate the ceiling on a slow
# one, and the tuner would then spend its time probing bandwidth that is not
# there. cake-autorate restarts whenever the uplink changes, so its own start
# line is exactly the right boundary.
#
# The number is taken from between "bandwidth " and "Kbit" rather than with a
# bare [0-9]* match, which would also capture the digit in a name like wlan4.
peak_for() {
	awk -v ifc="$1" '
		/Started cake-autorate/ { seen = 1; max = 0; next }
		seen && index($0, "dev " ifc " cake bandwidth ") {
			if (match($0, /bandwidth [0-9]+Kbit/)) {
				v = substr($0, RSTART + 10, RLENGTH - 14) + 0
				if (v > max) max = v
			}
		}
		END { if (max > 0) print max }
	' "$LOG" 2>/dev/null
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
	[ "$bounds_changed" = "1" ] && restart_autorate
fi
