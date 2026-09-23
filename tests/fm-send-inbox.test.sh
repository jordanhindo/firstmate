#!/usr/bin/env bash
# tests/fm-send-inbox.test.sh - fm-send's inbox data plane.
#
# An ordinary text steer to a task recorded in this home no longer types its
# payload: fm-send appends a durable sequenced record to state/<id>.inbox/ and
# rings one constant self-describing doorbell line, best-effort. These tests
# drive the real fm-send executable over a stubbed tmux and pin:
#   1. The payload is durably recorded and never typed; only the doorbell
#      crosses the terminal, and the send exits 0 at enqueue.
#   2. Multi-line steers are legal and round-trip byte-exact.
#   3. A re-send enqueues a NEW sequence and still never retypes a payload,
#      so the terminal can never truncate, garble, or duplicate a steer.
#   4. The composer pre-check is advisory: visibly pending text skips the ring
#      with a notice, and the steer is still durably sent (exit 0).
#   5. A failed doorbell is still a sent steer (exit 0, record durable): the
#      watcher's re-ring ladder owns delivery from the record on.
#   6. Carve-outs keep the typed plane: a leading "/" (any harness), a leading
#      "$" to codex, an explicit backend target, and the --key path.
#   7. A marked secondmate steer carries its marker + corr token in the record
#      body, and the pending-reply expectation is marked delivered at enqueue.
#   8. Pending-reply bookkeeping failure after enqueue never reports a
#      retryable send failure that could duplicate the durable instruction.
#   9. An unwritable inbox is a real local failure: nonzero exit, nothing
#      typed, and a just-created pending-reply expectation is discarded.
#  10. A repeated own doorbell already in the composer is submitted, while
#      unrelated pending text remains protected by the skip.
# Every case below that passes a literal `$...` message quotes it on purpose
# (the point is sending an unexpanded `$` line), so SC2016 is disabled.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-marker-lib.sh"

SEND="$ROOT/bin/fm-send.sh"

TMP_ROOT=$(fm_test_tmproot fm-send-inbox)
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)

# Stub tmux: logs literal typed text to FM_SEND_LOG and lets the submit and
# composer paths reach clean verdicts. FM_FAKE_TMUX_COMPOSER=pending renders a
# composer visibly holding text; FM_FAKE_TMUX_SEND_FAIL=1 fails send-keys.
make_stubs() {  # <dir> -> echoes fakebin dir
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    [ "${FM_FAKE_TMUX_SEND_FAIL:-0}" = 1 ] && exit 1
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    if [ "$literal" = 1 ]; then
      printf '%s\n' "${1:-}" >> "$FM_SEND_LOG"
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do case "$a" in *cursor_y*) printf '1\n'; exit 0 ;; esac; done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane)
    if [ "${FM_FAKE_TMUX_COMPOSER:-}" = pending ]; then
      printf '╭──────────────╮\n│ leftover txt │\n╰──────────────╯\n'
    else
      printf '╭────╮\n│    │\n╰────╯\n'
    fi
    exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
  printf '%s\n' "$fb"
}

setup_case() {  # <name> [harness] -> echoes case dir with home/state + t1 meta
  local name=$1 harness=${2:-claude} dir
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/home/state"
  make_stubs "$dir" >/dev/null
  fm_write_meta "$dir/home/state/t1.meta" "window=sess:fm-t1" "kind=ship" "harness=$harness"
  printf '%s\n' "$dir"
}

run_send() {  # <case-dir> <err-file> [env...] -- <fm-send args...>
  local dir=$1 err=$2
  shift 2
  local envs=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    envs+=("$1")
    shift
  done
  shift
  : > "$dir/send.log"
  env PATH="$dir/fakebin:$PATH" \
    FM_ROOT_OVERRIDE="$dir/home" FM_HOME="$dir/home" FM_SEND_LOG="$dir/send.log" \
    FM_SEND_CAPTURE_LOG="$dir/send.capture.log" \
    FM_SEND_SETTLE=0 ${envs[@]+"${envs[@]}"} \
    "$SEND" "$@" >/dev/null 2>"$err"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$2"
}

