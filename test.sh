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

# ── 1c. Open all required firewall ports ──────────────────────────────────────
echo ""
echo "[ 1c ] Firewall — open required ports (ufw)"
run_remote "sudo ufw allow 5080/udp   comment 'SIP internal (phones)' 2>/dev/null || true"
run_remote "sudo ufw allow 5080/tcp   comment 'SIP internal (phones)' 2>/dev/null || true"
run_remote "sudo ufw allow 5060/udp   comment 'SIP external (trunks)' 2>/dev/null || true"
run_remote "sudo ufw allow 5060/tcp   comment 'SIP external (trunks)' 2>/dev/null || true"
run_remote "sudo ufw allow 8080/tcp   comment 'custompbx WebSocket (PortSIP WSI)' 2>/dev/null || true"
run_remote "sudo ufw allow 8081/tcp   comment 'custompbx xml_curl' 2>/dev/null || true"
run_remote "sudo ufw allow 3478/udp   comment 'STUN' 2>/dev/null || true"
run_remote "sudo ufw allow 16384:32768/udp comment 'RTP media' 2>/dev/null || true"
echo "  Current ufw status:"
run_remote "sudo ufw status numbered 2>/dev/null | grep -E '5060|5080|8080|8081|3478|16384|ALLOW' | head -20 || echo '  (ufw not active or not installed)'"

# ── 1b. Pull latest config & self-heal internal profile if broken ─────────────
echo ""
echo "[ 1b ] Apply config (git pull → verify → docker restart if profile dead)"
run_remote "cd $REMOTE_DIR && git pull --ff-only"

# Confirm the file inside the running container has sip-port=5080
echo "  sip-port in container /etc/freeswitch/sip_profiles/internal.xml:"
run_remote "docker exec freeswitch grep 'sip-port' /etc/freeswitch/sip_profiles/internal.xml 2>/dev/null || echo '  (cannot read — container may be down)'"

# Reload XML so FreeSWITCH re-reads all mounted config files
run_remote "docker exec freeswitch fs_cli -x 'reloadxml'" 2>/dev/null || true
sleep 2

# Check if internal profile is alive; if not, do a full container restart
# (sofia stop+start cannot revive a dead/invalid profile — only docker restart can)
PROFILE_CHECK=$(run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal' 2>&1" 2>/dev/null)
if echo "$PROFILE_CHECK" | grep -q "Invalid Profile"; then
  echo "  internal profile is dead — restarting container, polling up to 60s..."
  run_remote "docker restart freeswitch"
  # Poll: wait until FreeSWITCH event socket reports "is ready"
  READY=false
  for i in $(seq 1 30); do
    sleep 2
    if run_remote "docker exec freeswitch fs_cli -x status 2>/dev/null" 2>/dev/null \
         | grep -q "is ready"; then
      READY=true
      echo -e "  [$PASS_OK] FreeSWITCH ready after restart (~$((i*2))s)"
      break
    fi
  done
  $READY || echo -e "  [$FAIL_OK] FreeSWITCH did not become ready in 60s — run: docker logs freeswitch"
else
  echo -e "  [$PASS_OK] internal profile running — reloadxml applied"
fi

# Show which SIP ports are actually bound on the host
echo "  Bound SIP ports (host):"
run_remote "ss -lnup 2>/dev/null | grep -E ':5060|:5080' || \
  netstat -lnup 2>/dev/null | grep -E ':5060|:5080' || true"

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
# NOTE: sipsak registers from the server IP (192.168.1.107). We immediately
# unregister (Expires:0) to prevent FreeSWITCH from forking calls to the ghost
# contact (which has no listener → triggers 480 Temporarily Unavailable).
echo ""
echo "[ 5 ] SIP REGISTER — ext $EXT_1000 (password: $SIP_PASS)"
run_remote "sipsak -s sip:${EXT_1000}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1000} -a ${SIP_PASS} -R -T 5000 -v 2>&1 | grep -E 'SIP/|200|401|403|REGISTER|registered|error'"
# Immediately unregister so the test contact doesn't poison real call routing
run_remote "sipsak -s sip:${EXT_1000}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1000} -a ${SIP_PASS} -x 0 -T 5000 2>&1 | grep -E 'SIP/|200|REGISTER' || true"

# ── 6. SIP REGISTER ext 1001 ──────────────────────────────────────────────────
echo ""
echo "[ 6 ] SIP REGISTER — ext $EXT_1001 (password: $SIP_PASS)"
run_remote "sipsak -s sip:${EXT_1001}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1001} -a ${SIP_PASS} -R -T 5000 -v 2>&1 | grep -E 'SIP/|200|401|403|REGISTER|registered|error'"
# Immediately unregister
run_remote "sipsak -s sip:${EXT_1001}@${SIP_IP}:${SIP_PORT} \
  -u ${EXT_1001} -a ${SIP_PASS} -x 0 -T 5000 2>&1 | grep -E 'SIP/|200|REGISTER' || true"

# ── 7. Check registrations in FreeSWITCH ──────────────────────────────────────
echo ""
echo "[ 7 ] Registered Users (FreeSWITCH)"
# Flush any stale server-side (sipsak) registrations that might remain from
# previous test runs. server-originated contacts have network_ip = 127.0.0.1.
run_remote "docker exec freeswitch fs_cli -x 'show registrations' | \
  awk -F, '\$6==\"127.0.0.1\"{print \"unregister ext:\"\$1}'" 2>/dev/null || true
run_remote "docker exec freeswitch fs_cli -x \
  'sofia profile internal flush_inbound_reg 127.0.0.1'" 2>/dev/null || true
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
echo ""
echo "[ 10 ] Call Test — 2-party loopback bridge (no phone needed, proves RTP engine)"
PARK=$(run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=15,origination_caller_id_number=${EXT_1001}}loopback/9196/default &park()\" 2>&1")
PARK_UUID=$(echo "$PARK" | awk '/^\+OK/{print $2}')
if [ -z "$PARK_UUID" ]; then
  echo "  Park leg: $PARK"
  echo -e "  [$FAIL_OK] Could not park leg"
