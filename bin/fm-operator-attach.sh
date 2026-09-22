#!/bin/sh
# fm-operator-attach.sh — lets ANY Claude Code session be the company operator without living in tmux.
# Run it as a BACKGROUND command from the operator session. It blocks, watching the seats, the Bridge and
# the operator inbox, and EXITS the moment something needs the operator (a lead reports done/blocked/
# needs-decision, a Bridge answer arrives, a seat stalls, an inbox order lands, the Intel Mac answers, or
# an hour passes). The harness wakes the session when a background command exits; the session reads the
# printed event, acts, and relaunches this script. It also self-heals the seats: rings stuck doorbells,
# interrupts a lead whose inbox has sat unread. This is the runtime's own attach point; do not write another
# watcher outside it. (2026-09-22, from the failed night: the operator must be woken by the runtime.)
W=${FM_OPERATOR_STATE:-$HOME/.local/share/latent-sea-company/firstmate-watch}
S=$HOME/.local/share/latent-sea-company/runtime-staging/primary/state
C=/Users/jordanhindo/latent-sea-company/company
FMH=$HOME/.local/share/latent-sea-company/runtime-staging/primary
FMROOT=$HOME/.local/share/latent-sea-company-tools/firstmate-1492153
export LATENT_SEA_COMPANY_STATE=$HOME/.local/share/latent-sea-company/runtime-staging/records LATENT_SEA_COMPANY_ROOT=$C
SEATS="product-and-release demand-and-brand"   # demand is running ONE narrow job (site layout fix), 2026-09-21
STALL_MIN=${STALL_MIN:-40}      # a lead with no status line for this long = stall
HEARTBEAT_MIN=${HEARTBEAT_MIN:-55}
NODE=/Users/jordanhindo/.nvm/versions/node/v24.14.0/bin/node
start=$(date +%s)
for s in $SEATS; do [ -f $W/$s.lines ] || wc -l < $S/$s.status | tr -d ' ' > $W/$s.lines; done
fire() { echo "WATCHDOG EVENT $(date '+%a %H:%M'): $1"; shift; [ $# -gt 0 ] && printf '%s\n' "$@"; exit 0; }
while :; do
  for s in $SEATS; do
    have=$(cat $W/$s.lines); now=$(wc -l < $S/$s.status | tr -d ' ')
    if [ "$now" -gt "$have" ]; then
      new=$(tail -n $((now-have)) $S/$s.status)
      echo "$now" > $W/$s.lines
      # Worker roll-up lines (child-outcome-*) are routine; only the lead's own lines wake Firstmate.
      hot=$(printf '%s\n' "$new" | grep -v -E 'key=(child-outcome|inactive-outcome)-' | grep -E '^(needs-decision|blocked|failed)|^done \[corr=.*(ready|delivered|landed|Desktop|opened|merged)|URGENT|awaits? Jordan|needs Jordan|captain-held' | cut -c1-400)
      [ -n "$hot" ] && fire "$s reported something that needs Firstmate" "$hot"
    fi
    age=$(( ( $(date +%s) - $(stat -f %m $S/$s.status) ) / 60 ))
    last=$(cat $W/$s.stall-ack 2>/dev/null || echo 0)
    if [ "$age" -ge "$STALL_MIN" ] && [ $(( $(date +%s) - last )) -ge $((STALL_MIN*60)) ]; then
      date +%s > $W/$s.stall-ack
      fire "$s has been silent for $age minutes (stall)" "$(tmux capture-pane -p -t firstmate:fm-$s 2>/dev/null | grep -v '^\s*$' | tail -4 | cut -c1-200)"
    fi
    tmux list-windows -t firstmate -F '#{window_name}' 2>/dev/null | grep -qx "fm-$s" || fire "$s lead window is gone"
    # Runtime defect found 2026-09-21: fm-send types its doorbell into a Claude lead's input box but the
    # Enter lands too early, so instructions sit unsent and unread. If the lead is idle with a doorbell
    # waiting and unread messages exist, press Enter for it.
    unread=$(ls $S/$s.inbox/*.msg 2>/dev/null | wc -l | tr -d ' ')
    if [ "$unread" -gt 0 ]; then
      p2=$(tmux capture-pane -p -t firstmate:fm-$s 2>/dev/null | tail -12)
      oldest=$(ls -t $S/$s.inbox/*.msg 2>/dev/null | tail -1)
      uage=$(( ( $(date +%s) - $(stat -f %m "$oldest") ) / 60 ))
      if printf '%s' "$p2" | grep -q "esc to interrupt"; then
        # Lead is mid-turn (often a long tool call); a queued doorbell only submits when the turn ends.
        # After 5 minutes unread, interrupt so the queue drains (2026-09-22: 8h and 40m stalls came from this).
        if [ "$uage" -ge 5 ] && [ $(( $(date +%s) - $(cat $W/$s.int-ack 2>/dev/null || echo 0) )) -ge 600 ]; then
          date +%s > $W/$s.int-ack
          FM_HOME=$FMH $FMROOT/bin/fm-control.sh $s interrupt >/dev/null 2>&1
          sleep 6
        fi
      fi
      p2=$(tmux capture-pane -p -t firstmate:fm-$s 2>/dev/null | tail -12)
      if ! printf '%s' "$p2" | grep -q "esc to interrupt"; then
        # Idle with unread mail: type the doorbell ourselves and submit it. Text-agnostic (fm-send's own
        # line may never have landed); a settle before Enter so Claude's composer does not eat it.
        tmux send-keys -t firstmate:fm-$s -l "Firstmate doorbell: read $S/$s.inbox/*.msg in numeric order, act on each, then mv each handled file to $S/$s.inbox/handled/."
        sleep 1.5
        tmux send-keys -t firstmate:fm-$s Enter
      fi
    fi
    # Known silent killers, caught by name instead of waiting 40 minutes: quota, sleep, provider errors.
    pane=$(tmux capture-pane -p -t firstmate:fm-$s 2>/dev/null | tail -12)
    cause=$(printf '%s' "$pane" | grep -o -E "hit your usage limit|went to sleep mid-response|API Error[^.]*|Login expired|rate limit" | head -1)
    if [ -n "$cause" ] && [ "$cause" != "$(cat $W/$s.cause 2>/dev/null)" ]; then
      printf '%s' "$cause" > $W/$s.cause
      [ "$s" = demand-and-brand ] || fire "$s lead is stopped: $cause" "$(printf '%s' "$pane" | grep -v '^\s*$' | tail -4 | cut -c1-200)"
    fi
    [ -z "$cause" ] && rm -f $W/$s.cause
  done

  # Intel Mac (Chris): probe once an hour; wake Firstmate the moment it answers (Jordan: 8am then hourly).
  now=$(date +%s); lastp=$(cat $W/intel.probe 2>/dev/null || echo 0)
  if [ $(( now - lastp )) -ge 3600 ]; then
    date +%s > $W/intel.probe
    if timeout 12 ssh -o ConnectTimeout=8 -o BatchMode=yes chris@100.65.45.127 uptime >/dev/null 2>&1; then
      fire "Chris's Intel Mac is ONLINE: start the unattended install + first-sound proof (item intel-install-fix)" "ssh answered at $(date '+%H:%M')"
    fi
  fi
  b=$(cd $C && $NODE bin/company-bridge.mjs list --state all 2>/dev/null | python3 -c "
import json,sys
try: rows=json.load(sys.stdin)['result']
except Exception: print(''); raise SystemExit
out=[]
for r in rows:
  for x in r['responses']:
    if not x.get('pickedUpAt') and not str(x['messageId']).startswith('legacy-'): out.append(r['id']+' | option '+str(x.get('selectedOptionId'))+' | '+repr(x['text'])[:200])
print('\n'.join(out))")
  [ -n "$b" ] && fire "Jordan saved a Bridge answer" "$b"
  n=$(cd $C && $NODE bin/company-bridge.mjs notes list --unpicked 2>/dev/null | python3 -c "import json,sys
try: print(len(json.load(sys.stdin)['result']))
except Exception: print(0)")
  [ "${n:-0}" -gt 0 ] && fire "Jordan left $n new Bridge note(s)"
  [ $(( ( $(date +%s) - start ) / 60 )) -ge "$HEARTBEAT_MIN" ] && fire "hourly heartbeat: nothing fired; do a quick pass and relaunch"
  sleep 60
done
