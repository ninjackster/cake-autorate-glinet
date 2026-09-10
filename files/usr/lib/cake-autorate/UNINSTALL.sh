#!/bin/sh
# Remove the cake-autorate port. Stock bash was never touched.
/etc/init.d/cake-autorate stop 2>/dev/null
/etc/init.d/cake-autorate disable 2>/dev/null
sed -i '/gl-wan-follow/d' /etc/crontabs/root 2>/dev/null && /etc/init.d/cron restart >/dev/null 2>&1
rm -f /etc/hotplug.d/iface/99-cake-autorate
rm -f /etc/init.d/cake-autorate
rm -f /etc/config/cake-autorate
rm -rf /usr/lib/cake-autorate
rm -f /usr/bin/bash5
rm -rf /tmp/cake-autorate /var/log/cake-autorate.*.log /var/lock/cake-wan-follow.lock

# Deleting the UCI section is not enough. Without a restart, sqm-scripts leaves
# the cake qdisc and the ifb device in place until reboot, so a user who removed
# this because shaping cost them throughput would keep paying for it.
if [ "$(uci -q get sqm.autorate)" = "queue" ]; then
	uci -q delete sqm.autorate
	uci -q commit sqm
	/etc/init.d/sqm restart >/dev/null 2>&1
fi

echo "removed. /bin/bash untouched:"
bash --version | head -1
