#!/bin/sh
# gl-autorate-ctl.sh {on|off|status} -- one command to turn adaptive shaping
# on or off.
#
# cake-autorate only ADJUSTS an existing cake qdisc; it never creates one. So
# turning it on means provisioning an SQM queue as well, which is what makes
# this a two-part operation rather than a single toggle.

. /usr/lib/cake-autorate/gl-shape-lib.sh

do_on() {
	dev="$(wan_dev)"
	# return, not exit: do_toggle calls this, and an exit here would kill the
	# whole script so the toggle printed nothing at all.
	[ -n "$dev" ] || { echo "no usable WAN (no default route)"; return 1; }
	target="$(shape_target "$dev")"
	resolve_shaping "$dev" "$target"

	uci -q set ${CONF}.${SECTION}=cake_autorate
	uci -q set ${CONF}.${SECTION}.active_wan="$dev"
	uci -q set ${CONF}.${SECTION}.ul_if="$CA_UL_IF"
	uci -q set ${CONF}.${SECTION}.dl_if="$CA_DL_IF"
	uci -q set ${CONF}.${SECTION}.enabled=1
	uci -q set ${CONF}.${SECTION}.wan_follow=1
	# The tuner derives bounds from the rates actually applied, which are only
	# written to the log when this is on.
	[ "$(uci -q get ${CONF}.${SECTION}.auto_tune)" = "1" ] && \
		uci -q set ${CONF}.${SECTION}.output_cake_changes=1
	uci -q commit ${CONF}

	write_sqm
	# Only bounce sqm when its config moved or the qdisc is gone; restarting it
	# rebuilds the qdisc and interrupts traffic. 9>&- on every service call:
	# this function runs holding the lock on fd 9, and a daemon that inherits
	# it would hold the lock forever and permanently block the follower.
	[ "$SQM_CHANGED" = "1" ] && /etc/init.d/sqm restart >/dev/null 2>&1 9>&-
	/etc/init.d/cake-autorate enable >/dev/null 2>&1 9>&-
	restart_autorate
	echo "on: uplink ${dev}, shaping ${SHAPE_IF} (${target} mode)"
}

do_off() {
	/etc/init.d/cake-autorate stop >/dev/null 2>&1 9>&-
	/etc/init.d/cake-autorate disable >/dev/null 2>&1 9>&-
	uci -q set ${CONF}.${SECTION}.enabled=0
	uci -q commit ${CONF}
	# Deleting the section is not enough: sqm-scripts leaves the qdisc and the
	# ifb device in place until it is restarted.
	if [ "$(uci -q get sqm.autorate)" = "queue" ]; then
		uci -q delete sqm.autorate
		uci -q commit sqm
		/etc/init.d/sqm restart >/dev/null 2>&1 9>&-
	fi
	echo "off"
}

do_toggle() {
	# Single entry point for anything that has one button to spend. Prints one
	# human-readable line, so a caller with a notification to fill needs no
	# second round trip and no parsing.
	if [ "$(uci -q get ${CONF}.${SECTION}.enabled)" = "1" ]; then
		do_off >/dev/null 2>&1
		echo "Autorate OFF"
	else
		if ! do_on >/dev/null 2>&1; then
			echo "Autorate could not start: no usable WAN"
			return 1
		fi
		# the shaper needs a moment to come up before it can be reported
		i=0
		while [ "$i" -lt 10 ]; do
			/etc/init.d/cake-autorate running >/dev/null 2>&1 && break
			i=$((i + 1)); sleep 1
		done
		dev="$(uci -q get ${CONF}.${SECTION}.active_wan)"
		shp="$(uci -q get sqm.autorate.interface)"
		dl="$(uci -q get ${CONF}.${SECTION}.dl_if)"
		ul="$(uci -q get ${CONF}.${SECTION}.ul_if)"
		dlr="$(tc qdisc show dev "$dl" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1 | cut -d' ' -f2)"
		ulr="$(tc qdisc show dev "$ul" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1 | cut -d' ' -f2)"
		if /etc/init.d/cake-autorate running >/dev/null 2>&1; then
			echo "Autorate ON via ${dev:-?} (shaping ${shp:-?}) ${dlr:-?} down / ${ulr:-?} up"
		else
			echo "Autorate failed to start on ${dev:-?}"
		fi
	fi
}

do_status() {
	dev="$(uci -q get ${CONF}.${SECTION}.active_wan)"
	dl="$(uci -q get ${CONF}.${SECTION}.dl_if)"
	ul="$(uci -q get ${CONF}.${SECTION}.ul_if)"
	echo "enabled:   $(uci -q get ${CONF}.${SECTION}.enabled)"
	echo "uplink:    ${dev:-none}"
	echo "mode:      $(uci -q get ${CONF}.${SECTION}.shape_mode 2>/dev/null || echo auto)"
	echo "shaping:   $(uci -q get sqm.autorate.interface 2>/dev/null || echo none)"
	echo "running:   $(/etc/init.d/cake-autorate running 2>/dev/null && echo yes || echo no)"
	[ -n "$dl" ] && echo "download:  $(tc qdisc show dev "$dl" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1)"
	[ -n "$ul" ] && echo "upload:    $(tc qdisc show dev "$ul" 2>/dev/null | grep -o 'bandwidth [0-9A-Za-z]*' | head -1)"
}

# Entry point owns the lock. The follower and the tuner write the same UCI
# config and restart the same service, and this is reachable from an HTTP
# endpoint, a button handler and ssh, so an unlocked write here is a real
# lost-update race. The work functions above assume the lock is already held
# and never re-exec, which is what keeps toggle from deadlocking on itself.
case "$1" in
	on|off|toggle)
		exec 9>"$LOCK_FILE"
		take_lock 60 || { echo "busy: another change is in progress"; exit 1; }
		;;
esac

case "$1" in
	on)     do_on || exit 1 ;;
	off)    do_off ;;
	toggle) do_toggle ;;
	status) do_status ;;       # read-only, no lock needed
	*)      echo "usage: $0 {on|off|toggle|status}"; exit 1 ;;
esac
