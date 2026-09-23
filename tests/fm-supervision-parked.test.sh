#!/usr/bin/env bash
# A record marked parked=1 is not in-flight work, so it never demands a watcher.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
. "$here/bin/fm-supervision-lib.sh"
state=$(mktemp -d); trap 'rm -rf "$state"' EXIT
printf 'harness=codex\nparked=1\n' > "$state/old.meta"
fm_supervision_status "$state"
[ "$FM_SUP_IN_FLIGHT" = 0 ] || { echo "not ok - parked record counted: $FM_SUP_IN_FLIGHT"; exit 1; }
printf 'harness=codex\n' > "$state/live.meta"
fm_supervision_status "$state"
[ "$FM_SUP_IN_FLIGHT" = 1 ] || { echo "not ok - live record not counted: $FM_SUP_IN_FLIGHT"; exit 1; }
echo "ok - parked records are not in flight; live ones are"
