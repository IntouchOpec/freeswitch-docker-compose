#!/usr/bin/env python3
"""Fetch FreeSWITCH diagnostics via SSH and save to log.txt"""
import subprocess, sys

HOST = "ubuntu@192.168.1.107"
PASS = "P@ssw0rd"

def ssh(cmd):
    r = subprocess.run(
        ["sshpass", "-p", PASS, "ssh", "-T", "-o", "StrictHostKeyChecking=no",
         "-o", "ConnectTimeout=10", HOST, cmd],
        capture_output=True, text=True, timeout=30
    )
    return r.stdout + r.stderr

out = []

out.append("=== REGISTRATIONS ===")
out.append(ssh('docker exec freeswitch fs_cli -x "show registrations"'))

out.append("=== SOFIA STATUS ===")
out.append(ssh('docker exec freeswitch fs_cli -x "sofia status"'))

out.append("=== SOFIA EXTERNAL INFO ===")
out.append(ssh('docker exec freeswitch fs_cli -x "sofia status profile external"'))

out.append("=== FS STATUS ===")
out.append(ssh('docker exec freeswitch fs_cli -x "status"'))

out.append("=== LAST 100 LOG LINES (hangup causes, errors) ===")
out.append(ssh(
    r'docker exec freeswitch fs_cli -x "console loglevel debug" 2>/dev/null; '
    r'docker exec freeswitch tail -n 200 /usr/local/freeswitch/log/freeswitch.log 2>/dev/null '
    r'|| docker exec freeswitch find / -name freeswitch.log 2>/dev/null | head -5'
))

out.append("=== LIVE TEST CALL originate user/1001 (capture hangup cause) ===")
out.append(ssh(
    'docker exec freeswitch fs_cli -x \'originate {originate_timeout=20,origination_caller_id_number=1000}user/1001@192.168.1.107 &echo()\''
))

out.append("=== CHANNELS AFTER CALL ===")
out.append(ssh('docker exec freeswitch fs_cli -x "show channels"'))

result = "\n".join(out)
print(result)
with open("diag.txt", "w") as f:
    f.write(result)
print("\n[saved to diag.txt]")
