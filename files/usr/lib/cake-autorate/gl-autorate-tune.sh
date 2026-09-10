#!/bin/sh
# gl-autorate-tune.sh -- derive the shaper bounds from what the link actually
# delivers, so they never have to be typed in per network.
#
# cake-autorate is a controller, not a discovery tool: it never probes above
# max, so max cannot simply be removed. This watches the rate it settles at and
# moves the bounds to match, keyed on the UPLINK rather than the shaped device,
# because capacity belongs to the link.

. /usr/lib/cake-autorate/gl-shape-lib.sh

CEILING=1000000     # 1 Gbit sanity cap
FLOOR=2000          # never propose a max below this
STEP_UP=125         # percent, when the shaper is pinned at max
SLACK=120           # percent headroom above the observed peak
DEADBAND=10         # percent change required before rewriting anything

[ "$(uci -q get ${CONF}.${SECTION}.auto_tune)" = "1" ] || exit 0
[ "$(uci -q get ${CONF}.${SECTION}.enabled)"   = "1" ] || exit 0

wan="$(uci -q get ${CONF}.${SECTION}.active_wan)"
[ -n "$wan" ] || exit 0
LOG="/var/log/cake-autorate.${SECTION}.log"
[ -f "$LOG" ] || exit 0

mem_key() { printf 'learned_%s' "$(printf '%s' "$1" | tr -c 'A-Za-z0-9' '_')"; }
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
	[ "$new_max" -gt "$CEILING" ] && new_max="$CEILING"
	[ "$new_max" -lt "$FLOOR" ]   && new_max="$FLOOR"

	delta=$(( new_max - cur_max )); [ "$delta" -lt 0 ] && delta=$(( -delta ))
	[ "$delta" -lt "$(pct "$cur_max" "$DEADBAND")" ] && continue

	uci -q set ${CONF}.${SECTION}.max_${dir}_shaper_rate_kbps="$new_max"
	uci -q set ${CONF}.${SECTION}.base_${dir}_shaper_rate_kbps="$(pct "$new_max" 85)"
	nm="$(pct "$new_max" 15)"; [ "$nm" -lt "$FLOOR" ] && nm="$FLOOR"
	uci -q set ${CONF}.${SECTION}.min_${dir}_shaper_rate_kbps="$nm"
	changed=1; bounds_changed=1
	logger -t cake-autorate-tune \
		"${dir} on ${wan}: peak ${peak}k, max ${cur_max}k -> ${new_max}k"
done

if [ "$changed" = "1" ]; then
	# The idle threshold must stay at or below the upload minimum or the
	# service refuses to start.
	ulmin="$(uci -q get ${CONF}.${SECTION}.min_ul_shaper_rate_kbps)"
	thr="$(uci -q get ${CONF}.${SECTION}.connection_active_thr_kbps)"
	[ -n "$ulmin" ] && [ -n "$thr" ] && [ "$thr" -gt "$ulmin" ] && \
		uci -q set ${CONF}.${SECTION}.connection_active_thr_kbps="$(pct "$ulmin" 50)"
	uci -q commit ${CONF}
	[ "$bounds_changed" = "1" ] && /etc/init.d/cake-autorate restart >/dev/null 2>&1
fi
