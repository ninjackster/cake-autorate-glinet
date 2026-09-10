#!/bin/sh
# install.sh -- (re)install the cake-autorate port. Idempotent; safe to re-run.
#
# Run this ON the router, from a directory containing the files/ tree:
#   tar cf - . | ssh root@ROUTER 'mkdir -p /tmp/ca && tar xf - -C /tmp/ca && sh /tmp/ca/install.sh'
#
# bash5 is not in this repo (no binaries are redistributed here). It is found
# in this order: an argument, an existing /usr/bin/bash5 preserved across a
# sysupgrade, or ./bash5 beside this script.

set -e
SRC="$(dirname "$0")"
BASH5="$1"

say() { echo "  $*"; }

# --- Refuse to clobber a vendor build -------------------------------------
# If GL ships cake-autorate for this model, theirs is the one to use. Ours
# would overwrite their init script and launcher with patched copies.
if [ -f /usr/lib/cake-autorate/cake-autorate.sh ] && \
   [ ! -f /usr/lib/cake-autorate/gl-wan-follow.sh ]; then
	echo "A cake-autorate install is already present that this port did not create."
	echo "It is probably GL's own. Use theirs, or remove it first. Nothing changed."
	exit 1
fi
if bash --version 2>/dev/null | head -1 | grep -qE 'version [5-9]\.'; then
	say "note: /bin/bash is already 5.x, so bash5 may be unnecessary here."
fi

# --- bash 5 ----------------------------------------------------------------
if [ -n "$BASH5" ] && [ -f "$BASH5" ]; then
	cp "$BASH5" /usr/bin/bash5
elif [ -x /usr/bin/bash5 ]; then
	say "bash5 already present (preserved across upgrade), keeping it"
elif [ -f "$SRC/bash5" ]; then
	cp "$SRC/bash5" /usr/bin/bash5
else
	echo "bash5 not found. Extract it from a GL 4.11 image:"
	echo "  unsquashfs -d rootfs sysupgrade-glinet_gl-mt6000/root /bin/bash"
	echo "then re-run: install.sh /path/to/bash"
	exit 1
fi
chmod 755 /usr/bin/bash5
/usr/bin/bash5 -c 'echo "  bash5 ok: $BASH_VERSION, EPOCHREALTIME=${EPOCHREALTIME:-MISSING}"'

# --- upstream scripts ------------------------------------------------------
# These come from the GL firmware image, not this repo. If they are missing,
# say so plainly rather than installing a half-working tree.
for f in cake-autorate.sh defaults.sh lib.sh; do
	if [ ! -f "/usr/lib/cake-autorate/$f" ] && [ ! -f "$SRC/upstream/$f" ]; then
		echo "missing /usr/lib/cake-autorate/$f"
		echo "Copy the three stock scripts (cake-autorate.sh, defaults.sh, lib.sh)"
		echo "from the GL 4.11 rootfs into $SRC/upstream/ and re-run."
		exit 1
	fi
	[ -f "$SRC/upstream/$f" ] && cp "$SRC/upstream/$f" /usr/lib/cake-autorate/$f
done

# --- this repo's files -----------------------------------------------------
mkdir -p /usr/lib/cake-autorate /etc/hotplug.d/iface /etc/gl-switch.d \
         /usr/lib/lua/luci/controller /usr/lib/lua/luci/model/cbi /usr/share/rpcd/acl.d
