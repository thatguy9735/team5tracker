#!/usr/bin/env bash
# Team 5 tracker health check. Tests the ACTUAL paths the app uses:
# the page GitHub serves, the script CDNs, and the live database rules.
# Exit 0 = all pass, 1 = something failed. Report goes to stdout and $GITHUB_STEP_SUMMARY.
set -u
SITE="${SITE:-https://thatguy9735.github.io/team5tracker/}"
DB="${DB:-https://team-5-tracker-default-rtdb.firebaseio.com}"
WAIT_FOR_DEPLOY="${WAIT_FOR_DEPLOY:-0}"
REPORT="$(mktemp)"; FAILS=0
pass(){ echo "| ✅ PASS | $1 | $2 |" >>"$REPORT"; }
fail(){ echo "| ❌ FAIL | $1 | $2 |" >>"$REPORT"; FAILS=$((FAILS+1)); }
# curl helper: prints "HTTPCODE BODY"
req(){ local m="$1" u="$2" d="${3:-}"; local out code
  if [ -n "$d" ]; then out=$(curl -s -m 20 -X "$m" -d "$d" -w $'\n%{http_code}' "$u"); else out=$(curl -s -m 20 -X "$m" -w $'\n%{http_code}' "$u"); fi
  code="${out##*$'\n'}"; echo "$code ${out%$'\n'*}" | tr -d '\n' | cut -c1-160; }
denied(){ [[ "$1" == 401* ]] && [[ "$1" == *"Permission denied"* ]]; }

echo "| Result | Check | Detail |" >"$REPORT"; echo "|---|---|---|" >>"$REPORT"

# 1. The page GitHub serves is byte-identical to index.html in the repo
want=$(sha256sum index.html | cut -c1-64); got=""; tries=1
[ "$WAIT_FOR_DEPLOY" = 1 ] && tries=20
for i in $(seq 1 $tries); do
  got=$(curl -s -m 20 "${SITE}?v=$(date +%s%N)" | sha256sum | cut -c1-64)
  [ "$got" = "$want" ] && break
  [ "$i" -lt "$tries" ] && sleep 30
done
[ "$got" = "$want" ] && pass "Live site serves the committed build" "sha256 ${want:0:12}" \
  || fail "Live site serves the committed build" "repo ${want:0:12} vs served ${got:0:12} (deploy stuck or site down)"

# 2. At least one script CDN is reachable (the app falls back from gstatic to jsdelivr)
g=$(curl -s -o /dev/null -m 20 -w '%{http_code}' https://www.gstatic.com/firebasejs/10.7.1/firebase-database-compat.js)
j=$(curl -s -o /dev/null -m 20 -w '%{http_code}' https://cdn.jsdelivr.net/npm/firebase@10.7.1/firebase-database-compat.js)
{ [ "$g" = 200 ] || [ "$j" = 200 ]; } && pass "Firebase SDK reachable" "gstatic $g, jsdelivr $j" || fail "Firebase SDK reachable" "gstatic $g, jsdelivr $j"

# 3a-f. Database rules behave exactly as intended. ROOM_ID is the team room id (GitHub secret, never printed).
# The Actions log is public on a public repo: report HTTP status codes only, never response bodies.
ROOM_ID="${ROOM_ID:-}"
if [ -z "$ROOM_ID" ]; then
  fail "a. Team room readable" "ROOM_ID secret is not set (Settings > Secrets and variables > Actions)"
  fail "b. Team room writable" "ROOM_ID secret is not set"
else
  r=$(req GET "$DB/rooms/$ROOM_ID/meta.json")
  [[ "$r" == 200* ]] && [[ "$r" != "200 null" ]] && pass "a. Team room readable" "room exists" || fail "a. Team room readable" "HTTP ${r%% *} (room missing or rules changed)"
  p=$(req PUT "$DB/rooms/$ROOM_ID/_healthprobe.json" '"x"'); req DELETE "$DB/rooms/$ROOM_ID/_healthprobe.json" >/dev/null; after=$(req GET "$DB/rooms/$ROOM_ID/_healthprobe.json")
  [[ "$p" == 200* ]] && [[ "$after" == "200 null" ]] && pass "b. Team room writable" "write, delete, confirm gone" || fail "b. Team room writable" "write HTTP ${p%% *}, read-back HTTP ${after%% *}"
fi
r=$(req GET "$DB/rooms.json?shallow=true");   denied "$r" && pass "c. Room list hidden" "denied as expected" || fail "c. Room list hidden" "expected 401, got HTTP ${r%% *}"
r=$(req GET "$DB/t5q4/settings.json");        denied "$r" && pass "d. Old unlocked path closed" "denied as expected" || fail "d. Old unlocked path closed" "expected 401, got HTTP ${r%% *}"
r=$(req GET "$DB/t5/state.json?shallow=true"); denied "$r" && pass "e. Spring archive closed" "denied as expected" || fail "e. Spring archive closed" "expected 401, got HTTP ${r%% *}"
r=$(req GET "$DB/_rootprobe.json");            denied "$r" && pass "f. Everything else closed" "denied as expected" || fail "f. Everything else closed" "expected 401, got HTTP ${r%% *}"

cat "$REPORT"; [ -n "${GITHUB_STEP_SUMMARY:-}" ] && { echo "## Tracker health check"; cat "$REPORT"; } >>"$GITHUB_STEP_SUMMARY"
cp "$REPORT" health-report.md
echo; [ "$FAILS" -eq 0 ] && echo "ALL PASS" || echo "$FAILS FAILED"
[ "$FAILS" -eq 0 ]