test_text_steer_rides_inbox() {
  local dir err rc rec body typed
  dir=$(setup_case rides); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "please rebase onto main"; rc=$?
  expect_code 0 "$rc" "an inbox-plane steer should exit 0 at enqueue"
  rec="$dir/home/state/t1.inbox/001.msg"
  [ -f "$rec" ] || fail "the steer was not durably recorded at $rec"
  body=$(record_body _ "$rec")
  [ "$body" = "please rebase onto main" ] || fail "the recorded body differs: $body"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "Firstmate instruction waiting: list $dir/home/state/t1.inbox/*.msg" \
    "the doorbell should direct the worker to drain the inbox"
  case "$typed" in
    *"please rebase onto main"*) fail "the payload must never be typed:"$'\n'"$typed" ;;
  esac
  pass "fm-send inbox: the payload is recorded durably and only the doorbell is typed"
}

test_multiline_steer_is_legal() {
  local dir err rc body
  dir=$(setup_case multiline); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 $'first line\nsecond line\nthird: with punctuation'; rc=$?
  expect_code 0 "$rc" "a multi-line steer should succeed"
  body=$(record_body _ "$dir/home/state/t1.inbox/001.msg")
  [ "$body" = $'first line\nsecond line\nthird: with punctuation' ] \
    || fail "the multi-line body did not round-trip:"$'\n'"$body"
  case "$(cat "$dir/send.log")" in
    *"second line"*) fail "a payload line leaked onto the typed channel" ;;
  esac
  pass "fm-send inbox: newlines are legal and the terminal can no longer truncate a steer"
}

test_resend_enqueues_new_sequence() {
  local dir err doorbells typed
  dir=$(setup_case resend); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "first send failed"
  run_send "$dir" "$err" -- t1 "check the CI result" || fail "second send failed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] && [ -f "$dir/home/state/t1.inbox/002.msg" ] \
    || fail "a re-send should enqueue a new sequence:"$'\n'"$(ls "$dir/home/state/t1.inbox")"
  doorbells=$(grep -cF 'Firstmate instruction waiting' "$dir/send.log" || true)
  [ "$doorbells" = 1 ] || fail "each send rings once (the log is truncated per send), got $doorbells"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "numeric order" \
    "a newer record's doorbell should preserve inbox sequence ordering"
  case "$typed" in
    *"check the CI result"*) fail "a re-send typed the payload" ;;
  esac
  pass "fm-send inbox: a re-send is a new durable record, never a retyped payload"
}

test_pending_composer_skips_ring_advisorily() {
  local dir err rc
  dir=$(setup_case pendingskip); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_COMPOSER=pending -- t1 "steer past a stuck composer"; rc=$?
  expect_code 0 "$rc" "a skipped ring is still a sent steer"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  [ ! -s "$dir/send.log" ] || fail "a visibly pending composer should skip the ring:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the skip notice should point at the re-ring"
  pass "fm-send inbox: a visibly pending composer skips the ring, and the steer stays durably sent"
}

