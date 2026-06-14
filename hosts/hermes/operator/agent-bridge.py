#!/usr/bin/env python3
"""agent-bridge — proxy a host ssh-agent socket to a container-visible path.

Part of the Hermes "full operator" TUI launcher (see
docs/wiki/services/hermes-agent.md, capability-tiers section). Runs on the
hermes VM host as root. It listens on a unix socket inside the hermes data
volume (`/var/lib/hermes/.ops/agent.sock` -> visible in the container at
`/opt/data/.ops/agent.sock`) and proxies every connection to the operator's
*forwarded* ssh-agent (`$SSH_AUTH_SOCK` from `ssh -A`). The listening socket is
chowned to the container runtime uid so the unprivileged agent (uid 10000) can
use it; it exists ONLY for the life of the session and is removed on exit.

No keys ever touch the box: this only forwards bytes to the agent that lives in
the operator's terminal on the doc1 bastion.

Usage: agent-bridge.py <src_agent_sock> <dst_sock> [<uid> <gid>]
"""
import os
import socket
import sys
import threading

src = sys.argv[1]
dst = sys.argv[2]
uid = int(sys.argv[3]) if len(sys.argv) > 3 else 10000
gid = int(sys.argv[4]) if len(sys.argv) > 4 else 10000

try:
    os.unlink(dst)
except FileNotFoundError:
    pass

listener = socket.socket(socket.AF_UNIX)
listener.bind(dst)
os.chown(dst, uid, gid)
os.chmod(dst, 0o600)
listener.listen(64)


def pump(a, b):
    try:
        while True:
            data = a.recv(4096)
            if not data:
                break
            b.sendall(data)
    except OSError:
        pass
    finally:
        try:
            b.shutdown(socket.SHUT_WR)
        except OSError:
            pass


def handle(client):
    upstream = socket.socket(socket.AF_UNIX)
    try:
        upstream.connect(src)
    except OSError:
        client.close()
        return
    threading.Thread(target=pump, args=(client, upstream), daemon=True).start()
    threading.Thread(target=pump, args=(upstream, client), daemon=True).start()


try:
    while True:
        conn, _ = listener.accept()
        handle(conn)
finally:
    try:
        os.unlink(dst)
    except OSError:
        pass
