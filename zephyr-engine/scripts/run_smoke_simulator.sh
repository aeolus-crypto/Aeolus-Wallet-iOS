#!/usr/bin/env bash
# Runs the simulator build's smoke test in an iOS Simulator. The wallets it creates and its log
# stay in $RUNNER_TEMP/zios-smoke (uploaded by CI). Usage: scripts/run_smoke_simulator.sh
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
xcrun simctl bootstatus "$UDID" -b > /dev/null
DIR="${RUNNER_TEMP:-/tmp}/zios-smoke"
rm -rf "$DIR" && mkdir -p "$DIR/fixture-linux"
cp "$ROOT/engine/fixtures/linux-x86_64/"* "$DIR/fixture-linux/"
RC=0
xcrun simctl spawn "$UDID" "$OUT/zios_smoke" "$DIR" "$DIR/fixture-linux" 1 || RC=$?
echo "--- core log: cache and keys loading"
grep -h -E "cache|portable|Loaded wallet|correspond|Failed|Error|exception" "$DIR"/zios.log* 2>/dev/null | grep -v "word list\|prefix length" | tail -60 || true
ls -l "$DIR"
exit "$RC"
