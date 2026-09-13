#!/usr/bin/env bash
# Independent criteria: real supervision consumer with a fake company CLI transport.
# It pins the runtime-shell side of Repair 4 (PAUSE-BUILDER-CARD.md): the company
# owns pause mode, and every runtime consumer asks the company-owned reader
# through one shared helper. Assertions describe behavior through the real
# consumer scripts; no implementation-source bytes are inspected.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-company-pause.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/home/state" "$TMP/home/config" "$TMP/company/bin" "$TMP/records"

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

cat > "$TMP/company/bin/company-runtime.mjs" <<'JS'
import fs from 'node:fs';
if (process.argv[2] !== 'company-state' || process.argv[3] !== '--admission' || process.argv[4] !== 'true') throw new Error('unexpected mode reader contract');
fs.appendFileSync(process.env.FM_PAUSE_TEST_LOG, 'read\n');
console.log(JSON.stringify({ok:true,result:{companyState:process.env.FM_PAUSE_TEST_MODE}}));
process.exitCode = process.env.FM_PAUSE_TEST_MODE === 'running' ? 0 : 3;
JS

# A fake ps that makes the surrounding test shell look like a verified harness so
# the real lock-owning consumers can reach their company admission check. The
# real ppid is still read from the system ps, so ancestry stays honest.
make_fake_ps() {  # <fakebin>
  local fakebin=$1
  mkdir -p "$fakebin"
  cat > "$fakebin/ps" <<'SH'
#!/usr/bin/env bash
set -u
harness=${FM_FAKE_HARNESS:-claude}
pid=
previous=
for argument in "$@"; do
  [ "$previous" = -p ] && pid=$argument
  previous=$argument
done
case "$*" in
  *"comm="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
      printf '/usr/local/bin/%s\n' "$harness"
    else
      printf '/bin/bash\n'
    fi
    exit 0
    ;;
  *"args="*)
    if [ "$pid" = "${FM_FAKE_HARNESS_PID:-}" ]; then
      printf '%s\n' "$harness"
    else
      printf 'bash\n'
    fi
    exit 0
    ;;
  *"ppid="*) /bin/ps -o ppid= -p "$pid" ;;
esac
exit 1
SH
  chmod +x "$fakebin/ps"
}