make_doorbell_region_stub() {
  local dir=$1
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    shift
    literal=0
    enter=0
    typed=
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift; typed=${1:-}; shift ;;
        Enter) enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf 'type:%s\n' "$typed" >> "$FM_SEND_LOG"
    fi
    if [ "$enter" -eq 1 ]; then
      printf 'enter\n' >> "$FM_SEND_LOG"
      count=$(cat "${FM_FAKE_TMUX_ENTER_COUNT:-/dev/null}" 2>/dev/null || printf '0')
      printf '%s\n' "$((count + 1))" > "${FM_FAKE_TMUX_ENTER_COUNT:-/dev/null}"
      if [ "${FM_FAKE_TMUX_CLEAR_ON_ENTER:-1}" = 1 ] \
        && [ -n "${FM_FAKE_TMUX_ENTERED:-}" ]; then
        : > "$FM_FAKE_TMUX_ENTERED"
      fi
    fi
    exit 0
    ;;
  display-message)
    for arg in "$@"; do
      case "$arg" in *cursor_y*) printf '%s\n' "${FM_FAKE_TMUX_CURSOR:-0}"; exit 0 ;; esac
    done
    exit 1
    ;;
  capture-pane)
    start=0
    end=-
    joined=0
    previous=
    for arg in "$@"; do
      case "$previous" in
        -S) start=$arg ;;
        -E) end=$arg ;;
      esac
      case "$arg" in
        -J) joined=1 ;;
      esac
      previous=$arg
    done
    if [ -n "${FM_FAKE_TMUX_ENTERED:-}" ] \
      && [ -e "$FM_FAKE_TMUX_ENTERED" ] \
      && [ "${FM_FAKE_TMUX_CLEAR_ON_ENTER:-1}" = 1 ]; then
      exit 0
    fi
    printf '%s\t%s\t%s\n' "$joined" "$start" "$end" >> "${FM_SEND_CAPTURE_LOG:-/dev/null}"
    if [ "$joined" -eq 1 ] && [ "$start" = "${FM_FAKE_TMUX_REGION_START:-}" ] \
      && [ "$end" = "${FM_FAKE_TMUX_REGION_END:-}" ] \
      && [ -n "${FM_FAKE_TMUX_JOINED_CAPTURE:-}" ]; then
      cat "$FM_FAKE_TMUX_JOINED_CAPTURE"
      exit 0
    fi
    if [ "${FM_FAKE_TMUX_CLASSIFIER_UNPROVEN:-0}" = 1 ]; then
      for arg in "$@"; do
        if [ "$arg" = -e ]; then
          printf 'unclassified screen\n'
          exit 0
        fi
      done
    fi
    awk -v start="$start" -v end="$end" '
      {
        row = NR - 1
        if (row >= start && (end == "-" || row <= end)) print
      }
    ' "$FM_FAKE_TMUX_SCREEN"
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

doorbell_box_rule() {
  local width=1200 rule
  printf -v rule '%*s' "$width" ''
  printf '%s' "${rule// /─}"
}

