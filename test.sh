#!/bin/bash
#
# test.sh — exercise agent-grant against a throwaway base under $TMPDIR.
#
# Runs as you, the fixture's owner, so it needs no sudo. It does need the
# agents-scratch group to exist:
#
#   sudo dseditgroup -o create agents-scratch

set -euo pipefail
export LC_ALL=C

tool=$(cd "$(dirname "$0")" && pwd)/agent-grant

if ! dscl . -read /Groups/agents-scratch PrimaryGroupID >/dev/null 2>&1; then
	echo "test.sh: group agents-scratch does not exist; see the top of this file" >&2
	exit 2
fi
if [ $((8#$(stat -f %Lp "$HOME") & 8#077)) -ne 0 ]; then
	echo "test.sh: $HOME is open to group or other, and apply would change that." >&2
	echo "test.sh: read docs/home-exposure.md, fix it, then rerun." >&2
	exit 2
fi

fixture=$(mktemp -d "${TMPDIR:-/tmp}/agent-grant-test.XXXXXX")
trap 'rm -rf "$fixture"' EXIT
export AGENT_GRANT_BASE=$fixture/base
root=$AGENT_GRANT_BASE/scratch
out=$fixture/out
failures=0

pass() {
	printf 'ok   %s\n' "$1"
}

flunk() {
	printf 'FAIL %s\n' "$1"
	sed 's/^/     /' "$out"
	failures=$((failures + 1))
}

# run STATUS NAME ARGS... — run agent-grant and compare its exit status.
run() {
	local want=$1 name=$2 got=0
	shift 2
	"$tool" "$@" >"$out" 2>&1 || got=$?
	if [ "$got" = "$want" ]; then
		pass "$name"
	else
		flunk "$name (exit $got, want $want)"
	fi
}

# says LINE NAME — the last run printed exactly LINE.
says() {
	if grep -qxF -- "$1" "$out"; then
		pass "$2"
	else
		flunk "$2"
	fi
}

snapshot() {
	find "$AGENT_GRANT_BASE" -exec stat -f '%Fc %N' {} + | sort
}

mkdir -p "$root/proj/src" "$fixture/outside"
chmod 755 "$AGENT_GRANT_BASE" "$root"
touch "$root/proj/src/main.c" "$root/proj/with space" "$root/proj/ünïcödé" \
	"$fixture/outside/secret"
ln -s "$fixture/outside/secret" "$root/proj/link"
# chmod blocks opening a fifo with no writer. If the tests hang, the scan
# picked this up.
mkfifo "$root/proj/fifo"

run 1 "check reports a new root" apply --check
says "mode $root" "  names the root's mode"
says "acl $root" "  names the root's ACL"
says "acl $root/proj/src/main.c" "  names a descendant"
run 0 "apply fixes it" apply
run 0 "check is clean after apply" apply --check

before=$(snapshot)
run 0 "apply again" apply
if [ ! -s "$out" ] && [ "$(snapshot)" = "$before" ]; then
	pass "  changes nothing, not even ctime"
else
	flunk "  changes nothing, not even ctime"
fi

# ls -e is the only base tool that prints an ACL.
# shellcheck disable=SC2012
if [ -z "$(ls -le "$fixture/outside/secret" | sed 1d)" ]; then
	pass "symlink target outside the root is untouched"
else
	flunk "symlink target outside the root is untouched"
fi

if [ "$(stat -f %Lp "$root")" = 700 ]; then
	pass "root is go-rwx"
else
	flunk "root is go-rwx"
fi

mkdir "$root/proj/newdir"
touch "$root/proj/new" "$root/proj/newdir/f"
run 0 "objects created after apply inherit a clean ACL" apply --check

touch "$fixture/outside/moved"
mv "$fixture/outside/moved" "$root/proj/moved"
run 1 "check catches a file moved in" apply --check
says "acl $root/proj/moved" "  names it"
run 0 "apply grants it" apply
run 0 "check is clean again" apply --check

chmod +a "group:staff allow read" "$root/proj/src/main.c"
run 1 "check catches a foreign entry" apply --check
run 0 "apply removes it" apply
run 0 "check is clean again" apply --check

chmod 775 "$AGENT_GRANT_BASE"
run 1 "check catches a group-writable base" apply --check
says "mode $AGENT_GRANT_BASE" "  names it"
run 0 "apply fixes it" apply

ln "$fixture/outside/secret" "$root/proj/hardlink"
run 2 "a hard link from outside the root is an error" apply
# ls -e is the only base tool that prints an ACL.
# shellcheck disable=SC2012
if grep -qF "$root/proj/hardlink:" "$out" &&
	[ -z "$(ls -le "$fixture/outside/secret" | sed 1d)" ]; then
	pass "  names it, and grants nothing through it"
else
	flunk "  names it, and grants nothing through it"
fi
rm "$root/proj/hardlink"
run 0 "check is clean once the link is gone" apply --check

# Both links inside the root, as npm does with esbuild's binary. Moved in, so
# it starts with no ACL.
touch "$fixture/outside/pair"
mv "$fixture/outside/pair" "$root/proj/pair"
ln "$root/proj/pair" "$root/proj/src/pair"
run 1 "a hard link with every link in the root is ordinary drift" apply --check
says "acl $root/proj/pair" "  names the first link"
says "acl $root/proj/src/pair" "  names the second link"
run 0 "apply grants it" apply
run 0 "check is clean again" apply --check
rm "$root/proj/pair" "$root/proj/src/pair"

bad=$root/$(printf 'bad\nname')
touch "$bad"
run 2 "a name containing a newline is an error" apply --check
rm "$bad"

mkdir "$AGENT_GRANT_BASE/no-such-level"
run 2 "a root whose group is missing is an error" apply --check
rmdir "$AGENT_GRANT_BASE/no-such-level"

echo
if [ "$failures" = 0 ]; then
	echo "all passed"
else
	echo "$failures failed"
	exit 1
fi
