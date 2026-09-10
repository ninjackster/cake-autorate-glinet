# Running cake-autorate on a GL.iNet router that has not been given firmware 4.11

GL.iNet added SQM autorate to their 4.11 firmware, but only for the Flint 2 (MT6000) and Beryl AX (MT3000). Every other model is waiting, with no announced date. The usual answer is that you cannot install cake-autorate yourself, because GL's firmware ships bash 3.2 and cake-autorate needs `EPOCHREALTIME`, which arrived in bash 5.0.

That answer is wrong, and the fix is sitting inside GL's own firmware image.

Done here on a Mudi 7 (GL-E5800, Qualcomm SDXPINN, firmware 4.10.0, OpenWrt 23.05 base).

## The obvious thing first, so you can skip the rest if it works

Try the package feed before extracting anything:

```sh
opkg update && opkg install bash && bash --version
```

If that gives you 5.x, stop reading and go straight to [Configuration](#configuration). On the Mudi 7 it does not, because GL points the device only at their own servers and the only bash they publish for this platform is the ancient one:

```
# opkg list | grep '^bash '
bash - 3.2.57-1

# feeds configured
glinet_core
glinet_gli_packages
glinet_gli_pub
```

No upstream OpenWrt feed, one bash, and it is the wrong one. Hence everything below.

## What GL actually did

I pulled apart `mt6000-4.11.0_beta1`. It is an OpenWrt sysupgrade tar holding an xz-compressed squashfs 4.0:

```sh
tar -xf mt6000-4.11.0_beta1-*.bin
unsquashfs -d rootfs sysupgrade-glinet_gl-mt6000/root
```

What comes out:

```
/usr/lib/cake-autorate/cake-autorate.sh   cake_autorate_version="3.3.0-PRERELEASE"
/bin/bash                                 GNU bash 5.1.4(1)
```

GL did not patch cake-autorate. They did not work around `EPOCHREALTIME`, which still appears 9 times in the shipped scripts. They took stock upstream [lynxthecat/cake-autorate](https://github.com/lynxthecat/cake-autorate) and shipped a modern bash next to it.

Everything GL wrote themselves is glue: a procd wrapper at `/etc/init.d/cake-autorate` and a `launcher.sh` that turns UCI options into a config file. It is all generic OpenWrt, using `uci`, `ubus` and `jsonfilter`. There is nothing MT6000-specific in any of it.

So the port is mostly a file copy. The interesting work is in the two places their glue assumes a router that does not move.

## Why GL's bash binary runs on a different model

Cross-flashing the MT6000 image would brick a Qualcomm device, but nothing here needs the kernel. The bash binary is `aarch64`, dynamically linked against `/lib/ld-musl-aarch64.so.1`, and its three dependencies were already present on the target:

```
NEEDED: libncursesw.so.6, libgcc_s.so.1, libc.so
RPATH/RUNPATH: none
```

This should hold for other aarch64 GL models **on the OpenWrt 23.05 base**, which is 4.5 and later. Do not assume it for early 4.x: those are built on 21.02 against musl 1.1, and a binary linked against musl 1.2 is not guaranteed to resolve there. Check `cat /etc/openwrt_release` first.

Check the rest before copying anything:

```sh
uname -m                                   # expect aarch64
ls -l /lib/ld-musl-aarch64.so.1
for l in libncursesw.so.6 libgcc_s.so.1 libc.so; do ls /lib/$l /usr/lib/$l 2>/dev/null; done
which fping
tc qdisc add dev lo root cake && tc qdisc del dev lo root && echo "cake ok"
```

Nothing in this procedure can brick or soft-lock a router. The kernel is untouched, `/bin/bash` is untouched, and every file added is removed by the uninstaller.

On the Mudi 7 all of it passed, and the binary ran first try:

```
GNU bash, version 5.1.4(1)-release (aarch64-openwrt-linux-gnu)
EPOCHREALTIME             1789019948.999055
mapfile/procsub/nameref   ok:2
lib.sh sleep idiom        elapsed_us=200371     (0.37ms overhead on a 200ms sleep)
```

That last line matters more than it looks. cake-autorate's timing loop is the algorithm, so a slow clock source would defeat the point. 0.37ms of overhead is fine.

## Install bash side by side, not over the top

GL replaces `/bin/bash` outright. Do not copy that. On the MT6000 every GL script was built and tested against 5.1.4. On your model they were built against 3.2, and that is a fourteen year gap in shell behavior introduced underneath vendor code you cannot see, including whatever watchdogs and helpers your firmware runs.

Install it as `/usr/bin/bash5` and pin the shebangs instead. It costs 1MB and the stock shell stays exactly as it was.

```sh
# from the extracted 4.11 rootfs, on your workstation
cat rootfs/bin/bash | ssh root@ROUTER 'cat > /usr/bin/bash5 && chmod 755 /usr/bin/bash5'

cd rootfs/usr/lib/cake-autorate
tar cf - *.sh | ssh root@ROUTER 'mkdir -p /usr/lib/cake-autorate &&
  tar xf - -C /usr/lib/cake-autorate &&
  chmod 755 /usr/lib/cake-autorate/*.sh &&
  chown -R root:root /usr/lib/cake-autorate &&
  sed -i "1{/^#!/s|.*|#!/usr/bin/bash5|}" /usr/lib/cake-autorate/*.sh'
```

Two details that cost me time. `chown`, because files moved with tar arrive owned by your workstation's uid. And the `1{/^#!/...}` guard on the sed, so it rewrites line 1 only when line 1 is actually a shebang.

Then install this repo's files over the top, which replaces GL's `launcher.sh` and `init.d` with the patched versions and adds the WAN follower:

```sh
cd files
tar cf - . | ssh root@ROUTER 'tar xf - -C / &&
  chmod 755 /usr/lib/cake-autorate/*.sh /etc/init.d/cake-autorate \
            /etc/hotplug.d/iface/99-cake-autorate &&
  chown -R root:root /usr/lib/cake-autorate /etc/init.d/cake-autorate \
            /etc/hotplug.d/iface/99-cake-autorate'
```

Verify before going further:

```sh
for f in /usr/lib/cake-autorate/cake-autorate.sh /usr/lib/cake-autorate/defaults.sh \
         /usr/lib/cake-autorate/lib.sh /usr/lib/cake-autorate/launcher.sh; do
  /usr/bin/bash5 -n "$f" || echo "FAILED $f"
done
for f in /usr/lib/cake-autorate/gl-wan-follow.sh /etc/init.d/cake-autorate \
         /etc/hotplug.d/iface/99-cake-autorate; do
  sh -n "$f" || echo "FAILED $f"
done
```

## Prove it works before it touches your traffic

Do not debug a shaper on the link you are using. Give it two throwaway interfaces and let it run against those:

```sh
ip link add ca-ul type dummy; ip link add ca-dl type dummy
ip link set ca-ul up; ip link set ca-dl up
tc qdisc replace dev ca-ul root cake bandwidth 20Mbit
tc qdisc replace dev ca-dl root cake bandwidth 20Mbit

mkdir -p /tmp/cake-autorate
cat > /tmp/cake-autorate/config.test.sh <<'EOF'
dl_if=ca-dl
ul_if=ca-ul
min_dl_shaper_rate_kbps=5000
base_dl_shaper_rate_kbps=20000
max_dl_shaper_rate_kbps=80000
min_ul_shaper_rate_kbps=5000
base_ul_shaper_rate_kbps=20000
max_ul_shaper_rate_kbps=35000
pinger_method=fping
output_cake_changes=1
output_summary_stats=1
log_file_path_override=/tmp/cake-autorate
EOF

/usr/lib/cake-autorate/cake-autorate.sh /tmp/cake-autorate/config.test.sh &
pid=$!
sleep 25
kill "$pid"
```

Capture the pid rather than using `kill %1`, which only works in an interactive shell and fails with "no such job" the moment you paste this into a script.

You are looking for real qdisc writes in the log, not just a clean startup:

```
SHAPER; tc qdisc change root dev ca-dl cake bandwidth 17279Kbit
```

then confirm the kernel took it:

```sh
tc qdisc show dev ca-dl        # bandwidth 17279Kbit
```

Clean up with `ip link del ca-ul; ip link del ca-dl`.

## The part GL's glue gets wrong on a travel router

GL's code assumes one fixed WAN. Stock SQM on the MT6000 is `interface 'eth1'`, a single wired uplink, and against that assumption their glue is correct. A travel router breaks it in two ways.

**Nothing re-evaluates the WAN.** There is no `procd_add_reload_trigger` in the init script and no `hotplug.d` entry anywhere in the 4.11 image:

```sh
grep -rl 'cake.autorate' etc/hotplug.d usr/share/rpcd usr/libexec    # no hits
```

`section_iface_is_up` runs once at service start. `respawn` restarts on crash, not on a network change. Fail over from repeater to cellular and it keeps shaping an interface that is no longer carrying anything.

**Cellular can never start at all.** GL's `resolve_section_iface` looks the device up through `ubus`, but on a GL modem the interface carrying the default route has no netifd entry:

```
wwan         up=true   dev=wlan4          proto=dhcp     <- resolves
modem_cpu    up=true   dev=rmnet_data1    proto=rmnet
(the default route is on rmnet_data0, which matches nothing)
```

So the gate rejects it and the service quietly does not start, on the exact link GL's own UI marks as recommended for autorate.

### Fixing both

`files/usr/lib/cake-autorate/gl-wan-follow.sh` resolves the live WAN from the routing table instead of from `ubus`, which covers every uplink type uniformly because a default route is a default route:

```awk
{ d = ""; m = 0
  for (i = 1; i <= NF; i++) {
    if ($i == "linkdown") next
    if ($i == "dev")      d = $(i+1)
    if ($i == "metric")   m = $(i+1)
  }
  if (d == "") next
  if (d ~ /^(wg|tun|ovpn|tailscale|ipsec|gre|sit)/) next
  if (best == "" || m+0 < bm+0) { best = d; bm = m }
}
END { print best }
```

Lowest metric wins, because that is the route traffic actually takes. Tunnels are excluded deliberately: if a VPN client puts its default route in the main table, following it would shape the tunnel and silently unshape the physical uplink underneath, which is the actual bottleneck. Resetting `d` and `m` per record matters because otherwise a record without a `dev` inherits the previous one's device and then competes on its own metric. This reads IPv4 only, and on an ECMP route the first nexthop wins.

The script then re-points both SQM and cake-autorate at that device and restarts them.

`files/etc/hotplug.d/iface/99-cake-autorate` fires it on `ifup` and `ifdown`, after a 3 second settle so the routing table is final by the time it looks.

The gate in `init.d/cake-autorate` and `launcher.sh` gets a fallback for the cellular case:

```sh
network_iface_is_up "$iface" && return 0

# Fallback: the device carries the default route but has no netifd
# network.interface. GL cellular modems (rmnet_dataN) are exactly this.
ul_if="$(uci -q get cake-autorate.${section}.ul_if)"
[ -n "$ul_if" ] || return 1
[ -e "/sys/class/net/${ul_if}" ] || return 1
ip route show default dev "$ul_if" 2>/dev/null | grep -q . && return 0
return 1
```

Use `ip route show default dev X` rather than grepping the full route output for `"dev X "`. Grepping interpolates a UCI value into a regex, where a device like `eth0.2` has a wildcard in it, and it depends on iproute2 emitting a trailing space after the device name.

Both patched files are in `files/`, with reviewable diffs against the GL originals in `patches/`.

### Three things the event model still misses

`hotplug.d/iface` only fires for netifd interfaces, and the whole point of the cellular fix is that the modem does not have one. Cellular-only boot, or a modem re-attaching after signal loss, produces no `iface` event at all. `START=97` at boot also runs before the modem has a route.

So there is a once-a-minute safety net, which is cheap because the script exits after two `uci get` calls when nothing has changed:

```sh
echo "* * * * * /usr/lib/cake-autorate/gl-wan-follow.sh" >> /etc/crontabs/root
/etc/init.d/cron restart
```

This only works because the script is idempotent, and getting that right took two attempts. Comparing the resolved device against the last value written to `ul_if` is not enough: when an uplink drops and the *same* one returns, `ul_if` still matches while the service sits stopped, so it would never be restarted. It has to compare against actual service state via `/etc/init.d/cake-autorate running`. Equally, do not compare the SQM interface unconditionally, because while `sqm.autorate` does not exist that comparison never matches and every cron tick restarts the service.

One busybox trap worth flagging: `flock -w` does not exist. Busybox `flock` supports only `-s -x -u -n`, so a bounded wait has to be a retry loop around `flock -n`. Blocking forever is the wrong choice when cron is also calling the script.

Each WAN change writes UCI, which is a write to the overlay. A few per day is nothing, but it is not free.

## Configuration

```sh
touch /etc/config/cake-autorate      # uci set fails with "Entry not found" without this

uci set cake-autorate.wan=cake_autorate
uci set cake-autorate.wan.enabled=1
uci set cake-autorate.wan.wan_follow=1
uci set cake-autorate.wan.ul_if=wlan4
uci set cake-autorate.wan.dl_if=ifb4wlan4
uci set cake-autorate.wan.min_dl_shaper_rate_kbps=2000
uci set cake-autorate.wan.base_dl_shaper_rate_kbps=20000
uci set cake-autorate.wan.max_dl_shaper_rate_kbps=200000
uci set cake-autorate.wan.min_ul_shaper_rate_kbps=1000
uci set cake-autorate.wan.base_ul_shaper_rate_kbps=5000
uci set cake-autorate.wan.max_ul_shaper_rate_kbps=50000
uci set cake-autorate.wan.connection_active_thr_kbps=800
uci commit cake-autorate
```

Set the min and max wide if you move between very different links. Discovering the usable rate is the entire job of the thing.

One validation rule bites immediately: `connection_active_thr_kbps` must not exceed `min_ul_shaper_rate_kbps`. Get it wrong and the script exits at startup with a single line in the log and nothing else.

**cake-autorate adjusts an existing cake qdisc. It never creates one.** SQM has to be shaping the same device or cake-autorate will start, resolve the interface, and sit at `verify_ifs_up` forever:

```sh
uci set sqm.autorate=queue
uci set sqm.autorate.interface=wlan4
uci set sqm.autorate.enabled=1
uci set sqm.autorate.qdisc=cake
uci set sqm.autorate.script=piece_of_cake.qos
uci commit sqm && /etc/init.d/sqm restart

/etc/init.d/cake-autorate enable && /etc/init.d/cake-autorate start
```

The follower derives `dl_if` as `ifb4<dev>` truncated to 15 characters, which is byte for byte what `ifb_name()` in `/usr/lib/sqm/functions.sh` does. Worth re-checking on your own device with `sed -n '/^ifb_name/,/^}/p' /usr/lib/sqm/functions.sh`, since a vendor could patch it. Note that sqm-scripts' own truncation makes `rmnet_data1` and `rmnet_data10` collide, which is not something this repo can fix.

## Turning it on, and a UI to do it with

`cake-autorate` only adjusts an existing cake qdisc, so enabling it is really two operations: provision an SQM queue on the live WAN, then start the service. `gl-autorate-ctl.sh` does both:

```sh
/usr/lib/cake-autorate/gl-autorate-ctl.sh on
/usr/lib/cake-autorate/gl-autorate-ctl.sh off
/usr/lib/cake-autorate/gl-autorate-ctl.sh status
```

`on` resolves the live WAN, writes `ul_if`/`dl_if`, creates the `sqm.autorate` queue seeded from your base rates, and starts everything. `off` tears all of it down, including the sqm restart that actually removes the qdisc.

For a toggle rather than a shell, there is a LuCI page at **Network -> Cake Autorate**, which on GL firmware lives at `http://<router>:8080` alongside the stock admin panel on port 80. It exposes the enable switch, the WAN follower, the six rate fields and the idle threshold, shows which device is currently being shaped and whether the service is up, and calls `gl-autorate-ctl.sh` on save so the SQM side stays in step.

This is a LuCI app, not a port of GL's own 4.11 switch. Their admin panel is a compiled Vue bundle that talks to a version-matched rpcd API; swapping another model's bundle in to gain one toggle is a bad trade. Curiously the strings are already on the device: a Mudi 7 on 4.10 ships `cake_autorate_title` and the rest in `/www/i18n/gl-sdk4-ui-flowstatistics.*.json` because GL builds i18n centrally across models. Only the component that would use them is missing.

LuCI is already installed on GL 4.x firmware. Check before assuming:

```sh
opkg list-installed | grep -c '^luci'      # 24 on a Mudi 7 4.10.0
ls /usr/lib/lua/luci/model/cbi             # luci-compat present means classic CBI works
```

## Bridge mode for modem uplinks

A Qualcomm modem interface cannot be shaped directly. `rmnet` devices sit on the
IPA hardware data path and use `rmnet_sch`, and putting cake on the root qdisc
with an IFB ingress redirect takes the link down. That is not theory: it took a
router offline, and `rmnet`, `wwan`, `usb`, `qmimux` and `ccmni` are excluded
from selection because of it.

GL already solved this and I misread it as a quirk. Their stock SQM config on
this hardware is `interface 'br-lan'`, not the WAN device. Shaping the LAN
bridge works whatever the uplink is.

The catch is that the directions swap, because traffic leaving `br-lan` is
heading to the LAN clients, which is what the internet sent you:

```
WAN device     egress = upload     ifb = download
LAN bridge     egress = DOWNLOAD   ifb = UPLOAD
```

So `sqm`'s own `download` and `upload` options are swapped to match.
`shape_mode` picks the behaviour: `wan`, `bridge`, or `auto` (bridge only when
the uplink is a modem).

**Verified on a cellular uplink.** Configured 140 down / 65 up:

```
measured        147.3 down / 65.7 up      both directions shaped
autorate        140Mbit -> 186219Kbit -> 153839Kbit -> 140Mbit
                (probes up, backs off on delay, decays to base when idle)
our queue       av_delay 4us
modem           root qdisc untouched, 0 ingress redirects, no ifb4rmnet
CPU             86% idle at 165Mbps
```

An earlier attempt to validate this over a repeatered wifi uplink failed and
looked like a bug in bridge mode. It was not: that link was degrading badly
enough to make the measurements worthless. Test shaping changes on a link that
is behaving.

One wrinkle worth knowing: the modem renumbers itself between `rmnet_data0` and
`rmnet_data1` with no change to the link. Two things follow from that. The
follower records the new name and leaves the shaper alone rather than tearing it
down, because in bridge mode the shaped device is `br-lan` either way. And every
modem interface shares a single `learned_modem` memory key, since keying on the
device name would split what it learned across two keys and lose it on every
rename.

## What it actually costs, measured

Measured on a Mudi 7 at ~47 Mbps down / 46 up, from a LAN client so the traffic crossed the router's forwarding path.

**Software flow offloading is not the problem it is said to be.** The common advice is that SQM and offloading are incompatible. On this platform that is false, and it is easy to check rather than believe. Download 50MB through the router and compare it against what cake counted:

```
offload ON    50,000,000 downloaded  ->  cake saw 53,097,541 bytes
offload OFF   50,000,000 downloaded  ->  cake saw 61,308,887 bytes
```

Cake sees the traffic either way. The download path is captured by a `tc ingress` redirect that runs before netfilter, and the flowtable fast path still hands egress packets to the qdisc. The incompatibility applies to *hardware* offload, which on this device is unavailable anyway (`ethtool -k wlan4` reports `hw-tc-offload: off [fixed]`, likewise for the modem and the bridge). Check your own hardware before giving anything up.

**VPNs cost you cake's flow isolation, not its shaping.** Everything inside a tunnel is one encrypted flow to one peer, so cake's per-flow fairness has nothing to separate. Four concurrent downloads, same load both times:

| | direct | via VPN |
|---|---|---|
| sparse flows | 5 | 7 |
| bulk flows | **4** | **1** |

Shaping and the bufferbloat control still work, because total rate is still enforced. What is gone is cake's ability to stop one device or one bulk transfer from starving the others, since it can no longer tell them apart. This was measured through a Tailscale exit node and reproduced with a bonding VPN (`sp_flows 1, bk_flows 1`), and applies equally to any WireGuard tunnel.

**Check where the queue actually is before you bother.** On a repeatered rental wifi link showing over a second of latency under load, shaping changed nothing, because the queue was not ours:

```
tc -s qdisc show dev <wan>   av_delay 243us   pk_delay 1.59ms   backlog 0b
```

Cake's own queue was empty while the link showed a second of delay. A shaper can only control a queue that forms in its own path, and as a wifi client on someone else's AP, it does not. That one command answers "is this queue mine?" and is worth running before changing anything.

## Things worth knowing before you commit

A firmware flash erases all of it. None of this is a package, so nothing survives sysupgrade and nothing will conflict with GL's own build when they eventually ship it. Re-run the port, or delete it and use theirs.

Autorate earns nothing on a stable link. It exists for uplinks whose real capacity moves underneath you: cellular, repeatered hotel and rental wifi, satellite, congested cable at peak. On a steady fiber connection a fixed cake rate is better and cheaper. GL's own UI says the same thing.

Turning on SQM at all costs throughput and CPU. On a fast link the shaper is doing real per-packet work on a router class CPU. That is a separate decision from installing this, and worth measuring on your own hardware.

`ps | grep` will lie to you here. Any command line containing the string "cake-autorate" matches your own grep, including the ssh invocation running it. Count the interpreter instead:

```sh
ls -l /proc/[0-9]*/exe 2>/dev/null | grep -c bash5
```

## Removing it

```sh
/usr/lib/cake-autorate/UNINSTALL.sh
```

Note what the uninstaller has to do beyond deleting files. Dropping the `sqm.autorate` UCI section is not enough on its own, because sqm-scripts leaves the cake qdisc and the ifb device in place until something restarts it. Someone removing this because shaping cost them throughput would otherwise keep paying for it with nothing left in the config to explain why.

Stock `/bin/bash` is never touched, so the shell you started with is the shell you end with.

## Licence

GPL-2.0, matching cake-autorate.

`files/usr/lib/cake-autorate/launcher.sh` and `files/etc/init.d/cake-autorate` originate in GL.iNet's 4.11.0-beta1 firmware for the GL-MT6000. GL's `launcher.sh` is itself a derivative of upstream cake-autorate's `launcher.sh.template`, so it carries that licence. Diffs against the GL originals are in `patches/` so the changes are reviewable in isolation.

No binaries are redistributed here. Extracting bash from a firmware image you downloaded for your own device is your business and stays on your device.

## Credit

cake-autorate is by [lynxthecat](https://github.com/lynxthecat/cake-autorate). The UCI glue and procd wrapper are GL.iNet's. What is mine is the WAN follower, the gate fallback for netifd-less cellular interfaces, and the side by side bash install.
