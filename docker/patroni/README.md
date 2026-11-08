# supabase 库 + Patroni(自动选主)

生产同版本镜像 `supabase/postgres:15.8.1.085` 加 Patroni 4.1.1;Patroni 做容器 1 号进程,由它拉起 Postgres。
数据目录、`postgresql.conf`(`custom_conf` 直接 include 原文件)、`postgresql.auto.conf` 都沿用;认证规则(含复制行)写在 `patroni.yml`。
方案与演练结果见 one 仓 `docs/db-switchover-smooth-progress.md`。

| 文件 | 作用 |
|---|---|
| `Dockerfile` / `entrypoint.sh` / `render.py` / `patroni.yml` | 库 + Patroni 镜像;配置模板由环境变量渲染 |
| `Dockerfile.haproxy` / `haproxy.cfg.tpl` / `haproxy-render.py` | 库入口:查 Patroni `/primary`,`on-marked-down shutdown-sessions` |
| `compose.yml` | 测试集群:5 etcd + 4 库 + 4 库入口(固定地址) |
| `Dockerfile.legacy` | 仅测试:「旧架构」原版库容器 |
| `Dockerfile.clients` + `clients/` | 三种持续写客户端(postgres.js / pgx / psycopg)与核对脚本 |
| `drills/` | 可重跑的演练脚本 |

## 演练(两处可跑:本机独立 colima 实例 `patroni-test`;或测试节点,把本目录与 `../volumes/db/*.sql` 放到 `/opt/patroni-test/src/docker/` 下、设 `PT_ON_NODE=1`。`drills/lib.sh` 只碰 `pt-` 前缀容器 / 卷与网络 `patroni-test`,拒绝在别处运行)
```
colima start patroni-test --cpu 4 --memory 4 --disk 40
drills/build.sh && drills/up-legacy.sh      # 旧架构一主三从
drills/01-migrate.sh                         # 演练 1:冷迁移(备集群 → 切主 → 旧主回归 → 计划内切回)
drills/02-site-cut.sh                        # 演练 2:主库所在机房断网,90 秒后直接恢复
drills/03-switchover-and-faults.sh           # 演练 3:切回 / 断一票 / 断一台从库 / 断主库 / 两台库同时断 / 复制槽
drills/04-cancel-commit.sh                   # 演练 4:隔离期间被取消的提交
drills/05-node-recovery.sh '名字|ENV=值 ...'  # postgres.js 换主恢复时间(变体对比)
drills/06-quorum-nosync.sh [轮数]            # 断主库机器时谁当新主(LOS_NOFAILOVER=1 把 los 设为不参选)
drills/07-cancel-drivers.sh                  # 各驱动取消提交的结果
drills/down-all.sh                           # 只删本目录建的容器 / 卷 / 网络(精确名字,不 prune)
```
`LATENCY=1` 注入站点间真实往返(drills/netem.sh)。结果落在 `drills/../out/`(不入库)。

## 连接串要求(演练结论)
所有经库入口连库的客户端都要带 `target_session_attrs=primary`:换主窗口里入口可能把连接转给刚降级的旧主(热备库),不带的话连接池会一直拿到只读连接。
postgres.js 必须写 `primary`(它的 `read-write` 在 PG 14+ 识别不出备库);同时把 `backoff` 换成封顶 2 秒的函数(缺省最长约 20 秒,且失败次数是整个池共用)。