tar cf - -C "$SRC/files" . | tar xf - -C /
chmod 755 /usr/lib/cake-autorate/*.sh /etc/init.d/cake-autorate \
          /etc/hotplug.d/iface/99-cake-autorate
[ -f /etc/gl-switch.d/autorate.sh ] && chmod 755 /etc/gl-switch.d/autorate.sh
chown -R root:root /usr/lib/cake-autorate /etc/init.d/cake-autorate \
          /etc/hotplug.d/iface/99-cake-autorate /usr/bin/bash5
sed -i '1{/^#!/s|.*|#!/usr/bin/bash5|}' /usr/lib/cake-autorate/cake-autorate.sh \
          /usr/lib/cake-autorate/defaults.sh /usr/lib/cake-autorate/lib.sh \
          /usr/lib/cake-autorate/launcher.sh
say "files installed"

# --- config (preserved across sysupgrade, so only seed when absent) --------
if [ ! -f /etc/config/cake-autorate ]; then
	touch /etc/config/cake-autorate
	uci -q batch <<-UCI
		set cake-autorate.wan=cake_autorate
		set cake-autorate.wan.enabled=0
		set cake-autorate.wan.wan_follow=1
		set cake-autorate.wan.min_dl_shaper_rate_kbps=5000
		set cake-autorate.wan.base_dl_shaper_rate_kbps=40000
		set cake-autorate.wan.max_dl_shaper_rate_kbps=60000
		set cake-autorate.wan.min_ul_shaper_rate_kbps=5000
		set cake-autorate.wan.base_ul_shaper_rate_kbps=38000
		set cake-autorate.wan.max_ul_shaper_rate_kbps=55000
		set cake-autorate.wan.connection_active_thr_kbps=800
		set cake-autorate.wan.pinger_method=fping
		set cake-autorate.wan.no_pingers=4
		set cake-autorate.wan.reflector_ping_interval_s=0.3
		set cake-autorate.wan.dl_owd_delta_delay_thr_ms=30.0
		set cake-autorate.wan.ul_owd_delta_delay_thr_ms=30.0
		commit cake-autorate
	UCI
	say "seeded default config"
else
	say "existing config kept (enabled=$(uci -q get cake-autorate.wan.enabled))"
fi

# --- cron safety net (hotplug cannot see a modem with no netifd interface) --
grep -q gl-wan-follow /etc/crontabs/root 2>/dev/null || \
	echo "* * * * * /usr/lib/cake-autorate/gl-wan-follow.sh" >> /etc/crontabs/root
/etc/init.d/cron restart >/dev/null 2>&1 || true

# --- survive the next sysupgrade -------------------------------------------
touch /etc/sysupgrade.conf
for p in /usr/bin/bash5 /usr/lib/cake-autorate/ /etc/init.d/cake-autorate \
         /etc/hotplug.d/iface/99-cake-autorate /etc/gl-switch.d/autorate.sh \
         /usr/lib/lua/luci/controller/cakeautorate.lua \
         /usr/lib/lua/luci/model/cbi/cakeautorate.lua \
         /usr/share/rpcd/acl.d/luci-app-cakeautorate.json; do
	grep -qxF "$p" /etc/sysupgrade.conf || echo "$p" >> /etc/sysupgrade.conf
done
say "added to /etc/sysupgrade.conf (kept on 'keep settings' upgrades)"

# --- physical switch (GL devices with one) ----------------------------------
# Only claim the switch if it is unassigned. Overwriting an existing binding
# would silently take away whatever the user had put there.
if [ -f /etc/config/switch-button ] && [ -f /etc/gl-switch.d/autorate.sh ]; then
	cur="$(uci -q get switch-button.@main[0].func)"
	if [ -z "$cur" ]; then
		uci -q set switch-button.@main[0].func=autorate
		uci -q commit switch-button
		say "switch bound to autorate (it was unassigned)"
	elif [ "$cur" = "autorate" ]; then
		say "switch already bound to autorate"
	else
		say "switch left alone (currently '$cur'); set func=autorate to use it"
	fi
fi

# --- refresh LuCI ----------------------------------------------------------
rm -f /tmp/luci-indexcache* 2>/dev/null || true
/etc/init.d/rpcd restart >/dev/null 2>&1 || true
/etc/init.d/uhttpd restart >/dev/null 2>&1 || true

# --- restore running state -------------------------------------------------
if [ "$(uci -q get cake-autorate.wan.enabled)" = "1" ]; then
	/usr/lib/cake-autorate/gl-autorate-ctl.sh on
else
	say "installed, currently disabled"
fi

echo
/usr/lib/cake-autorate/gl-autorate-ctl.sh status
