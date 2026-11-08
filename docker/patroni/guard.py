#!/usr/bin/env python3
"""盯守(两个机房同时坏、接管之后跑在新主库机器上):每 2 秒探测失联的库机器,一能连上就 ssh 过去
把它的 db / etcd / 入口容器停掉并设为不自启,防止它带着旧数据回来当第二个主。状态在 /guard/state.json。

目标机上的钥匙是专用的:authorized_keys 里那一行带强制命令,只能停该机的库 / 入口 / etcd 容器并设为不自启(restrict),
所以这里 ssh 过去不带任何自己的命令。私钥在 /guard/keys/<目标名>(接管时经标准输入送来,撤销盯守时删掉)。

用法(容器里):
  guard.py run                      常驻循环
  guard.py keys                     标准输入读 {"目标名": "私钥文本"},写进 /guard/keys
  guard.py add NAME 探测host:端口[,host:端口…] 用户@ssh主机:端口   登记一个目标(已登记的保留其状态,可重复执行)
  guard.py clear NAME               撤销盯守(重新加入时):锁内标记撤销、等在途的停机做完、删私钥,打印被撤销的登记和 inflight_done
  guard.py show                     打印状态
"""
import fcntl
import json
import os
import socket
import subprocess
import sys
import time

STATE = os.environ.get("GUARD_STATE", "/guard/state.json")
LOCK = os.environ.get("GUARD_LOCK", STATE + ".lock")
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


def update(change):
    """状态的读-改-写在文件锁里一次做完(巡回、登记、撤销可能同时来);change(state) 就地修改."""
    with open(LOCK, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = load()
        change(state)
        save(state)
        return state


def reachable(probe):
    """探测串 `host:端口,host:端口,…`:任何一个口答话就算它回来了(数据库口、Patroni 口、etcd 口、库入口——容器起来的哪一个都算)."""
    for item in probe.split(","):
        host, _, port = item.rpartition(":")
        try:
            socket.create_connection((host, int(port)), timeout=1.5).close()
            return True
        except OSError:
            continue
    return False


def parse_stop(stdout):
    """强制命令的输出 `STOPPED FENCED|FENCE_INCOMPLETE` → (停成功?, 围栏标记写成并核实了?)."""
    stopped = "STOPPED" in stdout
    return stopped, stopped and "FENCED" in stdout.split() and "FENCE_INCOMPLETE" not in stdout


def stop_remote(name, target):
    user_host, _, port = target["ssh"].rpartition(":")
    done = subprocess.run(["ssh", "-i", os.path.join(KEYS, name), "-o", "IdentitiesOnly=yes", "-o", "BatchMode=yes",
                           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", "-p", port, user_host, "stop"],
                          capture_output=True, text=True, timeout=60)
    return parse_stop(done.stdout)


def tick():
    for name, target in list(load()["targets"].items()):
        if not reachable(target["probe"]):
            continue
        now = time.time()
        if now - target.get("last_action", 0) < REPEAT_SECONDS:
            update(lambda st: st["targets"].get(name) and st["targets"][name].update(last_reachable=now))
            continue
        begun = {}

        def begin(state):
            if name in state["targets"]:         # 目标还在才开始;之后撤销会等这一次做完(inflight)
                state.setdefault("inflight", {})[name] = now
                begun["ok"] = True
        update(begin)
        if not begun.get("ok"):
            continue
        try:
            ok, fenced = stop_remote(name, target)       # 慢操作不拿锁
        except (OSError, subprocess.SubprocessError):
            ok, fenced = False, False

        def record(state):
            state.setdefault("inflight", {}).pop(name, None)
            current = state["targets"].get(name)
            if current is None:                  # 这期间被撤销了:别把它写回来
                return
            current.update(last_reachable=now, last_action=now, stopped=ok or current.get("stopped", False),
                           stopped_at=now if ok else current.get("stopped_at"), attempts=current.get("attempts", 0) + 1)
            if ok:                               # 停了但围栏标记没写成 = fence_incomplete,保持停机并如实上报
                current["fence_incomplete"] = not fenced
        update(record)


def cancel(name, wait_seconds=90):
    """撤销一个目标:先在锁里标记撤销(此后不再有新的停机),再等正在进行的停机做完,才返回;私钥一并删掉."""
    removed = {}

    def drop(state):
        removed["entry"] = state["targets"].pop(name, None)
    update(drop)
    deadline = time.time() + wait_seconds
    done = False
    while time.time() < deadline:
        started = load().get("inflight", {}).get(name)
        if started is None or time.time() - started > 2 * wait_seconds:      # 过期的在途记录不能永远卡住撤销
            done = True
            break
        time.sleep(0.2)
    if done:
        update(lambda st: st.get("inflight", {}).pop(name, None))
    try:
        os.remove(os.path.join(KEYS, name))
    except OSError:
        pass
    return {"removed": removed["entry"], "targets": load()["targets"], "inflight_done": done, "inflight": load().get("inflight", {})}


def main(argv):
    command = argv[1] if len(argv) > 1 else "run"
    if command == "run":
        while True:
            tick()
            time.sleep(INTERVAL_SECONDS)
    if command == "keys":
        os.makedirs(KEYS, mode=0o700, exist_ok=True)
        for name, text in json.load(sys.stdin).items():
            path = os.path.join(KEYS, name)
            with open(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                handle.write(text if text.endswith("\n") else text + "\n")
    elif command == "add":
        name, probe, ssh = argv[2:5]

        def add(state):
            previous = state["targets"].get(name, {})
            state["targets"][name] = {**previous, "probe": probe, "ssh": ssh, "added_at": previous.get("added_at", time.time()),
                                      "stopped": previous.get("stopped", False)}
        update(add)
    elif command == "clear":
        print(json.dumps(cancel(argv[2])))
        return
    elif command == "show":
        pass
    else:
        sys.exit(f"unknown command {command}")
    print(json.dumps(load()))


if __name__ == "__main__":
    main(sys.argv)
