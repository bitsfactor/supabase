# 生产布局(Patroni + etcd + HAProxy 库入口)

方案与演练结果见 one 仓 `docs/db-switchover-smooth-progress.md`。这里只写怎么装;所有配置项都是 Patroni / etcd / HAProxy 的标准项。

| 文件 | 作用 |
|---|---|
| `../tls/gen-certs.sh` | 生成 CA、各机 etcd / Patroni 证书与口令,按机器打包(`machines/<名>.tar.gz`);私钥口令只落在输出目录,不入库 |
| `../tls/store-secrets.sh` | 把包存进平台密钥库(`secrets.enc.env` 密文,docs/secrets-spec.md) |
| `../tls/install-tls.sh` | 目标机上解包到 `/opt/patroni/{tls,machine.env}` |
| `../tls/etcd-auth.sh` | 投票组建好后跑一次:建 root / patroni 用户,patroni 只能读写 `/one/`,开启认证 |
| `params.env` | 「各节点必须一致」的参数与端口(max_connections=2000 等),上线前与现主库核对;随部署复制到 `/opt/patroni/params.env` |
| `compose.entry.yml` | 投票组成员(profile `etcd`)+ 库入口(profile `entry`),部署在 `/opt/patroni`,不碰现有库容器 |
| `sandbox/` | 测试专用覆盖(us-los2 上一台宿主模拟三台「机器」,只用 pt- 容器 / 卷,不发布宿主端口):`entry.override.yml`、`db.base.yml`(生产 `db` 服务的替身)、`db.override.yml`;生产布局不使用 |
| `compose.db.yml` | 叠在 supabase 自己的 compose 上,把 `db` 换成 Patroni 镜像(服务名 / 容器名 / 数据目录 / db-config 卷 / shm 16gb / 5433 与原来完全一致,多发布 8008) |

## 安全做法(都已在测试集群实测)
- etcd:客户端与成员间都是 TLS 且必须出示同一 CA 签发的证书;开启 RBAC,Patroni 用 `patroni` 用户(仅 `/one/` 前缀读写)+ 口令 + 证书。
- Patroni REST:TLS + 必须出示客户端证书(`verify_client: required`),写类请求(切换、改配置)另需口令;`patronictl` 通过 `ctl:` 段带证书和口令。
- 库入口体检:HAProxy 用 `check-ssl verify required ca-file … crt …` 带客户端证书访问 `/primary`。
- 证书有效期 5 年(`LEAF_DAYS`),到期前重跑 `gen-certs.sh`(沿用 CA,只补发)再 `install-tls.sh`,滚动重启。**到期没有告警**,记入手册。
- `pg_hba` 的复制行是 `0.0.0.0/0 scram-sha-256`,来源限制由源站防火墙(`fleet_allowlist`)负责,不在 pg_hba 里列节点 IP。

## 必须一致的参数(`params.env`)
来源:现主库 `postgresql.auto.conf`(`max_connections=2000`)+ 镜像 `postgresql.conf`(`wal_level=logical`、`max_wal_senders=10`、`max_replication_slots=5`)+ Postgres 缺省。Patroni 命令行会盖掉库内设置,从库的值不得小于主库,**所以上线前在现主库核对**:
```sql
select name, setting from pg_settings where name in ('max_connections','max_wal_senders','max_replication_slots',
 'max_worker_processes','max_locks_per_transaction','max_prepared_transactions','wal_level','track_commit_timestamp');
```
不同则改 `params.env`。`render.py` 对这些没有缺省值,缺了会拒绝启动。注意 `max_replication_slots=5`:Patroni 每个成员占一个槽,加上旧的 `us_*_slot` 与 realtime 的逻辑槽,余量很小,清旧槽之前不要新增槽。

## 防火墙(源站同步要放行的端口)
`node.firewall_sync` 只放行 `fleet_allowlist` 里的机器。新增端口(均发布在宿主,走 docker DNAT):
- 每台库机器:`5000`(库入口)、`8008`(Patroni REST)、`2379` / `2380`(etcd);`5433`(库)原已在列表里。
- 纯投票机(两台洛杉矶以外的机器):`2379` / `2380`。
代码改动建议见交付说明(`origin_firewall_business.py` 的端口表 + 把纯投票机登记成服务,使其进入同步范围)。

## 入口两种模式
库入口模式由容器自己的环境决定,切换 = 改环境后 `up -d --force-recreate ha`(已建连接会断,客户端重连),不做热重载:
- `HA_MODE=static HA_STATIC=ny1=<现主IP>:5433`:Patroni 装好之前,固定转给现主库,TCP 探活,下线时掐断会话。
- `HA_MODE=patroni HA_NODES=ny1=<IP>:5433:8008,mia=…,los=…`:按 `/primary` 找主。
服务连接串统一 `pg.develop.cc:5000?target_session_attrs=primary`(postgres.js 只认 `primary`)。

## 自动化
上面每一步都有对应的 one 能力(`supabase.patroni_*`,实现见 one 仓 `src/one/business/supabase_patroni_business.py`):投票组是标准三成员 etcd,跟三台库机器同机(每台一个);证书包存在平台密钥库的 `PATRONI_BUNDLE_<机器名大写>` 里,机器名 = 节点名(`gen-certs.sh` 的 `ETCD_MEMBERS` / `DB_MEMBERS` 都用节点名),由能力经 SSH 标准输入下发。`gen-certs.sh` 生成的 machine.env 带复制账号口令 `PT_REPL_PASSWORD`,由 `supabase.patroni_prepare_primary` 设到现主库上。
