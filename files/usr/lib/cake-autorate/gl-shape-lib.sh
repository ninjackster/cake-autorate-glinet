# gl-shape-lib.sh -- shared WAN resolution and shaping-target selection.
# Sourced by gl-wan-follow.sh, gl-autorate-ctl.sh and gl-autorate-tune.sh.

CONF=cake-autorate
SECTION=wan

# The active uplink, from the routing table rather than ubus, because a GL
# cellular modem has no netifd network.interface at all.
wan_dev() {
	ip route show default 2>/dev/null | awk '
		{ d = ""; m = 0
		  for (i = 1; i <= NF; i++) {
			if ($i == "linkdown") next
			if ($i == "dev")      d = $(i+1)
			if ($i == "metric")   m = $(i+1)
		  }
		  if (d == "") next
		  # Never follow a tunnel: shaping it would leave the physical uplink
		  # underneath, which is the real bottleneck, unshaped.
		  if (d ~ /^(wg|tun|ovpn|tailscale|ipsec|gre|sit)/) next
		  if (best == "" || m+0 < bm+0) { best = d; bm = m }
		}
		END { print best }'
}

# Qualcomm modem interfaces sit on the IPA hardware data path and use
# rmnet_sch. Putting cake on the root qdisc and redirecting ingress to an IFB
# takes the link down, so these are shaped via the LAN bridge instead.
is_modem() {
	case "$1" in
		rmnet*|wwan*|usb*|qmimux*|ccmni*) return 0 ;;
	esac
	return 1
}

# Matches ifb_name() in /usr/lib/sqm/functions.sh byte for byte.
ifb_name() { printf 'ifb4%s' "$1" | cut -c1-15; }

lan_dev() {
	local d
	d="$(uci -q get network.lan.device)"
	[ -n "$d" ] || d="br-lan"
	printf '%s' "$d"
}

# Which device do we actually put cake on?
#   wan    -> the uplink itself. Accurate, and per-uplink.
#   bridge -> the LAN bridge. The only safe option for a modem uplink, and
#             what GL's own stock SQM config uses on this hardware.
shape_target() {
	local dev="$1" mode
	mode="$(uci -q get ${CONF}.${SECTION}.shape_mode)"
	[ -n "$mode" ] || mode=auto
	case "$mode" in
		bridge) printf 'bridge' ;;
		wan)    printf 'wan' ;;
		*)      if is_modem "$dev"; then printf 'bridge'; else printf 'wan'; fi ;;
	esac
}

# Resolve a target into the four values everything else needs.
#
# DIRECTION INVERSION, the part that is easy to get backwards:
#   On the WAN device      egress  = upload,   ingress(IFB) = download
#   On the LAN bridge      egress  = DOWNLOAD, ingress(IFB) = UPLOAD
# because traffic leaving br-lan is heading to the LAN clients, i.e. it is
# what the internet sent us. So in bridge mode the roles swap, and sqm's
# own download/upload options have to be swapped with them.
#
# Sets: SHAPE_IF, CA_DL_IF, CA_UL_IF, SQM_DOWNLOAD_IS, SQM_UPLOAD_IS
resolve_shaping() {
	local dev="$1" target="$2" lan
	if [ "$target" = "bridge" ]; then
		lan="$(lan_dev)"
		SHAPE_IF="$lan"
		CA_DL_IF="$lan"                 # egress on the bridge = download
		CA_UL_IF="$(ifb_name "$lan")"   # ingress on the bridge = upload
		SQM_DOWNLOAD_IS=ul              # sqm 'download' (ingress) carries upload
		SQM_UPLOAD_IS=dl                # sqm 'upload' (egress) carries download
	else
		SHAPE_IF="$dev"
		CA_DL_IF="$(ifb_name "$dev")"
		CA_UL_IF="$dev"
		SQM_DOWNLOAD_IS=dl
		SQM_UPLOAD_IS=ul
	fi
}

