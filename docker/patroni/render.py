#!/usr/bin/env python3
"""渲染 Patroni 配置:patroni.yml 里的 $VAR 用环境变量替换,再按环境变量加上可选的「备用集群」块。"""
import os
import string
import sys

import yaml

# 只有这几项有缺省值。其余(端口、必须一致的参数、口令)一律必填,缺了大声失败,不留悄悄走错的缺省:
# PT_PG_PORT / PT_REST_PORT(生产库容器 5432 发布在宿主 5433)、PT_MAX_*(取自 production/params.env)。
ENV_DEFAULTS = {
    "PT_SCOPE": "supabase-main",
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
    standby_host = os.environ.get("PT_STANDBY_HOST", "")
    # 同步提交(任一从库确认即可,quorum)是生产缺省;迁移期整个集群是备用集群,不支持同步,切主时那条 edit-config 一并打开。
    env["PT_SYNC"] = os.environ.get("PT_SYNC") or ("false" if standby_host else "quorum")
    text = string.Template(open(template_path).read()).substitute(env)
    cfg = yaml.safe_load(text)
    if standby_host:
        # 迁移期:整个 Patroni 集群先当旧主库的「备用集群」,切主时再摘掉这一块(见 drills/01-migrate.sh)。
        block = {"host": standby_host, "port": int(os.environ.get("PT_STANDBY_PORT", "5433"))}
        if os.environ.get("PT_STANDBY_SLOT"):
            block["primary_slot_name"] = os.environ["PT_STANDBY_SLOT"]
        cfg["bootstrap"]["dcs"]["standby_cluster"] = block
    if os.environ.get("PT_ETCD_USER"):
        # 接管后 etcd 开了认证(新口令只发给幸存机,旧成员没有它,读不了新的集群状态,也就不会自动倒回)
        cfg["etcd3"]["username"] = os.environ["PT_ETCD_USER"]
        cfg["etcd3"]["password"] = os.environ["PT_ETCD_PASSWORD"]
    yaml.safe_dump(cfg, sys.stdout, default_flow_style=False)


if __name__ == "__main__":
    main(sys.argv[1])
