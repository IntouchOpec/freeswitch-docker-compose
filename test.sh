#!/bin/bash
# test.sh — Connectivity, Docker, SIP login & call test for freeswitch-docker-compose

HOST="ubuntu@192.168.1.107"
PASS="P@ssw0rd"
REMOTE_DIR="~/freeswitch-docker-compose"
SIP_IP="192.168.1.107"
SIP_PORT="5060"
EXT_1000="1000"
EXT_1001="1001"
SIP_PASS="1234"

PASS_OK="\033[0;32mPASS\033[0m"
FAIL_OK="\033[0;31mFAIL\033[0m"

run_remote() {
  sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no "$HOST" "$1"
}

check() {
  local label="$1"; shift
  local output
  output=$("$@" 2>&1)
  local code=$?
  if [ $code -eq 0 ]; then
    echo -e "  [$PASS_OK] $label"
  else
    echo -e "  [$FAIL_OK] $label"
    echo "           $output"
  fi
}

echo "========================================="
echo " FreeSWITCH Test Suite"
echo " Remote: $HOST  |  SIP: $SIP_IP:$SIP_PORT"
echo "========================================="

# ── 1. SSH connection ──────────────────────────────────────────────────────────
echo ""
echo "[ 1 ] SSH & System"
run_remote "echo OK && uname -a"

# ── 2. Docker containers ───────────────────────────────────────────────────────
echo ""
echo "[ 2 ] Docker Containers"
run_remote "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"

# ── 3. FreeSWITCH SIP profiles ────────────────────────────────────────────────
echo ""
echo "[ 3 ] SIP Profiles"
run_remote "docker exec freeswitch fs_cli -x 'sofia status'"
run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal'"

# ── 4. SIP OPTIONS ping (server reachability) ─────────────────────────────────
echo ""
echo "[ 4 ] SIP OPTIONS Ping (server reachability)"
run_remote "sipsak -s sip:ping@${SIP_IP}:${SIP_PORT} -T 3000 -v 2>&1 | grep -E 'SIP/|200|404|403|OPTIONS|error' | head -5"

# ── 5. SIP REGISTER ext 1000 ──────────────────────────────────────────────────
echo ""
echo "[ 5 ] SIP REGISTER — ext $EXT_1000 (password: $SIP_PASS)"
run_remote "sipsak -s sip:${EXT_1000}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1000} -a ${SIP_PASS} -R -T 5000 -v 2>&1 | grep -E 'SIP/|200|401|403|REGISTER|registered|error'"

# ── 6. SIP REGISTER ext 1001 ──────────────────────────────────────────────────
echo ""
echo "[ 6 ] SIP REGISTER — ext $EXT_1001 (password: $SIP_PASS)"
run_remote "sipsak -s sip:${EXT_1001}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1001} -a ${SIP_PASS} -R -T 5000 -v 2>&1 | grep -E 'SIP/|200|401|403|REGISTER|registered|error'"

# ── 7. Check registrations in FreeSWITCH ──────────────────────────────────────
echo ""
echo "[ 7 ] Registered Users (FreeSWITCH)"
run_remote "docker exec freeswitch fs_cli -x 'show registrations'"

# ── 8. Call test: loopback → echo (validates dialplan + RTP) ─────────────────
echo ""
echo "[ 8 ] Call Test — loopback originate → echo (auto-answer, dialplan check)"
run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=15}loopback/9196/default &echo()\" 2>&1"

# ── 9. Call test: guaranteed connect — loopback B2BUA, both legs auto-answer ──
echo ""
echo "[ 9 ] Call Test — full B2BUA connect (auto-answer, expects +OK)"
OUTPUT9=$(run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=15,ignore_early_media=true}loopback/9196/default &park()\" 2>&1")
echo "  $OUTPUT9"
PARK_UUID=$(echo "$OUTPUT9" | awk '/^\+OK/{print $2}')
[ -n "$PARK_UUID" ] && \
  run_remote "docker exec freeswitch fs_cli -x \"uuid_kill $PARK_UUID\"" > /dev/null 2>&1
if echo "$OUTPUT9" | grep -q '^\+OK'; then
  echo -e "  [$PASS_OK] Call connected successfully"
else
  echo -e "  [$FAIL_OK] Call failed to connect"
fi

# ── 10. Call test: 1000 → 1001 live phone bridge (retry until +OK or 3 tries) ─
echo ""
echo "[ 10 ] Call Test — originate $EXT_1000 → $EXT_1001 (retry up to 3x)"
CALL_OK=false
for attempt in 1 2 3; do
  RESULT=$(run_remote "docker exec freeswitch fs_cli -x \
    \"originate {originate_timeout=20}user/${EXT_1000} ${EXT_1001} XML default\" 2>&1")
  echo "  Attempt $attempt/3: $RESULT"
  if echo "$RESULT" | grep -q '^\+OK'; then
    CALL_OK=true
    break
  fi
  [ "$attempt" -lt 3 ] && sleep 5
done
if $CALL_OK; then
  echo -e "  [$PASS_OK] Live call connected"
else
  echo -e "  [$FAIL_OK] Live call did not connect (phone not answered — register & answer to pass)"
fi

# ── 11. WebSocket / WebRTC profile bindings ───────────────────────────────────
echo ""
echo "[ 11 ] WebSocket / WebRTC bindings (ws:$${internal_ws_port} wss:$${internal_wss_port})"
run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal'"

# ── 12. FreeSWITCH channel & call stats ───────────────────────────────────────
echo ""
echo "[ 12 ] FreeSWITCH Stats"
run_remote "docker exec freeswitch fs_cli -x 'status'"

echo ""
echo "========================================="
echo " Done"
echo "========================================="