doorbell_box_row() {
  local text=$1 width=1200 padding
  padding=$((width - 1 - ${#text}))
  [ "$padding" -ge 0 ] || fail "doorbell fixture row exceeds its Claude composer width"
  printf '│ %s%*s│\n' "$text" "$padding" ''
}

write_doorbell_box() {  # <screen> <region> <cursor-row> <row...>
  local screen=$1 region=$2 cursor=$3 rule row
  shift 3
  rule=$(doorbell_box_rule)
  {
    printf 'old transcript with an identical-looking phrase\n'
    printf '╭%s╮\n' "$rule"
    for row in "$@"; do
      doorbell_box_row "$row"
    done
    printf '╰%s╯\n' "$rule"
    printf 'footer after the composer\n'
  } > "$screen"
  {
    printf '╭%s╮\n' "$rule"
    for row in "$@"; do
      doorbell_box_row "$row"
    done
    printf '╰%s╯\n' "$rule"
  } > "$region"
  printf '%s\n' "$cursor"
}

test_pending_multiline_human_text_stays_protected() {
  local dir err line rc cursor screen region
  dir=$(setup_case own-doorbell-human); err="$dir/send.err"
  make_doorbell_region_stub "$dir"
  line="Firstmate instruction waiting: list $dir/home/state/t1.inbox/*.msg and, in numeric order, read and act on each, then mv each handled file to $dir/home/state/t1.inbox/handled/."
  screen="$dir/screen"; region="$dir/region"
  cursor=$(write_doorbell_box "$screen" "$region" 3 "human text that must not be submitted" "$line")
  run_send "$dir" "$err" FM_FAKE_TMUX_SCREEN="$screen" \
    FM_FAKE_TMUX_JOINED_CAPTURE="$region" FM_FAKE_TMUX_REGION_START=1 \
    FM_FAKE_TMUX_REGION_END=4 FM_FAKE_TMUX_CURSOR="$cursor" \
    FM_FAKE_TMUX_CLASSIFIER_UNPROVEN=1 -- \
    t1 "steer behind human text"; rc=$?
  expect_code 0 "$rc" "human text in another composer row should stay protected"
  [ "$(grep -c '^enter$' "$dir/send.log" || true)" = 0 ] \
    || fail "a multiline composer containing human text was submitted:"$'\n'"$(cat "$dir/send.log")"
  [ "$(grep -c '^type:' "$dir/send.log" || true)" = 0 ] \
    || fail "the protected composer received a new typed doorbell:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$err")" "doorbell skipped" \
    "human text should be reported as a skipped doorbell"
  pass "fm-send inbox: human text elsewhere in the composer prevents own-doorbell recovery"
}

test_pending_own_doorbell_submits_wrapped_and_mixed_text() {
  local dir err line legacy full split first second rc cursor screen region
  dir=$(setup_case own-doorbell-recovery); err="$dir/send.err"
  make_doorbell_region_stub "$dir"
  line="Firstmate instruction waiting: list $dir/home/state/t1.inbox/*.msg and, in numeric order, read and act on each, then mv each handled file to $dir/home/state/t1.inbox/handled/."
  legacy="Firstmate doorbell: read $dir/home/state/t1.inbox/*.msg in numeric order, act on each, then mv each handled file to $dir/home/state/t1.inbox/handled/."
  screen="$dir/screen"; region="$dir/region"
  full="${line}${line}"
  split=$(( ${#full} / 2 ))
  first=${full:0:$split}
  second=${full:$split}
  cursor=$(write_doorbell_box "$screen" "$region" 3 "$first" "$second")
  {
    printf '╭%s╮\n' "$(doorbell_box_rule)"
    doorbell_box_row "$full"
    printf '╰%s╯\n' "$(doorbell_box_rule)"
  } > "$region"
  run_send "$dir" "$err" FM_FAKE_TMUX_SCREEN="$screen" \
    FM_FAKE_TMUX_JOINED_CAPTURE="$region" FM_FAKE_TMUX_REGION_START=1 \
    FM_FAKE_TMUX_REGION_END=4 FM_FAKE_TMUX_CURSOR="$cursor" -- \
    t1 "steer behind wrapped copies"; rc=$?
  expect_code 0 "$rc" "wrapped repeated own doorbells should be submitted"
  [ "$(grep -c '^enter$' "$dir/send.log" || true)" = 1 ] \
    || fail "wrapped repeated doorbells should receive one Enter:"$'\n'"$(cat "$dir/send.log")"
  [ "$(grep -c '^type:' "$dir/send.log" || true)" = 0 ] \
    || fail "wrapped repeated doorbells were retyped:"$'\n'"$(cat "$dir/send.log")"
  assert_contains "$(cat "$dir/send.capture.log")" $'1\t1\t4' \
    "the recovery capture should use whole composer bounds with wrapping joined"

  full="${line}${legacy}"
  cursor=$(write_doorbell_box "$screen" "$region" 2 "$full")
  {
    printf '╭%s╮\n' "$(doorbell_box_rule)"
    doorbell_box_row "$full"
    printf '╰%s╯\n' "$(doorbell_box_rule)"
  } > "$region"
  rm -f "$dir/entered" "$dir/enter-count" "$dir/send.capture.log"
  run_send "$dir" "$err" FM_FAKE_TMUX_SCREEN="$screen" \
    FM_FAKE_TMUX_JOINED_CAPTURE="$region" FM_FAKE_TMUX_REGION_START=1 \
    FM_FAKE_TMUX_REGION_END=3 FM_FAKE_TMUX_CURSOR="$cursor" \
    FM_FAKE_TMUX_ENTER_COUNT="$dir/enter-count" -- \
    t1 "steer behind mixed doorbells"; rc=$?
  expect_code 0 "$rc" "current plus legacy doorbells should be submitted"
  [ "$(grep -c '^enter$' "$dir/send.log" || true)" = 1 ] \
    || fail "a current plus legacy concatenation should receive one Enter:"$'\n'"$(cat "$dir/send.log")"
  pass "fm-send inbox: wrapped repeats and current-plus-legacy doorbell concatenations are accepted"
}

test_existing_doorbell_enter_is_at_most_once() {
  local dir err line rc cursor screen region
  dir=$(setup_case own-doorbell-stuck); err="$dir/send.err"
  make_doorbell_region_stub "$dir"
  line="Firstmate instruction waiting: list $dir/home/state/t1.inbox/*.msg and, in numeric order, read and act on each, then mv each handled file to $dir/home/state/t1.inbox/handled/."
  screen="$dir/screen"; region="$dir/region"
  cursor=$(write_doorbell_box "$screen" "$region" 2 "$line")
  run_send "$dir" "$err" FM_FAKE_TMUX_SCREEN="$screen" \
    FM_FAKE_TMUX_JOINED_CAPTURE="$region" FM_FAKE_TMUX_REGION_START=1 \
    FM_FAKE_TMUX_REGION_END=3 FM_FAKE_TMUX_CURSOR="$cursor" \
    FM_FAKE_TMUX_CLEAR_ON_ENTER=0 FM_FAKE_TMUX_ENTER_COUNT="$dir/enter-count" -- \
    t1 "steer behind a non-clearing composer"; rc=$?
  expect_code 0 "$rc" "a non-clearing composer should keep the durable steer successful"
  [ "$(cat "$dir/enter-count")" = 1 ] \
    || fail "a non-clearing composer received more than one Enter: $(cat "$dir/enter-count")"
  assert_contains "$(cat "$err")" "doorbell did not reach" \
    "a composer that stayed populated should report failed submission"
  pass "fm-send inbox: an existing doorbell gets one Enter and reports when the composer stays populated"
}
test_failed_ring_is_still_sent() {
  local dir err rc
  dir=$(setup_case ringfail); err="$dir/send.err"
  run_send "$dir" "$err" FM_FAKE_TMUX_SEND_FAIL=1 -- t1 "steer into a dead pane"; rc=$?
  expect_code 0 "$rc" "a failed doorbell must not fail the send"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "the steer was not recorded"
  assert_contains "$(cat "$err")" "watcher will re-ring" \
    "the failed-ring notice should point at the re-ring"
  pass "fm-send inbox: a failed doorbell is still a durably sent steer"
}

test_doorbell_waits_for_full_text_not_stale_prefix() {
  local dir fakebin log captures text stale_prefix enter_line rc
  dir="$TMP_ROOT/doorbell-prefix"; fakebin="$dir/fakebin"; log="$dir/tmux.log"
  captures="$dir/captures"; stale_prefix="$dir/stale-prefix"
  mkdir -p "$dir/state" "$fakebin"
  printf 'Firstmate doorbell: read old inbox entry\n' > "$stale_prefix"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    literal=0
    enter=0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift ;;
        Enter) enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf 'type\n' >> "$FM_TMUX_LOG"
      : > "$FM_TYPED_FILE"
    elif [ "$enter" -eq 1 ]; then
      printf 'enter\n' >> "$FM_TMUX_LOG"
      : > "$FM_ENTERED_FILE"
    fi
    exit 0
    ;;
  display-message)
    printf '2\n'
    exit 0
    ;;
  capture-pane)
    n=$(cat "$FM_CAPTURE_COUNT_FILE" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$FM_CAPTURE_COUNT_FILE"
    printf 'capture:%s\n' "$n" >> "$FM_TMUX_LOG"
    if [ -e "$FM_ENTERED_FILE" ]; then
      exit 0
    fi
    if [ ! -e "$FM_TYPED_FILE" ]; then
      printf '❯ \n'
    elif [ "$n" -lt 4 ]; then
      cat "$FM_STALE_PREFIX_FILE"
    else
      printf '%s\n' "$FM_TYPED_TEXT"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  text='Firstmate doorbell: read inbox in numeric order'
  : > "$log"
  : > "$captures"
  rm -f "$dir/typed" "$dir/entered"
  rc=0
  FM_STATE_OVERRIDE="$dir/state" PATH="$fakebin:$PATH" \
    FM_TMUX_LOG="$log" FM_CAPTURE_COUNT_FILE="$captures" FM_TYPED_TEXT="$text" \
    FM_STALE_PREFIX_FILE="$stale_prefix" FM_TYPED_FILE="$dir/typed" \
    FM_ENTERED_FILE="$dir/entered" \
    bash -c '. "$1"; fm_wake_tmux_send_and_submit "seat" "$2"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$text" || rc=$?
  [ "$rc" -eq 0 ] || fail "doorbell helper returned $rc"
  enter_line=$(awk '$0 == "enter" { print NR; exit }' "$log")
  [ "$(cat "$captures")" -ge 3 ] || fail "doorbell helper submitted before the full text appeared: $(cat "$log")"
  [ "$enter_line" -ge 5 ] || fail "doorbell helper sent Enter before the full text read-back: $(cat "$log")"
  pass "doorbell helper waits for the full pasted text instead of a stale prefix"
}

test_doorbell_ignores_identical_text_in_transcript() {
  local dir fakebin log text enter_count rc
  dir="$TMP_ROOT/doorbell-transcript-match"; fakebin="$dir/fakebin"; log="$dir/tmux.log"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    literal=0
    enter=0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift ;;
        Enter) enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf 'type\n' >> "$FM_TMUX_LOG"
    elif [ "$enter" -eq 1 ]; then
      printf 'enter\n' >> "$FM_TMUX_LOG"
    fi
    exit 0
    ;;
  display-message)
    printf '2\n'
    exit 0
    ;;
  capture-pane)
    start=
    previous=
    for arg in "$@"; do
      if [ "$previous" = -S ]; then start=$arg; fi
      previous=$arg
    done
    if [ "$start" = 2 ]; then
      printf '❯ incomplete current composer text\n'
    else
      printf 'old transcript: %s\n' "$FM_TYPED_TEXT"
      printf '❯ incomplete current composer text\n'
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  text='Firstmate doorbell: identical transcript text'
  : > "$log"
  rc=0
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" FM_TYPED_TEXT="$text" \
    bash -c '. "$1"; fm_wake_tmux_send_and_submit "seat" "$2"' _ \
      "$ROOT/bin/fm-wake-lib.sh" "$text" || rc=$?
  [ "$rc" -ne 0 ] || fail "doorbell accepted identical transcript text as composer text"
  enter_count=$(grep -c '^enter$' "$log" || true)
  [ "$enter_count" = 0 ] || fail "doorbell submitted unrelated composer input after a transcript match"
  pass "doorbell matches only the current composer line, not identical transcript text"
}

