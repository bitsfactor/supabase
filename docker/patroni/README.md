# supabase 库 + Patroni(自动选主)

生产同版本镜像 `supabase/postgres:15.8.1.085` 加 Patroni 4.1.1;Patroni 做容器 1 号进程,由它拉起 Postgres。
数据目录、`postgresql.conf`(`custom_conf` 直接 include 原文件)、`postgresql.auto.conf` 都沿用;认证规则(含复制行)写在 `patroni.yml`。
方案与演练结果见 one 仓 `docs/db-switchover-smooth-progress.md`。

| 文件 | 作用 |
|---|---|
| `Dockerfile` / `entrypoint.sh` / `render.py` / `patroni.yml` | 库 + Patroni 镜像;配置模板由环境变量渲染 |
| `Dockerfile.haproxy` / `haproxy.cfg.tpl` / `haproxy-render.py` | 库入口(HAProxy 2.8,端口 5000):`patroni` 模式查 `/primary`(HTTPS + 客户端证书)/ `static` 模式固定转给现主;模式由容器环境决定,切换 = 重建容器 |
| `tls/` | 证书与口令生成(`gen-certs.sh`)、入平台密钥库(`store-secrets.sh`)、装包(`install-tls.sh`)、etcd 认证初始化(`etcd-auth.sh`) |
| `production/` | 生产布局:`compose.entry.yml`(etcd + 库入口)、`compose.db.yml`(supabase `db` 换 Patroni)、`params.env`、`README.md` |
| `compose.yml` | 测试集群:5 etcd(TLS + 认证)+ 3 库(ny1 / mia / los;us-los2 生产里不进 Patroni)+ 3 库入口(固定地址) |
| `Dockerfile.legacy` | 仅测试:「旧架构」原版库容器 |
| `Dockerfile.clients` + `clients/` | 三种持续写客户端(postgres.js / pgx / psycopg)与核对脚本 |
| `drills/` | 可重跑的演练脚本 |

## 演练(两处可跑:本机独立 colima 实例 `patroni-test`;或测试节点,把本目录与 `../volumes/db/*.sql` 放到 `/opt/patroni-test/src/docker/` 下、设 `PT_ON_NODE=1`。`drills/lib.sh` 只碰 `pt-` 前缀容器 / 卷与网络 `patroni-test`,拒绝在别处运行)
```
colima start patroni-test --cpu 4 --memory 4 --disk 40
drills/build.sh && drills/up-legacy.sh      # 旧架构一主二从(同时生成测试证书到 out/tls)
drills/01-migrate.sh                         # 演练 1:冷迁移(备集群 → 切主 → 旧主回归 → 计划内切回)
drills/02-site-cut.sh                        # 演练 2:主库(ny1)所在机房断网,90 秒后直接恢复
drills/03-switchover-and-faults.sh           # 演练 3:切回 / 断一票 / 断一台从库 / ny1 死 / ny1 死且 los 不稳 / ny1+mia 同时死 / 复制槽(ONLY="场景名" 只跑指定场景)
# 04–07 是阶段一补充脚本,已按 3 库拓扑和 TLS 改过引用,但本轮没有重跑
drills/04-cancel-commit.sh                   # 演练 4:隔离期间被取消的提交
drills/05-node-recovery.sh '名字|ENV=值 ...'  # postgres.js 换主恢复时间(变体对比)
drills/06-quorum-nosync.sh [轮数]            # 断主库机器时谁当新主(LOS_NOFAILOVER=1 把 los 设为不参选)
drills/07-cancel-drivers.sh                  # 各驱动取消提交的结果
drills/down-all.sh                           # 只删本目录建的容器 / 卷 / 网络(精确名字,不 prune)
```
`LATENCY=1` 注入站点间真实往返(drills/netem.sh)。结果落在 `drills/../out/`(不入库)。

## 连接串要求(演练结论)
库入口端口 5000(不占库容器的 5433)。所有经库入口连库的客户端都要带 `target_session_attrs=primary`:换主窗口里入口可能把连接转给刚降级的旧主(热备库),不带的话连接池会一直拿到只读连接。
postgres.js 必须写 `primary`(它的 `read-write` 在 PG 14+ 识别不出备库);同时把 `backoff` 换成封顶 2 秒的函数(缺省最长约 20 秒,且失败次数是整个池共用)。

## 切主顺序(实测结论)
`drills/01-migrate.sh` 的 `STOP_FIRST=1`(先停旧主、等它的关机检查点流给新主,再提升)是**唯一**可用的顺序。`STOP_FIRST=0`(先提升后停旧主)下旧主的关机检查点(0x78 字节)落在新时间线分叉点之后,旧主比新主「多一条记录」:Patroni 不倒回也不报错,只循环 `terminating walreceiver`、日志 `no action`,计划内切回返回 503,旧主永远停在旧时间线上 —— 必须手工 `pg_rewind` 或重建。
