#!/usr/bin/env python3
"""盯守(两个机房同时坏、接管之后跑在新主库机器上):每 2 秒探测失联的库机器,一能连上就 ssh 过去
把它的 db / etcd / 入口容器停掉并设为不自启,防止它带着旧数据回来当第二个主。状态在 /guard/state.json。

目标机上的钥匙是专用的:authorized_keys 里那一行带强制命令,只能停该机的库 / 入口 / etcd 容器并设为不自启(restrict),
停机只发 stop,核实时发只读 check。私钥在 /guard/keys/<目标名>,已安装核实的公钥指纹在同目录 <目标名>.verified。

用法(容器里):
  guard.py run                      常驻循环
  guard.py keys                     标准输入读 {"目标名": {"private": "私钥", "fingerprint": "已核实公钥指纹"}},写进原卷
  guard.py add NAME 探测host:端口[,host:端口…] 用户@ssh主机:端口 [--existing-only]   登记目标;重试只更新已有目标
  guard.py clear NAME               撤销盯守(重新加入时):删登记和这台的私钥
  guard.py show                     打印状态
  guard.py verify                   核对卷内私钥指纹与核实记录;SSH可达则实际认证,不可达不阻断
"""
import fcntl
import json
import os
import socket
import subprocess
import sys
import time
from contextlib import contextmanager

STATE = os.environ.get("GUARD_STATE", "/guard/state.json")
LOCK = os.environ.get("GUARD_LOCK", STATE + ".lock")
KEYS = os.environ.get("GUARD_KEYS", "/guard/keys")
INTERVAL_SECONDS = 2
REPEAT_SECONDS = 10


def load(required=False):
    try:
        with open(STATE) as handle:
            state = json.load(handle)
    except FileNotFoundError:
        if required:
            raise
        return {"targets": {}}
    if not isinstance(state, dict) or not isinstance(state.get("targets"), dict):
        raise ValueError("guard state must contain a targets object")
    return state


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


@contextmanager
def action_lock(name):
    """撤销等本目标正在执行的停机结束;其它目标和状态读取不被慢 SSH 阻塞."""
    with open(LOCK + "." + name, "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


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


def remote_command(name, target, action, timeout_seconds):
    user_host, _, port = target["ssh"].rpartition(":")
    return subprocess.run(["ssh", "-i", os.path.join(KEYS, name), "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none", "-o", "BatchMode=yes",
                           "-o", "ConnectTimeout=5", "-o", "StrictHostKeyChecking=accept-new", "-p", port, user_host, action],
                          capture_output=True, text=True, timeout=timeout_seconds)


def stop_remote(name, target):
    """强制命令核实过目标机上的容器全停了、重启策略是 no 才会打印 STOPPED(NOT_STOPPED = 没停成)."""
    done = remote_command(name, target, "stop", 60)
    return done.returncode == 0 and done.stdout.strip() == "STOPPED"


def fingerprint(path):
    public = subprocess.run(["ssh-keygen", "-y", "-f", path], check=True, capture_output=True, text=True).stdout
    return subprocess.run(["ssh-keygen", "-lf", "-", "-E", "sha256"], input=public, check=True,
                          capture_output=True, text=True).stdout.split()[1]


def verify():
    result = {"fingerprints": {}, "online": [], "offline": []}
    for name in list(load(required=True)["targets"]):
        with action_lock(name):
            target = load(required=True)["targets"].get(name)
            if target is None:
                continue
            with open(os.path.join(KEYS, name + ".verified")) as handle:
                verified = handle.read().strip()
            actual = fingerprint(os.path.join(KEYS, name))
            if not verified or actual != verified:
                raise ValueError(f"{name}: guard volume fingerprint differs from installation verification")
            result["fingerprints"][name] = actual
            user_host, _, port = target["ssh"].rpartition(":")
            try:
                socket.create_connection((user_host.rpartition('@')[2], int(port)), timeout=2).close()
            except OSError:
                result["offline"].append(name)
                continue
            done = remote_command(name, target, "check", 15)
            if done.returncode or done.stdout.strip() != "GUARD_CHECK:" + name:
                raise ValueError(f"{name}: reachable target guard login failed: {(done.stderr or done.stdout)[-500:]}")
            result["online"].append(name)
    return result


def tick():
    for name in list(load()["targets"]):
        with action_lock(name):
            target = load()["targets"].get(name)
            if target is not None:
                check_target(name, target)


def check_target(name, target):
    if not reachable(target["probe"]):
        return
    now = time.time()
    if now - target.get("last_action", 0) < REPEAT_SECONDS:
        return
    try:
        ok = stop_remote(name, target)       # 慢操作不拿状态锁
    except (OSError, subprocess.SubprocessError):
        ok = False

    def record(state):
        current = state["targets"].get(name)
        if current is not None:
            current.update(last_reachable=now, last_action=now, stopped=ok,
                           stopped_at=now if ok else current.get("stopped_at"), attempts=current.get("attempts", 0) + 1)
    update(record)


def main(argv):
    command = argv[1] if len(argv) > 1 else "run"
    if command == "run":
        while True:
            tick()
            time.sleep(INTERVAL_SECONDS)
    if command == "keys":
        os.makedirs(KEYS, mode=0o700, exist_ok=True)
        for name, entry in json.load(sys.stdin).items():
            with action_lock(name):
                if "--existing-only" in argv[2:] and name not in load()["targets"]:
                    continue
                path = os.path.join(KEYS, name)
                temporary = path + ".new"
                try:
                    with open(os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                        text = entry["private"]
                        handle.write(text if text.endswith("\n") else text + "\n")
                    if fingerprint(temporary) != entry["fingerprint"]:
                        raise ValueError(f"{name}: incoming key fingerprint differs from installation verification")
                    os.replace(temporary, path)
                    with open(os.open(path + ".verified", os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600), "w") as handle:
                        handle.write(entry["fingerprint"])
                finally:
                    if os.path.exists(temporary):
                        os.remove(temporary)
    elif command == "add":
        name, probe, ssh = argv[2:5]

        def add(state):
            if "--existing-only" in argv[5:] and name not in state["targets"]:
                return
            previous = state["targets"].get(name, {})
            state["targets"][name] = {**previous, "probe": probe, "ssh": ssh, "added_at": previous.get("added_at", time.time()),
                                      "stopped": previous.get("stopped", False)}
        update(add)
    elif command == "clear":
        with action_lock(argv[2]):
            update(lambda st: st["targets"].pop(argv[2], None))
            for suffix in ("", ".verified"):
                try:
                    os.remove(os.path.join(KEYS, argv[2] + suffix))
                except FileNotFoundError:
                    pass
    elif command == "verify":
        print(json.dumps(verify()))
        return
    elif command == "show":
        pass
    else:
        sys.exit(f"unknown command {command}")
    print(json.dumps(load(required=command == "show" and "--required" in argv[2:])))


if __name__ == "__main__":
    main(sys.argv)