test_doorbell_never_submits_when_full_text_never_appears() {
  local dir fakebin log enter_count rc
  dir="$TMP_ROOT/doorbell-never-appears"; fakebin="$dir/fakebin"; log="$dir/tmux.log"
  mkdir -p "$dir/state" "$fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  send-keys)
    literal=0
    enter=0
    shift
    while [ "$#" -gt 0 ]; do
      case "$1" in
        -l) literal=1; shift ;;
        Enter) enter=1; shift ;;
        *) shift ;;
      esac
    done
    if [ "$literal" -eq 1 ]; then
      printf 'type\n' >> "$FM_TMUX_LOG"
    elif [ "$enter" -eq 1 ]; then
      printf 'enter\n' >> "$FM_TMUX_LOG"
    fi
    exit 0
    ;;
  display-message)
    printf '2\n'
    exit 0
    ;;
  capture-pane)
    printf '❯ text that never becomes the requested doorbell\n'
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/sleep"
  : > "$log"
  rc=0
  PATH="$fakebin:$PATH" FM_TMUX_LOG="$log" \
    bash -c '. "$1"; fm_wake_tmux_send_and_submit "seat" "Firstmate doorbell: never appears"' _ \
      "$ROOT/bin/fm-wake-lib.sh" || rc=$?
  [ "$rc" -ne 0 ] || fail "doorbell reported success when the full text never appeared"
  enter_count=$(grep -c '^enter$' "$log" || true)
  [ "$enter_count" = 0 ] || fail "doorbell sent Enter without seeing the full text"
  pass "doorbell reports failure and does not submit when the full text never appears"
}

