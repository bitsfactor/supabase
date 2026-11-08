#!/usr/bin/env python3
"""渲染 Patroni 配置:patroni.yml 里的 $VAR 用环境变量替换,再按环境变量加上可选的「备用集群」块。"""
import os
import string
import sys

import yaml

ENV_DEFAULTS = {
    "PT_SCOPE": "supabase-main",
    "PT_MAX_CONNECTIONS": "100",
    "PT_MAX_WORKER_PROCESSES": "8",
    "PT_SYNC": "false",
    "PT_NOSYNC": "false",
    "PT_NOFAILOVER": "false",
}


class Env(dict):
    def __missing__(self, key):
        if key in ENV_DEFAULTS:
            return ENV_DEFAULTS[key]
        raise SystemExit(f"render.py: environment variable {key} is required")


def main(template_path: str) -> None:
    env = Env(os.environ)
    text = string.Template(open(template_path).read()).substitute(env)
    cfg = yaml.safe_load(text)
    standby_host = os.environ.get("PT_STANDBY_HOST", "")
    if standby_host:
        # 迁移期:整个 Patroni 集群先当旧主库的「备用集群」,切主时再摘掉这一块(见 drills/01-migrate.sh)。
        block = {"host": standby_host, "port": 5432}
        if os.environ.get("PT_STANDBY_SLOT"):
            block["primary_slot_name"] = os.environ["PT_STANDBY_SLOT"]
        cfg["bootstrap"]["dcs"]["standby_cluster"] = block
    yaml.safe_dump(cfg, sys.stdout, default_flow_style=False)


if __name__ == "__main__":
    main(sys.argv[1])
