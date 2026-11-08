#!/bin/bash
# Patroni 回调(on_role_change / on_start / on_stop):参数 <动作> <角色> <scope>。
# 本阶段只写日志;库入口按 /primary 自己找主,不需要这里改任何域名。
echo "$(date -u +%FT%TZ) action=$1 role=$2 scope=$3" >> /var/log/patroni/callback.log
