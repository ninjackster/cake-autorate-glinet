#!/bin/sh
# gl-autorate-tune.sh -- derive the shaper bounds from what the link actually
# delivers, so they never have to be typed in per network.
#
# cake-autorate is a controller, not a discovery tool: it never probes above
# max, so max cannot simply be removed. This watches the rate it settles at and
# moves the bounds to match, remembering them per WAN device so a network you
# have used before is right immediately and a new one converges on its own.
#
# Run from cron. Cheap: it parses a log tail and writes nothing unless a bound
# actually needs to move.

CONF=cake-autorate
SEC=wan
CEILING=1000000     # 1 Gbit sanity cap
FLOOR=2000          # never propose a max below this
STEP_UP=125         # percent, when the shaper is pinned at max
SLACK=120           # percent headroom above the observed peak
DEADBAND=10         # percent change required before we rewrite anything

[ "$(uci -q get ${CONF}.${SEC}.auto_tune)" = "1" ] || exit 0
[ "$(uci -q get ${CONF}.${SEC}.enabled)"   = "1" ] || exit 0

dev="$(uci -q get ${CONF}.${SEC}.ul_if)"
[ -n "$dev" ] || exit 0
ifb="$(printf 'ifb4%s' "$dev" | cut -c1-15)"
LOG="/var/log/cake-autorate.${SEC}.log"
[ -f "$LOG" ] || exit 0

# Highest rate cake-autorate actually applied to a device since the log rotated.
peak_for() {
	tail -4000 "$LOG" 2>/dev/null |
		grep -o "dev $1 cake bandwidth [0-9]*Kbit" |
		grep -o '[0-9]*' | sort -n | tail -1
}

pct() { echo $(( $1 * $2 / 100 )); }

# Per-device memory, so returning to a known network skips the learning phase.
mem_key() { printf 'learned_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }

changed=0
bounds_changed=0
for dir in dl ul; do
	case "$dir" in
		dl) iface="$ifb" ;;
		ul) iface="$dev" ;;
	esac

	peak="$(peak_for "$iface")"
	[ -n "$peak" ] || continue

	# Remember what THIS device actually delivered. Recording the ceiling
	# instead would stamp the previous uplink's number onto a new one: that
	# is how a 60Mbit wifi ceiling ended up as the cellular "learned" value.
	if [ "$(uci -q get ${CONF}.$(mem_key "$dev")_${dir})" != "$peak" ]; then
		uci -q set ${CONF}.$(mem_key "$dev")_${dir}="$peak"
		changed=1
	fi

	cur_max="$(uci -q get ${CONF}.${SEC}.max_${dir}_shaper_rate_kbps)"
	[ -n "$cur_max" ] || continue

	# Pinned at the ceiling means the link may have more to give; otherwise
	# settle the ceiling just above what we have actually seen.
	if [ "$peak" -ge "$(pct "$cur_max" 98)" ]; then
		new_max="$(pct "$cur_max" "$STEP_UP")"
	else
		new_max="$(pct "$peak" "$SLACK")"
	fi

	[ "$new_max" -gt "$CEILING" ] && new_max="$CEILING"
	[ "$new_max" -lt "$FLOOR" ]   && new_max="$FLOOR"

	# Ignore noise; every write is a flash write and a service restart.
	delta=$(( new_max - cur_max )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
	[ "$delta" -lt "$(pct "$cur_max" "$DEADBAND")" ] && continue

	new_base="$(pct "$new_max" 85)"
	new_min="$(pct "$new_max" 15)"
	[ "$new_min" -lt "$FLOOR" ] && new_min="$FLOOR"

	uci -q set ${CONF}.${SEC}.max_${dir}_shaper_rate_kbps="$new_max"
	uci -q set ${CONF}.${SEC}.base_${dir}_shaper_rate_kbps="$new_base"
	uci -q set ${CONF}.${SEC}.min_${dir}_shaper_rate_kbps="$new_min"
	changed=1; bounds_changed=1
	logger -t cake-autorate-tune \
		"${dir} on ${dev}: peak ${peak}k, max ${cur_max}k -> ${new_max}k"
done

if [ "$changed" = "1" ]; then
	# The idle threshold must stay at or below the upload minimum or the
	# service refuses to start.
	ulmin="$(uci -q get ${CONF}.${SEC}.min_ul_shaper_rate_kbps)"
	thr="$(uci -q get ${CONF}.${SEC}.connection_active_thr_kbps)"
	[ -n "$ulmin" ] && [ -n "$thr" ] && [ "$thr" -gt "$ulmin" ] && \
		uci -q set ${CONF}.${SEC}.connection_active_thr_kbps="$(pct "$ulmin" 50)"
	uci -q commit ${CONF}
	[ "$bounds_changed" = "1" ] && /etc/init.d/cake-autorate restart >/dev/null 2>&1
fi
