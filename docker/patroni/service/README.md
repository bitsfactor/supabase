# Patroni 服务

库自动选主 = 三台库机器各部署一次本服务(Patroni + etcd 投票成员 + 库入口 HAProxy),`.deploy.patroni.yaml` 是平台部署清单。
加第四台库机器 = 在该机再部署一次(每机配置里不带 `COMPOSE_PROFILES=etcd`,投票组仍是三票);所有库入口里的 confd 盯着 etcd 里 Patroni 的成员表,几秒内自动认识新机器,没有要手工维护的后端表。
证书:`../tls/gen-certs.sh` 生成私有 CA 与每机节点证书,按 base64 填进每机配置(`TLS_CRT_B64` / `TLS_KEY_B64`)和服务配置(`TLS_CA_B64`)。
应急操作(状态 / 设为主库 / 暂停恢复 / 停掉这台 / 重新加入)走 one 的应急系统能力 `supabase.patroni_*`,不在这里。
盯守钥匙安装后实际登录核实,成功指纹存在 one 本机离线密钥库并下发原盯守卷。接管核对卷内私钥指纹与核实记录;目标 SSH 不可达不阻断,可达时只读 check 必须成功。
迁移期:`ENTRY_BACKUP`(旧主库 IP:端口)让库入口把旧主库当备用后端,服务先改连入口再切主;迁移完清空。超级用户口令与 pgsodium 根密钥配置默认引用 system_config 的正式项,可覆盖为独立 system_config 引用,不抄第二份。
首次交接允许旧主短暂继续写时,先移除动态 `standby_cluster` 并启用 `synchronous_mode=quorum`,核实备用领导者已成为主和每个入口已转向后,才让旧主只读并停库。入口用 HAProxy 原生 `on-marked-up shutdown-backup-sessions` 关闭旧主备用连接;进行中的事务可能报错,这项设置不保证客户端零失败。旧主 clean stop 后整份改名保留数据目录,为新目录全量拷贝加入,不在旧目录上执行 rewind / reinit。生产逐步命令、影响及回退在 one 的首次迁移清单。
独立单机彩排使用独立 `PT_SCOPE`、全新的 `PT_DATA_DIR` 和配置卷,`PT_SYNC=false`;默认数据目录与默认同步模式保持不变。证书调用 one 的 `scripts/patroni_certs.py --key-prefix PATRONI_REHEARSAL`,CA 只使用该前缀的密钥字段;测试数据与所有测试密钥必须在卸载后精确清理。
迁移前逐项核对主库参数。平台清单开放六项容量设置：`PT_MAX_CONNECTIONS`、`PT_MAX_WORKER_PROCESSES`、`PT_MAX_WAL_SENDERS`、`PT_MAX_REPLICATION_SLOTS`、`PT_MAX_PREPARED_TRANSACTIONS`、`PT_MAX_LOCKS_PER_TRANSACTION`；从库不得小于主库。`wal_level=logical` 与 `track_commit_timestamp=off` 是模板固定值，必须与主库核对；不一致时停止换装，先调整模板和配置入口。
etcd 使用双向证书,接管不换口令。`db-config` 卷沿用原 supabase 的,全新机器自动创建;旧卷根密钥不一致时须先按迁移清单停从库、保存旧密钥到密钥库并统一为主库密钥,容器启动不会自行覆盖。
普通连接名单只放在 Patroni 动态 `postgresql.pg_hba`:本机网段(`samenet`)与库机器地址,复制规则不变。本机 `postgresql` 不得覆盖它,`bootstrap` 兼容名单只用于首次初始化。所有服务改连入口并核实后,经 `scripts/patroni_sync_nodes.py --hba-script <node>` 生成首次加固脚本,由平台 `node.run` 执行(内部用原生 `patronictl edit-config`)。此后平台成功部署的新节点由同一步骤现查节点白名单视图的 Patroni 子集、按当前库机器名单整体替换地址(移出的同步删除)、刷新应急离线清单并安装该机盯守专用钥匙,不另跑手工同步。失败恢复启用前保存的完整动态 HBA 名单,不要删除字段代替回退。同出口的库机器仍可绕入口直连,服务必须只经入口。