test_harness_invocations_stay_typed() {
  local dir err typed
  # A slash command must reach the harness's own parser, on any harness.
  dir=$(setup_case slash); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 "/no-mistakes" || fail "a slash send should succeed"
  typed=$(cat "$dir/send.log")
  assert_contains "$typed" "/no-mistakes" "the slash command should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a slash command must not be routed to the inbox"
  # A codex `$<skill>` invocation likewise stays typed.
  dir=$(setup_case codexskill codex); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$no-mistakes' || fail "a codex \$skill send should succeed"
  assert_contains "$(cat "$dir/send.log")" '$no-mistakes' "the codex \$skill should be typed literally"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a codex \$skill must not be routed to the inbox"
  # The same `$` message to a non-codex harness is plain text: inbox plane.
  dir=$(setup_case dollartext claude); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 '$5/month is cheap' || fail "a claude \$-text send should succeed"
  [ -f "$dir/home/state/t1.inbox/001.msg" ] || fail "a non-codex \$-message should ride the inbox"
  case "$(cat "$dir/send.log")" in
    *'$5/month'*) fail "a non-codex \$-message payload was typed" ;;
  esac
  pass "fm-send planes: slash and codex \$skill invocations stay typed; plain \$-text rides the inbox"
}

test_explicit_target_stays_typed() {
  local dir err
  dir=$(setup_case explicit); err="$dir/send.err"
  run_send "$dir" "$err" -- sess:win "hello there" || fail "an explicit-target send should succeed"
  assert_contains "$(cat "$dir/send.log")" "hello there" \
    "an explicit backend target should receive the literal text"
  [ -z "$(find "$dir/home/state" -maxdepth 1 -name '*.inbox' -print 2>/dev/null)" ] \
    || fail "an explicit target has no task record here and must not grow an inbox"
  pass "fm-send planes: an explicit backend target keeps the typed plane"
}

