#!/usr/bin/env python3
"""盯守(两个机房同时坏、接管之后跑在新主库机器上):每 2 秒探测失联的库机器,一能连上就 ssh 过去
把它的 db / etcd / 入口容器停掉并设为不自启,防止它带着旧数据回来当第二个主。状态在 /guard/state.json。

目标机上的钥匙是专用的:authorized_keys 里那一行带强制命令,只能停该机的库 / 入口 / etcd 容器并设为不自启(restrict),
所以这里 ssh 过去不带任何自己的命令。私钥在 /guard/keys/<目标名>(接管时经标准输入送来,撤销盯守时删掉)。

用法(容器里):
  guard.py run                      常驻循环
  guard.py keys                     标准输入读 {"目标名": "私钥文本"},写进 /guard/keys
  guard.py add NAME 探测host:端口 用户@ssh主机:端口   登记一个目标(已登记的保留其状态,可重复执行)
  guard.py clear NAME               撤销盯守(重新加入时):删掉登记和这台的私钥,打印被撤销的登记
  guard.py show                     打印状态
"""
import json
import os
import socket
import subprocess
import sys
import time

STATE = os.environ.get("GUARD_STATE", "/guard/state.json")
KEYS = os.environ.get("GUARD_KEYS", "/guard/keys")
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


def stop_remote(name, target):
    user_host, _, port = target["ssh"].rpartition(":")
    done = subprocess.run(["ssh", "-i", os.path.join(KEYS, name), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", "-p", port, user_host, "stop"],
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
                ok = stop_remote(name, target)
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
    if command == "keys":
        os.makedirs(KEYS, mode=0o700, exist_ok=True)
        for name, text in json.load(sys.stdin).items():
            path = os.path.join(KEYS, name)
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                handle.write(text if text.endswith("\n") else text + "\n")
    elif command == "add":
        name, probe, ssh = argv[2:5]
        previous = state["targets"].get(name, {})
        state["targets"][name] = {**previous, "probe": probe, "ssh": ssh, "added_at": previous.get("added_at", time.time()),
                                  "stopped": previous.get("stopped", False)}
        save(state)
    elif command == "clear":
        removed = state["targets"].pop(argv[2], None)
        save(state)
        try:
            os.remove(os.path.join(KEYS, argv[2]))
        except OSError:
            pass
        print(json.dumps({"removed": removed, "targets": state["targets"]}))
        return
    elif command == "show":
        pass
    else:
        sys.exit(f"unknown command {command}")
    print(json.dumps(load()))


if __name__ == "__main__":
    main(sys.argv)
