#!/usr/bin/env bash
# 数据库参数调优(只需重载、不重启;主库与各从库各自执行,三台一致)。
# 现有 max_connections / shared_buffers / work_mem 等同样由 ALTER SYSTEM 写在
# PGDATA/postgresql.auto.conf;这里只追加「重载即生效」的几项。
# 依据:126G 内存 NVMe 机器、库 ~160G(2026-11-07 体检);改值先在从库验证,主库单独批准。
set -euo pipefail
psql_admin() { docker exec supabase-db psql -U supabase_admin -d postgres -v ON_ERROR_STOP=1 -Atc "$1"; }
psql_admin "ALTER SYSTEM SET max_wal_size = '8GB'"                  # 1GB 时检查点被写量频繁触发
psql_admin "ALTER SYSTEM SET checkpoint_completion_target = '0.9'"  # 检查点写盘摊平
psql_admin "ALTER SYSTEM SET effective_cache_size = '80GB'"         # 规划器估算用,不占内存
psql_admin "ALTER SYSTEM SET random_page_cost = '1.1'"              # NVMe 随机读接近顺序读
psql_admin "ALTER SYSTEM SET effective_io_concurrency = '200'"      # NVMe 并发预读
psql_admin "SELECT pg_reload_conf()"
psql_admin "SELECT name||'='||setting||coalesce(unit,'')||' pending_restart='||pending_restart FROM pg_settings WHERE name IN ('max_wal_size','checkpoint_completion_target','effective_cache_size','random_page_cost','effective_io_concurrency') ORDER BY name"
