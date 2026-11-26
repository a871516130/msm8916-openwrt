#!/bin/sh
# Set the bt-agent pairing PIN policy and (re)start the agent so it takes
# effect.  Usage: bt_pin.sh <mac|*> <pin>
#
# The uci "btagent" config is the source of truth: the btagent init script
# regenerates /tmp/btagent.cfg from it and runs bt-agent -p against it.  The
# file is appended to, so start from a clean slate to keep the new policy from
# mixing with a stale one.  bt-agent complains if the PIN file is world
# readable, and a non-trivial PIN should not be -- tighten it to the owner.
#
# Prints "ok" on success, or a message on failure.

MAC="$1"
PIN="$2"

[ -x /etc/init.d/btagent ] || { echo "bt-agent (bluez-tools) is not installed"; exit 1; }
[ -n "$MAC" ] || { echo "missing MAC argument"; exit 1; }
[ -n "$PIN" ] || { echo "missing PIN argument"; exit 1; }

# Keep the existing anonymous section if present, otherwise add one.
if uci -q get btagent.@btagent[0].mac >/dev/null 2>&1; then
	uci set btagent.@btagent[0].mac="$MAC"
	uci set btagent.@btagent[0].pin="$PIN"
else
	sid=$(uci add btagent btagent)
	[ -n "$sid" ] || { echo "failed to create btagent section"; exit 1; }
	uci set btagent.$sid.mac="$MAC"
	uci set btagent.$sid.pin="$PIN"
fi
uci commit btagent || { echo "uci commit failed"; exit 1; }

rm -f /tmp/btagent.cfg
/etc/init.d/btagent restart >/dev/null 2>&1
chmod 600 /tmp/btagent.cfg 2>/dev/null

echo "ok"