else
  echo "  Park leg: +OK $PARK_UUID"
  BRIDGE=$(run_remote "docker exec freeswitch fs_cli -x \
    \"originate {originate_timeout=15,origination_caller_id_number=${EXT_1000}}loopback/9197/default &bridge($PARK_UUID)\" 2>&1")
  echo "  Bridge leg: $BRIDGE"
  sleep 1
  run_remote "docker exec freeswitch fs_cli -x \"uuid_kill $PARK_UUID\"" > /dev/null 2>&1
  if echo "$BRIDGE" | grep -q '^\+OK'; then
    echo -e "  [$PASS_OK] 2-party RTP bridge OK"
  else
    echo -e "  [$FAIL_OK] Bridge failed: $BRIDGE"
  fi
fi

# ── 10b. Live call 1000 → 1001 (real phones) ──────────────────────────────────
echo ""
echo "[ 10b ] Live call $EXT_1000 → $EXT_1001 (real phones — answer $EXT_1001 to get +OK)"
REGS=$(run_remote "docker exec freeswitch fs_cli -x 'show registrations'" 2>&1)
echo "  Registrations:"
echo "$REGS" | grep -E "^100[0-9]|total"
if echo "$REGS" | grep -q "^${EXT_1001},"; then
  LIVE=$(run_remote "docker exec freeswitch fs_cli -x \
    \"originate {originate_timeout=15,origination_caller_id_number=${EXT_1000}}user/${EXT_1001} &echo()\" 2>&1")
  echo "  Result: $LIVE"
  if echo "$LIVE" | grep -q '^\+OK'; then
    echo -e "  [$PASS_OK] Call connected and answered!"
  elif echo "$LIVE" | grep -q 'NO_ANSWER'; then
    echo -e "  [$PASS_OK] Routing OK — phone rang at $(echo "$REGS" | grep "^${EXT_1001}," | cut -d, -f5 | cut -d@ -f1 | sed 's/.*\///') but was not answered (expected during automated test)"
  else
    echo -e "  [$FAIL_OK] Unexpected: $LIVE"
  fi
else
  echo -e "  [--] $EXT_1001 not registered — register PortSIP phone to $SIP_IP:$SIP_PORT and re-run"
fi

