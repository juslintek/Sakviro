#!/usr/bin/env python3
import json
import os
import select
import subprocess
import sys
import time

binary, home = sys.argv[1:]
env = dict(os.environ, HOME=home, CFFIXED_USER_HOME=home)
args = [binary, "--mcp", "-mcpEnabled", "YES"]
server = subprocess.Popen(args, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    for request in [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "1"}}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "ping"},
    ]:
        if request["id"] == 3:
            time.sleep(1)
            assert server.poll() is None
        server.stdin.write(json.dumps(request) + "\n")
        server.stdin.flush()
        assert select.select([server.stdout], [], [], 10)[0], "MCP response timed out"
        line = server.stdout.readline()
        assert line, server.stderr.read() if server.poll() is not None else "MCP closed stdout"
        response = json.loads(line)
        assert response.get("id") == request["id"] and "result" in response and "error" not in response, response
        if request["id"] == 1:
            server.stdin.write(json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n")
            server.stdin.flush()
    server.stdin.close()
    code = server.wait(timeout=10)
    stderr = server.stderr.read()
finally:
    if server.poll() is None:
        server.kill()
        server.wait(timeout=10)
print("EOF exit:", code, "stderr:", stderr.strip())
assert code == 0 and "MCP stdin reached EOF" in stderr, stderr
assert "MCP starting" in stderr and "MCP ready" in stderr, stderr
bad_stdin = os.open(home, os.O_RDONLY)
try:
    failed = subprocess.run(args, env=env, stdin=bad_stdin, capture_output=True, text=True, timeout=10)
finally:
    os.close(bad_stdin)
print("Read error exit:", failed.returncode, "stderr:", failed.stderr.strip())
assert failed.returncode == 1 and "MCP stdin read failed:" in failed.stderr, failed.stderr
