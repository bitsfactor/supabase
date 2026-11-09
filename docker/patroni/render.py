#!/usr/bin/env python3
"""渲染 Patroni 配置:patroni.yml 里的 $VAR 用环境变量替换,再按环境变量加上可选的「备用集群」块。"""
import os
import re
import string
import sys

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


def parse_migration_slots(value: str) -> list:
    """迁移物理槽名单；空字符串表示无保留项，其余逐项严格验证。"""
    names = value.split(',') if value else []
    if any(not re.fullmatch(r"[a-z0-9_]{1,63}", name) for name in names):
        raise ValueError("PT_MIGRATION_SLOTS contains an invalid physical slot name")
    return names


def invalid_password_fields(values: dict) -> list:
    """认证口令只允许至少16位ASCII字母数字及._-；只返回非法键名。"""
    invalid = []
    for key in ('PT_REST_PASSWORD', 'PT_SUPERUSER_PASSWORD', 'PT_REPL_PASSWORD'):
        if key not in values:
            continue
        value = values[key]
        if not isinstance(value, str) or not re.fullmatch(r'[A-Za-z0-9._-]{16,}', value):
            invalid.append(key)
    return invalid


def render_configuration(template_text: str, values: dict) -> str:
    """用实际环境值在YAML节点层生成完整配置，不写文件或输出认证值。"""
    invalid = invalid_password_fields(values)
    if invalid:
        raise ValueError('render.py: invalid password fields: ' + ', '.join(invalid))
    import yaml
    env = Env(values)
    standby_host = values.get("PT_STANDBY_HOST", "")
    # 同步提交(任一从库确认即可,quorum)是生产缺省;迁移期整个集群是备用集群,不支持同步,切主时那条 edit-config 一并打开。
    env["PT_SYNC"] = values.get("PT_SYNC") or ("false" if standby_host else "quorum")
    visited = set()
    def substitute(node):
        if id(node) in visited:
            return
        visited.add(id(node))
        if isinstance(node, yaml.ScalarNode) and "$" in node.value:
            value = string.Template(node.value).substitute(env)
            if node.style is None:
                scalar = yaml.compose(value)
                if not isinstance(scalar, yaml.ScalarNode):
                    raise ValueError("render.py: invalid scalar environment value")
                node.tag, node.value = scalar.tag, scalar.value
            else:
                node.value = value
        elif isinstance(node, yaml.MappingNode):
            for key, value in node.value:
                substitute(key)
                substitute(value)
        elif isinstance(node, yaml.SequenceNode):
            for item in node.value:
                substitute(item)
    try:
        root = yaml.compose(template_text)
        substitute(root)
        configuration = yaml.safe_load(yaml.serialize(root))
    except yaml.YAMLError:
        raise ValueError("render.py: invalid YAML configuration") from None
    # 逐台接管时，尚未换装的级联从库仍持有旧槽；由原生永久槽保住它。
    try:
        migration_slots = parse_migration_slots(values.get("PT_MIGRATION_SLOTS", ""))
    except ValueError as error:
        raise SystemExit("render.py: " + str(error)) from error
    if migration_slots:
        configuration["bootstrap"]["dcs"]["slots"] = {name: {"type": "physical"} for name in migration_slots}
    if standby_host:
        # 迁移期:整个 Patroni 集群先当旧主库的「备用集群」,切主时再摘掉这一块(见 drills/01-migrate.sh)。
        block = {"host": standby_host, "port": int(values.get("PT_STANDBY_PORT", "5433"))}
        if values.get("PT_STANDBY_SLOT"):
            block["primary_slot_name"] = values["PT_STANDBY_SLOT"]
        configuration["bootstrap"]["dcs"]["standby_cluster"] = block
    try:
        return yaml.safe_dump(configuration, default_flow_style=False)
    except yaml.YAMLError:
        raise ValueError("render.py: invalid YAML configuration") from None


def main(template_path: str) -> None:
    sys.stdout.write(render_configuration(open(template_path).read(), dict(os.environ)))


if __name__ == "__main__":
    main(sys.argv[1])