# Write sqm.autorate for the resolved target, honouring the inversion.
write_sqm() {
	local base_dl base_ul dl_rate ul_rate
	base_dl="$(uci -q get ${CONF}.${SECTION}.base_dl_shaper_rate_kbps)"
	base_ul="$(uci -q get ${CONF}.${SECTION}.base_ul_shaper_rate_kbps)"
	[ "$SQM_DOWNLOAD_IS" = "dl" ] && dl_rate="$base_dl" || dl_rate="$base_ul"
	[ "$SQM_UPLOAD_IS"   = "ul" ] && ul_rate="$base_ul" || ul_rate="$base_dl"

	uci -q set sqm.autorate=queue
	uci -q set sqm.autorate.interface="$SHAPE_IF"
	uci -q set sqm.autorate.enabled=1
	uci -q set sqm.autorate.qdisc=cake
	uci -q set sqm.autorate.script=piece_of_cake.qos
	uci -q set sqm.autorate.qdisc_advanced=0
	uci -q set sqm.autorate.linklayer=none
	uci -q set sqm.autorate.download="$dl_rate"
	uci -q set sqm.autorate.upload="$ul_rate"
	uci -q commit sqm
}

# Both the follower and the tuner write these bounds. They used to derive them
# independently and drifted: the follower skipped the floor and never touched
# the idle threshold, so a restored slow uplink could leave
# connection_active_thr_kbps above min_ul, and cake-autorate then exits at
# startup. Deriving them in one place is the fix.
CEILING_KBPS=1000000     # 1 Gbit sanity cap
FLOOR_KBPS=2000          # smallest sensible ceiling
MIN_FLOOR_KBPS=500       # smallest sensible floor
LOCK_FILE=/var/lock/cake-wan-follow.lock

# Bounded wait for the shared lock. busybox flock has only -s -x -u -n, so a
# timeout has to be a retry loop. Callers must have opened fd 9 themselves.
take_lock() {
	local waited=0 limit="${1:-60}"
	while ! flock -n 9
	do
		waited=$((waited + 1))
		[ "$waited" -ge "$limit" ] && return 1
		sleep 1
	done
	return 0
}

# The idle threshold must stay at or below the upload minimum or the service
# exits at startup. Every path that lowers min_ul has to call this.
clamp_active_thr() {
	local ulmin thr
	ulmin="$(uci -q get ${CONF}.${SECTION}.min_ul_shaper_rate_kbps)"
	thr="$(uci -q get ${CONF}.${SECTION}.connection_active_thr_kbps)"
	[ -n "$ulmin" ] && [ -n "$thr" ] || return 0
	[ "$thr" -le "$ulmin" ] && return 0
	uci -q set ${CONF}.${SECTION}.connection_active_thr_kbps=$(( ulmin / 2 ))
}

# Derive base and min from a ceiling and write all three, preserving
# min <= base <= max. Flooring min without also checking it against base is how
# a low ceiling used to produce min > base.
set_bounds() {
	local dir="$1" mx="$2" base mn
	[ -n "$mx" ] || return 1
	[ "$mx" -gt "$CEILING_KBPS" ] && mx="$CEILING_KBPS"
	[ "$mx" -lt "$FLOOR_KBPS" ]   && mx="$FLOOR_KBPS"
	base=$(( mx * 85 / 100 ))
	mn=$(( mx * 15 / 100 ))
	[ "$mn" -lt "$MIN_FLOOR_KBPS" ] && mn="$MIN_FLOOR_KBPS"
	[ "$mn" -gt "$base" ] && mn="$base"
	uci -q set ${CONF}.${SECTION}.max_${dir}_shaper_rate_kbps="$mx"
	uci -q set ${CONF}.${SECTION}.base_${dir}_shaper_rate_kbps="$base"
	uci -q set ${CONF}.${SECTION}.min_${dir}_shaper_rate_kbps="$mn"
}