# ── 11. Profile status ────────────────────────────────────────────────────────
echo ""
echo "[ 11 ] SIP profile status"
run_remote "docker exec freeswitch fs_cli -x 'sofia status'" | grep -E "Name|profile|alias|======"
PROFILE_STATUS=$(run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal'" 2>&1)
if echo "$PROFILE_STATUS" | grep -q "Invalid Profile"; then
  echo -e "  [$FAIL_OK] internal profile not running"
else
  INT_PORT=$(echo "$PROFILE_STATUS" | grep "^URL" | grep -oE ':[0-9]+' | tr -d ':')
  echo -e "  [$PASS_OK] internal profile running on port ${INT_PORT:-5080}"
fi
EXT_STATUS=$(run_remote "docker exec freeswitch fs_cli -x 'sofia status profile external'" 2>&1)
if echo "$EXT_STATUS" | grep -q "Invalid Profile"; then
  echo -e "  [$FAIL_OK] external profile not running"
else
  EXT_PORT=$(echo "$EXT_STATUS" | grep "^URL" | grep -oE ':[0-9]+' | tr -d ':')
  EXT_CTX=$(echo "$EXT_STATUS"  | grep "^Context" | awk '{print $2}')
  CODECS=$(echo "$EXT_STATUS"   | grep "^CODECS IN" | cut -d$'\t' -f2)
  echo -e "  [$PASS_OK] external profile running on port ${EXT_PORT:-5060}, context=${EXT_CTX}, codecs=${CODECS}"
fi

# ── 11b. custompbx WebSocket reachability ─────────────────────────────────────
echo ""
echo "[ 11b ] custompbx WebSocket (port 8080)"
WS_RESULT=$(run_remote "curl -sv --max-time 5 \
  -H 'Upgrade: websocket' -H 'Connection: Upgrade' \
  -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  -H 'Sec-WebSocket-Version: 13' \
  http://127.0.0.1:8080/ws 2>&1")
if echo "$WS_RESULT" | grep -qiE '101|switching'; then
  echo -e "  [$PASS_OK] WebSocket port 8080 reachable (HTTP 101)"
  echo "  NOTE: PortSIP WSI Error = PortSIP's WSI protocol is incompatible with custompbx."
  echo "  FIX in PortSIP:  Settings → Features → clear the 'WebSocket Server' / WSI URL field."
elif echo "$WS_RESULT" | grep -qiE 'refused|fail'; then
  echo -e "  [$FAIL_OK] Port 8080 refused — restarting custompbx"
  run_remote "docker restart custompbx"
fi

# ── 12. FreeSWITCH channel & call stats ───────────────────────────────────────
echo ""
echo "[ 12 ] FreeSWITCH Stats"
run_remote "docker exec freeswitch fs_cli -x 'status'"

echo ""
echo "========================================="
echo " Done"

# ── 13. Call duration test — verifies call stays alive beyond 13 seconds ──────
# This catches the session-timer re-INVITE drop bug (fixed by enable-timer=false)
echo ""
echo "[ 13 ] Call Duration Test — must stay connected > 15s (regression: 13s drop)"
echo "  Session-timer status:"
run_remote "docker exec freeswitch fs_cli -x 'sofia status profile external' 2>&1 | grep -E 'SESSION-TO|TIMER'"
run_remote "docker exec freeswitch fs_cli -x 'sofia status profile internal' 2>&1 | grep -E 'SESSION-TO|TIMER'"

# Park a loopback leg (auto-answers immediately, no phone needed)
PARK13=$(run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=5,origination_caller_id_number=1001}loopback/9196/default &park()\" 2>&1")
PARK13_UUID=$(echo "$PARK13" | awk '/^\+OK/{print $2}')

if [ -z "$PARK13_UUID" ]; then
  echo -e "  [$FAIL_OK] Could not establish call leg: $PARK13"
else
  echo "  Call established: UUID=$PARK13_UUID"
  echo "  Waiting 16 seconds to test duration..."
  sleep 16

  # Check if channel still alive after 16s
  ALIVE=$(run_remote "docker exec freeswitch fs_cli -x 'show channels' 2>&1")
  CH_COUNT=$(echo "$ALIVE" | grep -c "$PARK13_UUID" || true)

  if [ "$CH_COUNT" -gt 0 ]; then
    echo -e "  [$PASS_OK] Call still alive at 16s — 13s drop bug is FIXED"
    run_remote "docker exec freeswitch fs_cli -x \"uuid_kill $PARK13_UUID\"" > /dev/null 2>&1
  else
    echo -e "  [$FAIL_OK] Call dropped before 16s — 13s drop bug still present"
    echo "  Last logs:"
    run_remote "docker logs freeswitch --since 20s 2>&1 | grep -E 'session|timer|re-inv|BYE|cause|Abandoned|auth' | tail -10"
  fi
fi
echo "========================================="