test_key_path_never_touches_inbox() {
  local dir err
  dir=$(setup_case keypath); err="$dir/send.err"
  run_send "$dir" "$err" -- t1 --key Enter || fail "a --key send should succeed"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "the --key path must never write an inbox record"
  pass "fm-send planes: the --key lifecycle path never touches the inbox"
}

test_secondmate_marker_and_enqueue_delivery() {
  local dir err body corr pr_rec delivered
  dir=$(setup_case secondmate); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  run_send "$dir" "$err" -- fm-domain "please summarize fleet health" \
    || fail "a secondmate steer should succeed"
  body=$(record_body _ "$dir/home/state/domain.inbox/001.msg")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "the recorded body lost the from-firstmate marker/corr framing:"$'\n'"$body" ;;
  esac
  corr=$(printf '%s' "$body" | grep -oE 'corr=[a-f0-9]{16}' | head -1 | cut -d= -f2)
  [ -n "$corr" ] || fail "no corr token in the recorded body"
  pr_rec="$dir/home/state/pending-replies/$corr"
  [ -f "$pr_rec" ] || fail "no pending-reply expectation was recorded at $pr_rec"
  delivered=$(grep '^delivered_epoch=' "$pr_rec" | cut -d= -f2)
  [ -n "$delivered" ] || fail "enqueue IS delivery: delivered_epoch should be set at enqueue time:"$'\n'"$(cat "$pr_rec")"
  case "$(cat "$dir/send.log")" in
    *"summarize fleet health"*) fail "the marked payload was typed" ;;
  esac
  pass "fm-send inbox: a secondmate steer records marker+corr in the body and is delivered at enqueue"
}

test_post_enqueue_bookkeeping_failure_is_not_retryable() {
  local dir err rc rec body
  dir=$(setup_case bookkeeping-failure); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
set -u
source_arg=${@: -2:1}
target_arg=${@: -1}
if [ "${FM_FAIL_DELIVERY_CONFIRM:-0}" = 1 ] \
  && grep -q '^confirmed=' "$source_arg" 2>/dev/null; then
  # Simulate losing both the delivery commit and its prepared recovery marker.
  rm -f "$target_arg"
  exit 1
fi
exec /bin/mv "$@"
SH
  chmod +x "$dir/fakebin/mv"

  run_send "$dir" "$err" FM_FAIL_DELIVERY_CONFIRM=1 -- domain "durable once"; rc=$?
  # The durable record IS the delivery: even with the commit AND its recovery
  # marker both lost, the steer was delivered, so fm-send must not signal a
  # status that invites a resend (a nonzero would make automated callers
  # enqueue the same instruction again under a new sequence). The degradation
  # surfaces as its own distinct do-not-resend condition instead.
  expect_code 0 "$rc" "a delivered steer must not report a resend-inviting failure over lost bookkeeping"
  rec="$dir/home/state/domain.inbox/001.msg"
  [ -f "$rec" ] || fail "bookkeeping failure test did not durably enqueue the steer"
  [ "$(find "$dir/home/state/domain.inbox" -maxdepth 1 -name '*.msg' | wc -l | tr -d ' ')" = 1 ] \
    || fail "the delivered steer was duplicated:"$'\n'"$(ls "$dir/home/state/domain.inbox")"
  body=$(record_body _ "$rec")
  case "$body" in
    "$FM_FROMFIRST_MARK"corr=*) : ;;
    *) fail "bookkeeping failure test lost the secondmate marker: $body" ;;
  esac
  assert_contains "$(cat "$err")" "reply-tracking-degraded" \
    "lost bookkeeping should surface as its own distinct degraded condition"
  assert_contains "$(cat "$err")" "do not resend" \
    "the degraded condition should give explicit do-not-resend guidance"
  assert_contains "$(cat "$err")" "durably recorded at" \
    "the degraded condition should name the already-delivered record"
  pass "fm-send inbox: lost reply bookkeeping never invites a resend, and the delivered steer is never duplicated"
}

