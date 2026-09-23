#!/usr/bin/env bash
# Regression coverage for the shared tmux doorbell parser and the operator
# attach's watcher-beacon contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-doorbell-beacon)
FIXTURE="$ROOT/tests/fixtures/pane-empty-composer.txt"

make_claude_fixture_tmux() {
  local dir=$1
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    enter=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift; printf '%s\n' "${1:-}" > "$FM_TYPED_FILE"; shift ;;
        Enter) enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf 'type:%s\n' "$(cat "$FM_TYPED_FILE")" >> "$FM_TMUX_LOG"
    fi
    if [ "$enter" -eq 1 ]; then
      printf 'enter\n' >> "$FM_TMUX_LOG"
      : > "$FM_ENTERED_FILE"
    fi
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in *cursor_y*) printf '8\n'; exit 0 ;; esac
    done
    exit 1
    ;;
  capture-pane)
    start=0
    end=-
    previous=
    for arg in "$@"; do
      case "$previous" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      previous=$arg
    done
    if [ "$start" = 0 ] && [ "$end" = - ]; then
      cat "$FM_FIXTURE"
    elif [ "$start" = 5 ] && [ "$end" = 7 ]; then
      if [ -e "$FM_ENTERED_FILE" ]; then
        sed -n '6,8p' "$FM_FIXTURE"
      elif [ -s "$FM_TYPED_FILE" ]; then
        printf '%s\n' \
          '────────────────────────────────────────────────────────────────────────────────' \
          "❯ $(cat "$FM_TYPED_FILE")" \
          '────────────────────────────────────────────────────────────────────────────────'
      else
        sed -n '6,8p' "$FM_FIXTURE"
      fi
    else
      sed -n "$((start + 1)),$((end + 1))p" "$FM_FIXTURE"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/tmux"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/sleep"
}

make_send_case() {
  local name=$1 dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state"
  make_claude_fixture_tmux "$dir"
  printf 'window=seat:fm-t1\nkind=ship\nharness=claude\n' > "$dir/home/state/t1.meta"
  printf '%s\n' "$dir"
}

run_fixture_send() {
  local dir=$1
  PATH="$dir/fakebin:$PATH" \
    FM_HOME="$dir/home" \
    FM_ROOT_OVERRIDE="$ROOT" \
    FM_SEND_SETTLE=0 \
    FM_FIXTURE="$dir/fixture.txt" \
    FM_TYPED_FILE="$dir/typed" \
    FM_ENTERED_FILE="$dir/entered" \
    FM_TMUX_LOG="$dir/tmux.log" \
    "$ROOT/bin/fm-send.sh" t1 "steer behind the idle Claude composer" \
    >"$dir/send.out" 2>"$dir/send.err"
}

test_empty_claude_fixture_is_submit_safe() {
  local dir out
  dir=$(make_send_case empty-composer)
  cp "$FIXTURE" "$dir/fixture.txt"
  : > "$dir/typed"
  : > "$dir/tmux.log"
  run_fixture_send "$dir" || fail "fm-send rejected Claude's empty separator composer"
  out=$(cat "$dir/tmux.log")
  [ "$(grep -c '^enter$' "$dir/tmux.log" || true)" -eq 1 ] \
    || fail "empty Claude composer should receive exactly one Enter: $out"
  [ "$(grep -c '^type:' "$dir/tmux.log" || true)" -eq 1 ] \
    || fail "empty Claude composer should receive exactly one doorbell paste: $out"
  assert_not_contains "$(cat "$dir/send.err")" "doorbell skipped" \
    "an empty Claude composer must not be reported as holding foreign text"
  pass "shared doorbell parser: the captured empty Claude separator composer is safe to submit"
}

test_horizontal_rule_composer_text_stays_protected() {
  local dir
  dir=$(make_send_case human-text)
  sed 's/^❯ $/❯ human draft/' "$FIXTURE" > "$dir/fixture.txt"
  : > "$dir/typed"
  : > "$dir/tmux.log"
  run_fixture_send "$dir" || fail "durable send should survive a protected composer"
  [ ! -s "$dir/tmux.log" ] \
    || fail "real user text in the separator composer was submitted: $(cat "$dir/tmux.log")"
  assert_contains "$(cat "$dir/send.err")" "doorbell skipped" \
    "real user text must remain protected by the shared doorbell parser"
  pass "shared doorbell parser: real text in a Claude separator composer stays protected"
}

make_guard_case() {
  local dir="$TMP_ROOT/guard-beacon" home="$TMP_ROOT/guard-beacon/home"
  mkdir -p "$home/state" "$home/config" "$TMP_ROOT/guard-beacon/root" "$TMP_ROOT/guard-beacon/company/bin"
  printf 'window=seat:fm-t1\nkind=ship\n' > "$home/state/t1.meta"
  touch -t 202001010000 "$home/state/.last-watcher-beat"
  printf '%s\n' "$TMP_ROOT/guard-beacon"
}

run_autoarm_guard() {
  local dir=$1
  FM_ROOT_OVERRIDE="$dir/root" \
    FM_HOME="$dir/home" \
    FM_GUARD_GRACE=300 \
    FM_SUPERVISION_MODEL=autoarm \
    "$ROOT/bin/fm-guard.sh" 2>&1
}

test_attach_beacon_refresh_makes_guard_healthy() {
  local dir stale healthy restored node
  dir=$(make_guard_case)
  stale=$(run_autoarm_guard "$dir")
  assert_contains "$stale" "WATCHER DOWN - SUPERVISION IS OFF" \
    "an unrefreshed attach beacon must remain stale"

  node="$dir/node"
  cat > "$node" <<'SH'
#!/usr/bin/env bash
printf '{"result":[]}\n'
SH
  chmod +x "$node"
  FM_OPERATOR_STATE="$dir/operator-watch" \
    FM_OPERATOR_RUNTIME_STATE="$dir/home/state" \
    FM_OPERATOR_COMPANY_ROOT="$dir/company" \
    FM_OPERATOR_FIRSTMATE_HOME="$dir/home" \
    FM_OPERATOR_FIRSTMATE_ROOT="$ROOT" \
    FM_OPERATOR_NODE="$node" \
    FM_OPERATOR_SEATS= \
    HEARTBEAT_MIN=0 \
    "$ROOT/bin/fm-operator-attach.sh" >"$dir/attach.out" 2>"$dir/attach.err" \
    || fail "operator attach failed while refreshing its beacon: $(cat "$dir/attach.err")"
  healthy=$(run_autoarm_guard "$dir")
  [ -z "$healthy" ] || fail "fm-guard should be healthy after operator attach refreshed its beacon: $healthy"

  rm -f "$dir/home/state/.last-watcher-beat"
  touch -t 202001010000 "$dir/home/state/.last-watcher-beat"
  restored=$(run_autoarm_guard "$dir")
  assert_contains "$restored" "WATCHER DOWN - SUPERVISION IS OFF" \
    "the same guard must return to stale when the refreshed beacon ages out"
  pass "operator attach beacon contract: refresh makes fm-guard healthy and stale returns without it"
}

test_empty_claude_fixture_is_submit_safe
test_horizontal_rule_composer_text_stays_protected
test_attach_beacon_refresh_makes_guard_healthy