# A fake code root whose bin/ is the real firstmate bin/ except for the child
# programs each consumer would otherwise run for real. The company reader is the
# fake external transport; these stand-ins only record how they were invoked.
make_fake_root() {  # <root>
  local root=$1 f
  mkdir -p "$root/bin"
  for f in "$ROOT"/bin/*.sh; do
    ln -s "$f" "$root/bin/$(basename "$f")"
  done
  rm -f "$root/bin/fm-bootstrap.sh" "$root/bin/fm-inactive-reconcile.sh"
  cat > "$root/bin/fm-bootstrap.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'bootstrap network=%s detect_only=%s\n' \
  "${FM_BOOTSTRAP_NETWORK:-all}" "${FM_BOOTSTRAP_DETECT_ONLY:-0}" >> "${FM_FAKE_ROOT_LOG:?}"
SH
  cat > "$root/bin/fm-inactive-reconcile.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf 'inactive %s\n' "$*" >> "${FM_FAKE_ROOT_LOG:?}"
SH
  chmod +x "$root/bin/fm-bootstrap.sh" "$root/bin/fm-inactive-reconcile.sh"
}

export FM_HOME="$TMP/home" FM_ROOT_OVERRIDE="$ROOT"
export LATENT_SEA_COMPANY_ROOT="$TMP/company" LATENT_SEA_COMPANY_STATE="$TMP/records"

# --- metadata admission through the shared supervision consumer -----------------
export FM_PAUSE_TEST_LOG="$TMP/reads.supervision" FM_PAUSE_TEST_MODE=paused
printf 'kind=worker\n' > "$TMP/home/state/one.meta"
printf 'kind=worker\n' > "$TMP/home/state/two.meta"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"
if fm_supervision_needed "$FM_HOME/state"; then
  echo 'FAIL: paused job metadata still requires automatic supervision' >&2
  exit 1
fi
[ -s "$TMP/reads.supervision" ] || { echo 'FAIL: real consumer did not call company-owned mode reader' >&2; exit 1; }
FM_PAUSE_TEST_MODE=running
export FM_PAUSE_TEST_MODE
fm_supervision_needed "$FM_HOME/state" || { echo 'FAIL: running jobs lost supervision' >&2; exit 1; }
unset LATENT_SEA_COMPANY_ROOT LATENT_SEA_COMPANY_STATE
fm_supervision_needed "$FM_HOME/state" || { echo 'FAIL: ordinary noncompany jobs lost supervision' >&2; exit 1; }
export LATENT_SEA_COMPANY_ROOT="$TMP/company" LATENT_SEA_COMPANY_STATE="$TMP/records"

# --- config-file source and partial-configuration refusal -----------------------
CFG_HOME="$TMP/cfg/home"
mkdir -p "$CFG_HOME/config"
printf '{"stateRoot":"%s","companyRoot":"%s"}\n' "$TMP/records" "$TMP/company" > "$CFG_HOME/config/company-web.json"
: > "$TMP/reads.cfg"
CFG_RESULT=$(env -u LATENT_SEA_COMPANY_ROOT -u LATENT_SEA_COMPANY_STATE FM_HOME="$CFG_HOME" \
  FM_PAUSE_TEST_LOG="$TMP/reads.cfg" FM_PAUSE_TEST_MODE=paused \
  bash -c '. "$1/bin/fm-company-pause-lib.sh"; fm_company_admission; printf "%s %s\n" "$?" "$FM_COMPANY_MODE"' _ "$ROOT")
[ "$CFG_RESULT" = "3 paused" ] || { echo "FAIL: config/company-web.json source did not resolve to paused (got '$CFG_RESULT')" >&2; exit 1; }
[ -s "$TMP/reads.cfg" ] || { echo 'FAIL: config-file source did not call the company-owned mode reader' >&2; exit 1; }
if env -u LATENT_SEA_COMPANY_ROOT FM_HOME="$CFG_HOME" LATENT_SEA_COMPANY_STATE="$TMP/records" \
  bash -c '. "$1/bin/fm-company-pause-lib.sh"; fm_company_admission; [ "$FM_COMPANY_MODE" = error ]' _ "$ROOT"; then :; else
  echo 'FAIL: partial company configuration was silently treated as non-company' >&2
  exit 1
fi

# --- fresh spawn cannot admit new work or mutate while paused --------------------
SPAWN_HOME="$TMP/spawn-home"
mkdir -p "$SPAWN_HOME/state"
: > "$TMP/reads.spawn"
if FM_HOME="$SPAWN_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
  FM_PAUSE_TEST_LOG="$TMP/reads.spawn" FM_PAUSE_TEST_MODE=paused \
  "$ROOT/bin/fm-spawn.sh" task-blocked "$TMP/absent-project" --mode local-only --yolo off \
  >"$TMP/spawn.out" 2>&1; then
  echo 'FAIL: spawn was admitted while company is paused' >&2
  exit 1
fi
[ -s "$TMP/reads.spawn" ] || { echo 'FAIL: spawn did not consult the company mode reader' >&2; exit 1; }
[ ! -e "$SPAWN_HOME/state/task-blocked.meta" ] || { echo 'FAIL: paused spawn wrote task metadata' >&2; exit 1; }
[ ! -e "$SPAWN_HOME/state/.spawn-task-blocked.lock" ] || { echo 'FAIL: paused spawn took the task lock' >&2; exit 1; }
grep -qi 'paused' "$TMP/spawn.out" || { echo 'FAIL: paused spawn refusal did not name the company pause' >&2; exit 1; }

# Existing task relaunch is also business admission. It must consult pause mode
# before taking a lifecycle lock, reading task details, or starting a replacement.
RELAUNCH_HOME="$TMP/relaunch-home"
mkdir -p "$RELAUNCH_HOME/state"
: > "$TMP/reads.relaunch"
if FM_HOME="$RELAUNCH_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
  FM_PAUSE_TEST_LOG="$TMP/reads.relaunch" FM_PAUSE_TEST_MODE=paused \
  "$ROOT/bin/fm-spawn.sh" task-blocked --relaunch >"$TMP/relaunch.out" 2>&1; then
  echo 'FAIL: relaunch was admitted while company is paused' >&2
  exit 1
fi
[ -s "$TMP/reads.relaunch" ] || { echo 'FAIL: relaunch did not consult the company mode reader' >&2; exit 1; }
[ ! -e "$RELAUNCH_HOME/state/.control-task-blocked.lock" ] || { echo 'FAIL: paused relaunch took the lifecycle lock before admission' >&2; exit 1; }
grep -qi 'paused' "$TMP/relaunch.out" || { echo 'FAIL: paused relaunch refusal did not name the company pause' >&2; exit 1; }

# Control: a non-company relaunch keeps its prior validation path.
NONCOMPANY_HOME="$TMP/noncompany-relaunch-home"
mkdir -p "$NONCOMPANY_HOME/state"
env -u LATENT_SEA_COMPANY_ROOT -u LATENT_SEA_COMPANY_STATE \
  FM_HOME="$NONCOMPANY_HOME" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
  "$ROOT/bin/fm-spawn.sh" task-blocked --relaunch >"$TMP/noncompany-relaunch.out" 2>&1 || true
grep -q 'needs an existing task record' "$TMP/noncompany-relaunch.out" || {
  echo 'FAIL: ordinary non-company relaunch no longer reached its existing validation' >&2
  exit 1
}
if grep -qi 'company work is paused' "$TMP/noncompany-relaunch.out"; then
  echo 'FAIL: ordinary non-company relaunch was treated as paused company work' >&2
  exit 1
fi

# --- deferred startup falls back to detect-only while paused --------------------
DEF_ROOT="$TMP/deferred/root"
DEF_HOME="$TMP/deferred/home"
FAKEBIN="$TMP/fakebin"
make_fake_root "$DEF_ROOT"
make_fake_ps "$FAKEBIN"
mkdir -p "$DEF_HOME/state"
printf '%s\n' $$ > "$DEF_HOME/state/.lock"
: > "$TMP/reads.deferred"
: > "$TMP/deferred.log"
PATH="$FAKEBIN:$PATH" FM_FAKE_HARNESS_PID=$$ FM_HOME="$DEF_HOME" FM_ROOT_OVERRIDE="$DEF_ROOT" \
  FM_FAKE_ROOT_LOG="$TMP/deferred.log" \
  FM_PAUSE_TEST_LOG="$TMP/reads.deferred" FM_PAUSE_TEST_MODE=paused \
  "$DEF_ROOT/bin/fm-startup-network.sh" run --locked 1 >"$TMP/deferred.out" 2>&1
[ -s "$TMP/reads.deferred" ] || { echo 'FAIL: deferred startup did not consult the company mode reader' >&2; exit 1; }
grep -q 'detect_only=1' "$TMP/deferred.log" || { echo 'FAIL: paused deferred startup did not run detect-only bootstrap' >&2; exit 1; }
if grep -q 'inactive' "$TMP/deferred.log"; then
  echo 'FAIL: paused deferred startup ran the mutating inactive-outcome scan' >&2
  exit 1
fi
grep -q '^phases=probe$' "$DEF_HOME/state/.startup-network.status" || { echo 'FAIL: paused deferred startup did not report detect-only phases' >&2; exit 1; }
grep -q '^locked=0$' "$DEF_HOME/state/.startup-network.status" || { echo 'FAIL: paused deferred startup still reported locked sweeps' >&2; exit 1; }

# Control: the same setup admits the mutating branch when running.
: > "$TMP/reads.deferred-running"
: > "$TMP/deferred-running.log"
PATH="$FAKEBIN:$PATH" FM_FAKE_HARNESS_PID=$$ FM_HOME="$DEF_HOME" FM_ROOT_OVERRIDE="$DEF_ROOT" \
  FM_FAKE_ROOT_LOG="$TMP/deferred-running.log" \
  FM_PAUSE_TEST_LOG="$TMP/reads.deferred-running" FM_PAUSE_TEST_MODE=running \
  "$DEF_ROOT/bin/fm-startup-network.sh" run --locked 1 >"$TMP/deferred-running.out" 2>&1
grep -q 'detect_only=0' "$TMP/deferred-running.log" || { echo 'FAIL: running deferred startup did not run its mutating sweeps' >&2; exit 1; }
grep -q 'inactive' "$TMP/deferred-running.log" || { echo 'FAIL: running deferred startup skipped the inactive-outcome scan' >&2; exit 1; }

# --- session start skips mutating continuation without claiming lock failure -----
SS_HOME="$TMP/session/home"
SS_ROOT="$TMP/session/root"
SS_FAKEBIN="$TMP/session/fakebin"
make_fake_root "$SS_ROOT"
make_fake_ps "$SS_FAKEBIN"
mkdir -p "$SS_HOME/state" "$SS_HOME/data" "$SS_HOME/config"
: > "$TMP/reads.session"
: > "$TMP/session.log"
PATH="$SS_FAKEBIN:$PATH" FM_FAKE_HARNESS_PID=$$ FM_HOME="$SS_HOME" FM_ROOT_OVERRIDE="$SS_ROOT" \
  FM_FAKE_ROOT_LOG="$TMP/session.log" FM_SESSION_START_TIMEOUT=60 \
  FM_PAUSE_TEST_LOG="$TMP/reads.session" FM_PAUSE_TEST_MODE=paused \
  "$SS_ROOT/bin/fm-session-start.sh" >"$TMP/session.out" 2>&1 || true
grep -q 'lock acquired' "$TMP/session.out" || { echo 'FAIL: paused session start did not acquire the verified lock' >&2; exit 1; }
grep -q 'detect_only=1' "$TMP/session.log" || { echo 'FAIL: paused session start did not run detect-only bootstrap' >&2; exit 1; }
if grep -q 'FLEET LOCK OWNERSHIP WAS NOT VERIFIED' "$TMP/session.out"; then
  echo 'FAIL: paused session start misreported the verified lock as a lock failure' >&2
  exit 1
fi
grep -qi 'company paused' "$TMP/session.out" || { echo 'FAIL: paused session start did not announce the company pause' >&2; exit 1; }

echo 'PASS: shared company admission reader governs supervision, spawn, deferred startup, and session start; ordinary homes unchanged'
