#!/usr/bin/env bash
# Runs the simulator build's smoke test in an iOS Simulator. Usage: scripts/run_smoke_simulator.sh
set -euo pipefail
. "$(dirname "$0")/env.sh" iphonesimulator
UDID="$(xcrun simctl list devices available -j | python3 -c '
import json,sys
d=json.load(sys.stdin)["devices"]
for rt,devs in sorted(d.items(), reverse=True):
    if "iOS" in rt:
        for x in devs:
            if x["name"].startswith("iPhone"):
                print(x["udid"]); sys.exit(0)
sys.exit(1)')"
echo "simulator $UDID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
DIR="${RUNNER_TEMP:-/tmp}/zios-smoke"
rm -rf "$DIR" && mkdir -p "$DIR"
xcrun simctl spawn "$UDID" "$OUT/zios_smoke" "$DIR"
