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
# Achieved-rate samples are monitor_achieved_rates_interval_ms apart (200ms by
# default), so one sample is a 200ms burst, not a capacity. On wifi with frame
# aggregation a single sample reads roughly twice the sustained rate: measured
# against curl on this router, max instantaneous was 140689kbps while the link
# delivered 65688kbps sustained. Averaging across five seconds of samples put
# the estimate at 87018kbps. Peak-of-instantaneous would have reintroduced the
# same over-estimation this function was changed to remove.
SUSTAIN_SAMPLES=25  # 25 x 200ms = 5s

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

# Peak ACHIEVED throughput, per direction, SINCE THE LAST SERVICE START.
#
# Read from cake-autorate's LOAD lines, whose columns are:
#   LOAD; datetime; timestamp; proc_time_us; dl_achieved; ul_achieved; cake_dl; cake_ul
# so field 5 is download and field 6 is upload, in kbps.
#
# Reported as the highest SUSTAINED rate, not the highest single sample: see
# SUSTAIN_SAMPLES above for why a single sample is a burst rather than a
# capacity.
#
# This previously read the SHAPER lines instead, which carry the rate
# cake-autorate APPLIED, not the rate the link DELIVERED. On a link where the
# controller probes above real capacity that number only climbs: the tuner
# recorded its own probe as the "peak", set the ceiling to peak * 1.2, and
# ratcheted upward with nothing anchoring it to reality. It had learned 91Mbit
# of upload on a cellular link that measured 43Mbit, which left the shaper at
# twice the real capacity, so cake was never the bottleneck and the queue formed
# upstream in the carrier where nothing here can touch it.
#
# Bounding to the current run still matters on a travel router: device names are
# reused across completely different networks. The log rotates on size and time,
# and after a rotation the start marker is gone, but every line that remains
# still belongs to the current run, so falling back to the whole file is right.
peak_for() {
	awk -v col="$1" -v K="$SUSTAIN_SAMPLES" -F'; ' '
		/Started cake-autorate/ { n = 0; best = 0; next }
		$1 == "LOAD" {
			buf[n % K] = $col + 0
			n++
			if (n >= K) {
				s = 0
				for (i = 0; i < K; i++) s += buf[i]
				a = s / K
				if (a > best) best = a
			}
		}
		END { if (best > 0) printf "%d\n", best }
	' "$LOG" 2>/dev/null
}

changed=0
bounds_changed=0
for dir in dl ul; do
	iface="$(uci -q get ${CONF}.${SECTION}.${dir}_if)"
	[ -n "$iface" ] || continue

	# LOAD column: 5 is dl_achieved, 6 is ul_achieved.
	case "$dir" in
		dl) col=5 ;;
		ul) col=6 ;;
		*)  continue ;;
	esac

	peak="$(peak_for "$col")"
	[ -n "$peak" ] || continue

	cur_max="$(uci -q get "${CONF}.${SECTION}.max_${dir}_shaper_rate_kbps")"
	# ash turns a non-numeric value into 0 inside $(( )), which would drive
	# new_max to 0 and collapse the ceiling to the floor with nothing logged.
	case "$cur_max" in
		''|*[!0-9]*) continue ;;
	esac

	# Achieved throughput only reports capacity when there was traffic to carry.
	# An idle window peaks near zero, and acting on that would drive the ceiling
	# to the floor and strangle the link. Too little observed load is no data, not
	# a slow link, so skip the run rather than learn from it.
	#
	# This guard has to sit BEFORE the learned value is written, not just before
	# the bounds are moved: gl-wan-follow.sh restores bounds from the learned peak
	# on every uplink change, so an idle sample recorded here would collapse the
	# shaper later even though the tuner itself declined to act on it.
	if [ "$peak" -lt "$(pct "$cur_max" 25)" ]; then
		continue
	fi

	# Record what THIS uplink actually delivered. Recording the applied ceiling
	# instead is what inflated the cellular upload memory to 91Mbit on a 43Mbit
	# link, and recording another link's number is how a 60Mbit wifi ceiling once
	# became the cellular "learned" value.
	if [ "$(uci -q get ${CONF}.$(mem_key "$wan")_${dir})" != "$peak" ]; then
		uci -q set ${CONF}.$(mem_key "$wan")_${dir}="$peak"
		changed=1
	fi

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
