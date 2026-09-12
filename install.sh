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

# --- Preflight -------------------------------------------------------------
# The bash we install is an aarch64 musl binary lifted from GL's own 4.11 image.
# Checking that here turns "it installed but nothing runs" into one clear line.
arch="$(uname -m 2>/dev/null)"
case "$arch" in
	aarch64) ;;
	*) echo "this port installs an aarch64 binary; this device reports '$arch'."
	   echo "Nothing was changed."; exit 1 ;;
esac

[ -e /lib/ld-musl-aarch64.so.1 ] || {
	echo "no /lib/ld-musl-aarch64.so.1: this firmware is not musl-linked aarch64."
	echo "Nothing was changed."; exit 1
}

# The three libraries the vendor bash is linked against. Missing any of them
# means it installs and then fails to exec, which is a confusing way to fail.
for lib in libncursesw.so.6 libgcc_s.so.1 libc.so; do
	[ -e "/lib/$lib" ] || [ -e "/usr/lib/$lib" ] || {
		echo "missing $lib, which the vendor bash needs. Nothing was changed."
		exit 1
	}
done

# bash5 is ~1MB and the scripts are small; 4MB is comfortable headroom.
free_kb="$(df -k /overlay 2>/dev/null | awk 'NR==2{print $4}')"
# An `x && { ... }` here would leave a false test as the block's exit status,
# which under `set -e` aborts the installer on a perfectly healthy device.
case "$free_kb" in
	''|*[!0-9]*) : ;;  # unknown, do not block on it
	*)
		if [ "$free_kb" -lt 4096 ]; then
			echo "only ${free_kb}KB free on /overlay; need about 4MB. Nothing was changed."
			exit 1
		fi
		;;
esac

# --- Refuse to clobber a vendor build -------------------------------------
# If GL ships cake-autorate for this model, theirs is the one to use. Ours
# would overwrite their init script and launcher with patched copies.
# Keying this off "does gl-wan-follow.sh exist" was wrong: after a firmware
# upgrade that ships GL's own cake-autorate, sysupgrade.conf restores our files,
# so it exists, the guard passes, and we overwrite GL's launcher and init script
# with patched copies. Key off provenance instead. Every file this port vendors
# carries an "Origin: GL.iNet firmware" header; GL's own shipped copies do not.
if [ -f /etc/init.d/cake-autorate ] && \
   ! grep -q 'Origin: GL.iNet firmware' /etc/init.d/cake-autorate 2>/dev/null; then
	echo "/etc/init.d/cake-autorate exists but was not installed by this port."
	echo "That almost certainly means GL now ships cake-autorate for this model."
	echo "Theirs is the one to use. Run UNINSTALL.sh first if you want ours."
	echo "Nothing changed."
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
		set cake-autorate.wan.output_load_stats=1
		commit cake-autorate
	UCI
	say "seeded default config"
else
	say "existing config kept (enabled=$(uci -q get cake-autorate.wan.enabled))"
fi

# --- migration: the tuner needs cake-autorate's LOAD lines ------------------
# gl-autorate-tune.sh reads achieved throughput from the LOAD lines, which are
# only emitted when output_load_stats is on. Without it peak_for() returns
# nothing and auto-tune silently does nothing at all. The config above is
# deliberately preserved across upgrades, so seeding it there does not reach an
# existing install. Add it when it is absent, and leave an explicit 0 alone in
# case someone turned it off on purpose.
if [ -f /etc/config/cake-autorate ] && [ -z "$(uci -q get cake-autorate.wan.output_load_stats)" ]; then
	uci -q set cake-autorate.wan.output_load_stats=1
	uci -q commit cake-autorate
	say "enabled output_load_stats (required by the tuner)"
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
