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

# ── 8. Call test: loopback → park (validates dialplan routing) ────────────────
echo ""
echo "[ 8 ] Call Test — loopback originate → park (dialplan check)"
run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=15}loopback/9196/default &echo()\" 2>&1"

# ── 9. Call test: 1000 → 1001 user bridge (both registered via sipsak) ─────────
echo ""
echo "[ 9 ] Call Test — originate 1000 → 1001 (expects SUBSCRIBER_ABSENT if not live)"
run_remote "docker exec freeswitch fs_cli -x \
  \"originate {originate_timeout=10}user/${EXT_1000} ${EXT_1001} XML default\" 2>&1"

# ── 10. FreeSWITCH channel & call stats ───────────────────────────────────────
echo ""
echo "[ 10 ] FreeSWITCH Stats"
run_remote "docker exec freeswitch fs_cli -x 'status'"

echo ""
echo "========================================="
echo " Done"
echo "========================================="
