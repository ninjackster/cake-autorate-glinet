#!/bin/sh
# extract-upstream.sh -- pull the four vendor files this port needs out of a
# GL.iNet 4.11 firmware image.
#
#   ./extract-upstream.sh <firmware.bin> [outdir]
#
# Runs on your workstation, NOT on the router: it needs unsquashfs, which
# OpenWrt does not ship. Writes to upstream/ by default, which is where
# install.sh looks.
#
# Nothing is downloaded and nothing is redistributed. You supply an image you
# obtained yourself, and the four files stay on your machine.
#
# GPL-2.0.

set -eu

IMG="${1:-}"
OUT="${2:-upstream}"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "  $*"; }

[ -n "$IMG" ] || cat <<'USAGE' >&2
usage: ./extract-upstream.sh <firmware.bin> [outdir]

You need a GL.iNet 4.11 image for a model that ships cake-autorate. The Flint 2
(mt6000) build is the one this was developed against:

  https://dl.gl-inet.com/  ->  router  ->  mt6000  ->  4.11.x

You do not flash it. Only four files are taken out of it, and only onto this
machine.
USAGE
[ -n "$IMG" ] || exit 2
[ -f "$IMG" ] || die "no such file: $IMG"

command -v unsquashfs >/dev/null 2>&1 || die \
"unsquashfs not found. macOS: brew install squashfs. Debian/Ubuntu: apt install squashfs-tools."

# sha256 tool differs between macOS and Linux
if command -v sha256sum >/dev/null 2>&1; then SHA="sha256sum"
elif command -v shasum   >/dev/null 2>&1; then SHA="shasum -a 256"
else SHA=""
fi

TMP="$(mktemp -d 2>/dev/null || mktemp -d -t glxtr)"
trap 'rm -rf "$TMP"' EXIT INT TERM

say "image: $IMG ($(wc -c < "$IMG" | tr -d ' ') bytes)"

# --- 1. sysupgrade tar ------------------------------------------------------
tar -tf "$IMG" >/dev/null 2>&1 || die \
"not a readable tar. A GL sysupgrade image is a plain tar holding kernel and root."
tar -tf "$IMG" 2>/dev/null | grep -q 'sysupgrade-.*/root$' || die \
"no sysupgrade-*/root member. This does not look like a GL sysupgrade image."
tar -xf "$IMG" -C "$TMP"
ROOT="$(find "$TMP" -type f -name root -path '*sysupgrade*' | head -1)"
[ -n "$ROOT" ] || die "could not locate the root filesystem inside the image"
say "rootfs: $(wc -c < "$ROOT" | tr -d ' ') bytes"

# --- 2. squashfs sanity -----------------------------------------------------
# Magic 'hsqs' at offset 0, and compression id at bytes 20-21 (4 = xz).
head -c 4 "$ROOT" | grep -q 'hsqs' || die "root member is not a squashfs image"

# --- 3. targeted extraction -------------------------------------------------
# Only these four paths, deliberately. A full unsquashfs fails on a
# case-insensitive filesystem (macOS) because the kernel modules include both
# xt_dscp.ko and xt_DSCP.ko, and it aborts partway leaving empty files behind.
say "extracting four files"
unsquashfs -d "$TMP/x" -no-xattrs "$ROOT" \
	'/bin/bash' \
	'/usr/lib/cake-autorate/cake-autorate.sh' \
	'/usr/lib/cake-autorate/defaults.sh' \
	'/usr/lib/cake-autorate/lib.sh' >/dev/null 2>&1 || true

B="$TMP/x/bin/bash"
C="$TMP/x/usr/lib/cake-autorate"
[ -s "$B" ] || die "no /bin/bash in this image"
for f in cake-autorate.sh defaults.sh lib.sh; do
	[ -s "$C/$f" ] || die \
"no /usr/lib/cake-autorate/$f in this image. This firmware does not ship
cake-autorate. Use a 4.11+ build for a model that has it, such as mt6000."
done

# --- 4. verify what came out ------------------------------------------------
# The whole point of this port is that the vendor bash is a portable aarch64
# musl binary with EPOCHREALTIME. If it is not, say so here rather than after
# it is installed on a router.
case "$(file -b "$B" 2>/dev/null)" in
	*aarch64*) ;;
	*) die "extracted bash is not aarch64: $(file -b "$B")" ;;
esac
strings "$B" 2>/dev/null | grep -q 'ld-musl-aarch64' || die \
"extracted bash is not linked against musl aarch64"
strings "$B" 2>/dev/null | grep -qx 'EPOCHREALTIME' || die \
"extracted bash has no EPOCHREALTIME, which is the entire reason for using it"
# The version lives in a banner string: "@(#)Bash version 5.1.4(1) release GNU"
BV="$(strings "$B" 2>/dev/null | grep -oE 'Bash version [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $3}')"
case "${BV:-0}" in
	[5-9].*) ;;
	*) die "extracted bash reports version '${BV:-unknown}'; need 5.x" ;;
esac

CV="$(grep -oE 'cake_autorate_version="[^"]*"' "$C/cake-autorate.sh" | head -1 | cut -d'"' -f2)"
[ -n "$CV" ] || die "cake-autorate.sh has no version string; unexpected contents"

# --- 5. place ---------------------------------------------------------------
mkdir -p "$OUT"
cp "$B" "$OUT/bash5"
chmod 755 "$OUT/bash5"
for f in cake-autorate.sh defaults.sh lib.sh; do
	cp "$C/$f" "$OUT/$f"
	chmod 755 "$OUT/$f"
done

echo
say "bash            ${BV}  ($(wc -c < "$OUT/bash5" | tr -d ' ') bytes)"
say "cake-autorate   ${CV}"
if [ -n "$SHA" ]; then
	echo
	say "sha256:"
	( cd "$OUT" && $SHA bash5 cake-autorate.sh defaults.sh lib.sh ) | sed 's/^/    /'
fi
cat <<NEXT

Four files are in $OUT/. Install with:

  tar cf - . | ssh root@192.168.8.1 'mkdir -p /tmp/ca && tar xf - -C /tmp/ca && sh /tmp/ca/install.sh'

install.sh picks up $OUT/ automatically.
NEXT
