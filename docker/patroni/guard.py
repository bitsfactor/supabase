#!/usr/bin/env python3
"""盯守(两个机房同时坏、接管之后跑在新主库机器上):每 2 秒探测失联的库机器,一能连上就 ssh 过去
把它的 db / etcd / 入口容器停掉并设为不自启,防止它带着旧数据回来当第二个主。状态在 /guard/state.json。

用法(容器里):
  guard.py run                      常驻循环
  guard.py add NAME 探测host:端口 用户@ssh主机:端口 容器1,容器2 …   登记一个目标
  guard.py clear NAME               撤销盯守(重新加入时)
  guard.py show                     打印状态
"""
import json
import os
import socket
import subprocess
import sys
import time

STATE = os.environ.get("GUARD_STATE", "/guard/state.json")
KEY = os.environ.get("GUARD_KEY", "/guard/key")
INTERVAL_SECONDS = 2
REPEAT_SECONDS = 10


def load():
    try:
        with open(STATE) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"targets": {}}


def save(state):
    tmp = STATE + ".tmp"
    with open(tmp, "w") as handle:
        json.dump(state, handle)
    os.replace(tmp, STATE)


def reachable(host, port):
    try:
        socket.create_connection((host, int(port)), timeout=1.5).close()
        return True
    except OSError:
        return False


def stop_remote(target):
    user_host, _, port = target["ssh"].rpartition(":")
    command = ("docker update --restart=no " + " ".join(target["containers"]) + " >/dev/null 2>&1; "
               "docker stop -t 10 " + " ".join(target["containers"]) + " >/dev/null 2>&1; echo STOPPED")
    done = subprocess.run(["ssh", "-i", KEY, "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
                           "-o", "StrictHostKeyChecking=accept-new", "-p", port, user_host, command],
                          capture_output=True, text=True, timeout=60)
    return "STOPPED" in done.stdout


def tick():
    state = load()
    now = time.time()
    changed = False
    for name, target in state["targets"].items():
        host, _, port = target["probe"].rpartition(":")
        if not reachable(host, port):
            continue
        target["last_reachable"] = now
        if now - target.get("last_action", 0) >= REPEAT_SECONDS:
            ok = False
            try:
                ok = stop_remote(target)
            except (OSError, subprocess.SubprocessError):
                ok = False
            target["last_action"] = now
            target["stopped"] = ok or target.get("stopped", False)
            target["stopped_at"] = now if ok else target.get("stopped_at")
            target["attempts"] = target.get("attempts", 0) + 1
        changed = True
    if changed:
        save(state)


def main(argv):
    command = argv[1] if len(argv) > 1 else "run"
    if command == "run":
        while True:
            tick()
            time.sleep(INTERVAL_SECONDS)
    state = load()
    if command == "add":
        name, probe, ssh, containers = argv[2:6]
        state["targets"][name] = {"probe": probe, "ssh": ssh, "containers": containers.split(","), "added_at": time.time(),
                                  "stopped": False}
        save(state)
    elif command == "clear":
        state["targets"].pop(argv[2], None)
        save(state)
    elif command == "show":
        pass
    else:
        sys.exit(f"unknown command {command}")
    print(json.dumps(load()))


if __name__ == "__main__":
    main(sys.argv)
