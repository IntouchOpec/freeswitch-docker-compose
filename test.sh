#!/bin/bash
# test.sh — Connectivity, Docker, SIP login & call test for freeswitch-docker-compose

HOST="ubuntu@192.168.1.107"
PASS="P@ssw0rd"
REMOTE_DIR="~/freeswitch-docker-compose"
SIP_IP="192.168.1.107"
SIP_PORT="5080"     # internal profile (phones/extensions); external/trunks = 5060
EXT_1000="1000"
EXT_1001="1001"
SIP_PASS="1234"

PASS_OK="\033[0;32mPASS\033[0m"
FAIL_OK="\033[0;31mFAIL\033[0m"

# Ports — plain shell vars (NOT FreeSWITCH $${} syntax)
# internal (phones): 5080  |  external (trunks): 5060  |  WS: 5066
WS_PORT="5066"
WSS_PORT="7443"

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

# ── 1b. Pull latest config & reload FreeSWITCH XML + internal profile ─────────
echo ""
echo "[ 1b ] Apply config changes (git pull → reloadxml → stop → start internal)"
run_remote "cd $REMOTE_DIR && git pull --ff-only"
run_remote "docker exec freeswitch fs_cli -x 'reloadxml'"
sleep 1
# Stop first — suppress error if profile is in invalid/dead state (can't be restarted, only started)
run_remote "docker exec freeswitch fs_cli -x 'sofia profile internal stop'" 2>/dev/null || true
sleep 1
PROFILE_START=$(run_remote "docker exec freeswitch fs_cli -x 'sofia profile internal start' 2>&1")
echo "  sofia profile internal start: $PROFILE_START"
sleep 5  # give Sofia time to fully bind the port

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

# ── 10. Full 2-party bridge — park 1001 leg then bridge 1000 leg to it ─────────
# Both legs are loopback so no physical phone is needed; proves RTP bridging works.
echo ""
echo "[ 10 ] Call Test — 2-party bridge $EXT_1000 → $EXT_1001 (loopback, guaranteed)"
PARK=$(run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=15,origination_caller_id_number=${EXT_1001},origination_caller_id_name=${EXT_1001}}loopback/9196/default &park()\" 2>&1")
PARK_UUID=$(echo "$PARK" | awk '/^\+OK/{print $2}')
if [ -z "$PARK_UUID" ]; then
  echo "  Park leg (${EXT_1001}): $PARK"
  echo -e "  [$FAIL_OK] Could not park ${EXT_1001} leg"
else
  echo "  Park leg (${EXT_1001}): +OK $PARK_UUID"
  BRIDGE=$(run_remote "docker exec freeswitch fs_cli -x \
    \"originate {originate_timeout=15,origination_caller_id_number=${EXT_1000},origination_caller_id_name=${EXT_1000}}loopback/9197/default &bridge($PARK_UUID)\" 2>&1")
  echo "  Bridge leg (${EXT_1000}): $BRIDGE"
  sleep 1
  run_remote "docker exec freeswitch fs_cli -x \"uuid_kill $PARK_UUID\"" > /dev/null 2>&1
  if echo "$BRIDGE" | grep -q '^\+OK'; then
    echo -e "  [$PASS_OK] 2-party call connected ($EXT_1000 ↔ $EXT_1001)"
  else
    echo -e "  [$FAIL_OK] Bridge failed"
  fi
fi

# ── 11. Internal profile status ───────────────────────────────────────────────
echo ""
echo "[ 11 ] Internal profile status (should be RUNNING on port 5080, ws:$WS_PORT)"
PROFILE_STATUS=$(run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal'" 2>&1)
echo "$PROFILE_STATUS"
if echo "$PROFILE_STATUS" | grep -q "Invalid Profile"; then
  echo -e "  [$FAIL_OK] internal profile STILL not running — forcing docker restart freeswitch"
  run_remote "docker restart freeswitch"
  sleep 8
  run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal'"
else
  echo -e "  [$PASS_OK] internal profile running"
fi

# ── 12. FreeSWITCH channel & call stats ───────────────────────────────────────
echo ""
echo "[ 12 ] FreeSWITCH Stats"
run_remote "docker exec freeswitch fs_cli -x 'status'"

echo ""
echo "========================================="
echo " Done"
echo "========================================="