test_meta_lock_contention_fails_bounded() {
  local dir err rc holder marker lock i
  dir=$(setup_case meta-lock); err="$dir/send.err"
  marker="$dir/meta-lock-held"
  lock="$dir/home/state/.meta-t1.lock"
  bash -c '
    . "$1"
    fm_lock_acquire_wait "$2"
    touch "$3"
    sleep 30
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$lock" "$marker" &
  holder=$!
  i=0
  while [ ! -e "$marker" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$marker" ] || { kill "$holder" 2>/dev/null; fail "the metadata lock holder did not start"; }
  run_send "$dir" "$err" FM_TASK_INBOX_LOCK_WAIT_SECS=0 -- t1 "must not hang"; rc=$?
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$rc" -ne 0 ] || fail "metadata lock contention should fail after the bounded wait"
  [ ! -d "$dir/home/state/t1.inbox" ] || fail "a lock refusal must not enqueue a record"
  assert_contains "$(cat "$err")" "metadata could not be locked" \
    "the bounded metadata lock refusal should be explicit"
  pass "fm-send inbox: metadata lock contention fails bounded without enqueue"
}

test_unwritable_inbox_fails_loudly() {
  local dir err rc
  dir=$(setup_case unwritable); err="$dir/send.err"
  fm_write_secondmate_meta "$dir/home/state/domain.meta" "$dir/home" "sess:fm-domain"
  : > "$dir/home/state/domain.inbox"   # a FILE where the inbox dir must go
  run_send "$dir" "$err" -- fm-domain "this cannot be recorded"; rc=$?
  [ "$rc" -ne 0 ] || fail "an unwritable inbox must fail the send"
  assert_contains "$(cat "$err")" "inbox record could not be written" \
    "the failure should name the unwritable inbox"
  [ ! -s "$dir/send.log" ] || fail "a failed enqueue still typed something:"$'\n'"$(cat "$dir/send.log")"
  [ -z "$(find "$dir/home/state/pending-replies" -type f -not -name '.*' 2>/dev/null)" ] \
    || fail "a failed enqueue should discard the just-created pending-reply expectation"
  pass "fm-send inbox: an unwritable record is a loud local failure that leaves no false expectation"
}

test_text_steer_rides_inbox
test_multiline_steer_is_legal
test_resend_enqueues_new_sequence
test_pending_composer_skips_ring_advisorily
test_pending_multiline_human_text_stays_protected
test_pending_own_doorbell_submits_wrapped_and_mixed_text
test_existing_doorbell_enter_is_at_most_once
test_failed_ring_is_still_sent
test_doorbell_waits_for_full_text_not_stale_prefix
test_doorbell_ignores_identical_text_in_transcript
test_doorbell_never_submits_when_full_text_never_appears
test_harness_invocations_stay_typed
test_explicit_target_stays_typed
test_key_path_never_touches_inbox
test_secondmate_marker_and_enqueue_delivery
test_post_enqueue_bookkeeping_failure_is_not_retryable
test_meta_lock_contention_fails_bounded
test_unwritable_inbox_fails_loudly
