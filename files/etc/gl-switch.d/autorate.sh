#!/bin/sh
# autorate.sh -- physical switch handler for adaptive shaping.
#
# GL's /etc/rc.button/switch dispatches to /etc/gl-switch.d/<func>.sh with
# "on" or "off", where <func> is switch-button.@main[0].func. Setting that to
# "autorate" makes the Mudi's slide switch toggle cake-autorate.
#
# GPL-2.0, matching cake-autorate itself.

action="$1"
CTL=/usr/lib/cake-autorate/gl-autorate-ctl.sh

[ -x "$CTL" ] || {
	logger -t gl-switch-autorate "$CTL missing; nothing to toggle"
	exit 0
}

# rc.button/switch already called screen_disp_switch, which shows the generic
# "Toggle Button" for a func it does not know about. Replace it with something
# meaningful. mcu_send_message is not used: it only does anything on an e750,
# which writes to /dev/ttyS0. On the e5800 the screen is driven over ubus.
screen() {
	[ -e /proc/gl-hw-info/screen ] || return 0
	ubus call gl_screen set \
		"{\"method\": \"switch\", \"params\": { \"enable\": $1, \"mode\": \"$2\", \"sub_func\": \"\"}}" \
		>/dev/null 2>&1
}

case "$action" in
on)
	screen true "SQM Autorate"
	if out="$("$CTL" on 2>&1)"; then
		logger -t gl-switch-autorate "$out"
		# Report what it actually landed on rather than just "on": which
		# device is being shaped is the non-obvious part on a travel router.
		dev="$(uci -q get cake-autorate.wan.active_wan)"
		screen true "Autorate: ${dev:-on}"
	else
		logger -t gl-switch-autorate "failed to enable: $out"
		screen true "Autorate failed"
	fi
	;;
off)
	screen false "SQM Autorate"
	"$CTL" off >/dev/null 2>&1
	logger -t gl-switch-autorate "disabled via switch"
	;;
*)
	logger -t gl-switch-autorate "unknown action: $action"
	exit 1
	;;
esac
