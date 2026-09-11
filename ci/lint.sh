#!/bin/sh
# ci/lint.sh -- static checks. Runs in CI and on your machine, same code.
#
#   ./ci/lint.sh
#
# There is no way to test this project without GL hardware, so these checks
# cover the one class of bug that is catchable without it: shell that is wrong
# for the interpreter it will actually run under.

set -eu
cd "$(dirname "$0")/.."
fail=0
note() { printf '  %s\n' "$*"; }

# Everything here runs under busybox ash EXCEPT launcher.sh, which carries a
# #!/usr/bin/bash5 shebang and is bash. Checking it as ash produces two dozen
# bogus "In dash, arrays are not supported" errors, so the dialect is per file.
ASH="files/usr/lib/cake-autorate/gl-shape-lib.sh
files/usr/lib/cake-autorate/gl-wan-follow.sh
files/usr/lib/cake-autorate/gl-autorate-ctl.sh
files/usr/lib/cake-autorate/gl-autorate-tune.sh
files/usr/lib/cake-autorate/gl-autorate-httpd.sh
files/usr/lib/cake-autorate/UNINSTALL.sh
files/usr/lib/cake-autorate/www/cgi-bin/autorate
files/etc/gl-switch.d/autorate.sh
files/etc/hotplug.d/iface/99-cake-autorate
files/etc/init.d/cake-autorate
install.sh
extract-upstream.sh"
BASH_FILES="files/usr/lib/cake-autorate/launcher.sh"

echo "== syntax =="
for f in $ASH; do
	[ -f "$f" ] || { note "MISSING $f"; fail=1; continue; }
	sh -n "$f" 2>/dev/null || { note "syntax FAILED $f"; fail=1; }
done
note "$(echo "$ASH" | wc -l | tr -d ' ') ash scripts parse"

if command -v bash >/dev/null 2>&1; then
	for f in $BASH_FILES; do
		bash -n "$f" 2>/dev/null || { note "syntax FAILED $f"; fail=1; }
	done
	note "launcher.sh parses as bash"
fi

echo "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
	# Fail on errors only. Notes and warnings are advisory here: much of this
	# is vendor code carried with minimal edits, and churning it to silence
	# style notes would make the patches/ diffs harder to review.
	# SC1091: sourced files are resolved at runtime on the router.
	for f in $ASH; do
		shellcheck -s busybox -S error -e SC1091 "$f" || fail=1
	done
	for f in $BASH_FILES; do
		shellcheck -s bash -S error -e SC1091 "$f" || fail=1
	done
	note "no shellcheck errors"
else
	note "shellcheck not installed, skipped"
fi

echo "== lua =="
if command -v luac >/dev/null 2>&1; then
	for f in files/usr/lib/lua/luci/controller/cakeautorate.lua \
	         files/usr/lib/lua/luci/model/cbi/cakeautorate.lua; do
		luac -p "$f" || { note "lua syntax FAILED $f"; fail=1; }
	done
	note "LuCI files compile"
elif command -v lua >/dev/null 2>&1; then
	for f in files/usr/lib/lua/luci/controller/cakeautorate.lua \
	         files/usr/lib/lua/luci/model/cbi/cakeautorate.lua; do
		lua -e "assert(loadfile('$f'))" || { note "lua syntax FAILED $f"; fail=1; }
	done
	note "LuCI files load"
else
	note "no lua available, skipped"
fi

echo "== json =="
for f in files/usr/share/rpcd/acl.d/*.json; do
	[ -f "$f" ] || continue
	if command -v python3 >/dev/null 2>&1; then
		python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" \
			|| { note "invalid JSON $f"; fail=1; }
	fi
done
note "rpcd ACL is valid JSON"

echo "== shebangs =="
# The port's whole premise is that these run under the vendor bash, not
# /bin/bash, which on these devices is 3.2 and lacks EPOCHREALTIME.
for f in $BASH_FILES; do
	head -1 "$f" | grep -q '^#!/usr/bin/bash5$' \
		|| { note "$f does not point at /usr/bin/bash5"; fail=1; }
done
note "bash scripts point at /usr/bin/bash5"

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES above"; fi
exit "$fail"
