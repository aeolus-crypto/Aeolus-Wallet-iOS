# Layer: zephyr-backports security fixes (on in every CI build)

On in every CI push build since 2026-11-27 (iOS security audit HIGH-01); a manual workflow run can
still untick it. The engine is built from the original ZephyrProtocol repositories; this layer
adds the security fixes that the zephyr-backports forks carry (and that the Android app ships
through zephyr-java), for use before a production release if upstream has not merged them.

| File | What it is |
|---|---|
| `zephyr/v2.3.0-sec.2.patch` | Tree difference ZephyrProtocol/zephyr v2.3.0 (`67c5f53b`) → zephyr-backports/zephyr v2.3.0-sec.2 (`8c6a1202`), without fork-only files. Advisories SB-001..010, SB-015..034. |
| `zephyr-cpp/v2.3.0-sec.1.patch` | ZephyrProtocol/zephyr-cpp `4a99272f` → zephyr-backports/zephyr-cpp v2.3.0-sec.1 (`3a2ee602`). Advisories SB-011..014. |

The RandomX submodule bump of sec.2 (`102f8acf` → `12f2c2ff`, v1.2.3) is not in the patch (a
submodule pointer cannot be applied as a diff). The wallet never computes RandomX hashes, so the
engine is unaffected; `setup_tree.sh` leaves the submodule at upstream's commit.

Use: `ZIOS_BACKPORTS=1 scripts/setup_tree.sh` locally, or run the "iOS engine" workflow by hand
with **backports** ticked. CI's `patch layers apply` job checks on every push that this layer and
the iOS layer apply together.

The iOS layer (`../ios/`) touches only `CMakeLists.txt` line ~48 (the legacy iOS include),
and `src/cryptonote_basic/miner.cpp`; this layer changes none of those
regions, so either can be dropped or refreshed without touching the other. When upstream merges
any of these fixes, `setup_tree.sh` reports the patch as already applied; regenerate the files
from the new upstream tag at that point.
