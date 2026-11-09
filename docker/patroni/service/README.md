# Patroni 服务

容器网络固定为 `patroni-fixed`，默认子网 `10.254.240.0/28`，平台配置 `PT_NETWORK_SUBNET` 可覆盖。必须先比对节点全部 Docker 网络、所有路由表、同名网络归属及地址余量；冲突就拒绝，不删除、重排或改写已有网络，也不依赖默认地址池余量。测试覆盖默认网络为自己的外部网络，tls-init 同样使用测试网络。

首次迁移只逐台替换数据库：先在两台旧从库仍运行时单独准备 tls-init 和两票 etcd，确认全部端点健康且版本可用，再换第一台数据库，确认同集群的恢复模式及实际 streaming 后才换下一台。旧级联从库使用的物理槽通过 `PT_MIGRATION_SLOTS`（逗号分隔）写入 Patroni 原生永久槽配置，防止第一台接管时删除旧槽；这是 bootstrap 配置，已有 DCS 必须回读并用原生动态配置补齐，不能以环境变量有值代替已经生效。两台全部换好前不得删旧槽。

one 的 `scripts/patroni_preflight.py` 为只读预检脚本，使用现有 node_run MCP；不得在生产只读预检中实际构建镜像。精确源码及目标机镜像标识匹配构建回执才通过，缺失证据一律拒绝。`scripts/patroni_replace_replica.py` 共用单台换装与自动回退：保存原恢复配置和启动策略，旧库 clean stop 后才启动新库，限时检查 streaming；失败先核实新库停止、无提升和时间线未变，再恢复原文件、策略、原容器及原上游 streaming。回退回执即使成功也禁止自动继续下一台。进程强杀、宿主断电不能承诺自动恢复，必须根据原备份核查后恢复，不得盲目重跑。

库自动选主 = 三台库机器各部署一次本服务(Patroni + etcd 投票成员 + 库入口 HAProxy),`.deploy.patroni.yaml` 是平台部署清单。
加第四台库机器 = 在该机再部署一次(每机配置里不带 `COMPOSE_PROFILES=etcd`,投票组仍是三票);所有库入口里的 confd 盯着 etcd 里 Patroni 的成员表,几秒内自动认识新机器,没有要手工维护的后端表。
证书:`../tls/gen-certs.sh` 生成私有 CA 与每机节点证书,按 base64 填进每机配置(`TLS_CRT_B64` / `TLS_KEY_B64`)和服务配置(`TLS_CA_B64`)。
应急操作(状态 / 设为主库 / 暂停恢复 / 停掉这台 / 重新加入)走 one 的应急系统能力 `supabase.patroni_*`,不在这里。
盯守钥匙安装后实际登录核实,成功指纹存在 one 本机离线密钥库并下发原盯守卷。接管核对卷内私钥指纹与核实记录;目标 SSH 不可达不阻断,可达时只读 check 必须成功。
迁移期:`ENTRY_BACKUP`(旧主库 IP:端口)让库入口把旧主库当备用后端,服务先改连入口再切主;迁移完清空。超级用户口令默认引用 system_config 的正式项;`PT_PGSODIUM_ROOT_KEY` 可选、默认留空,仅显式配置时管理根密钥,可使用 system_config 引用,不抄第二份。
首次交接允许旧主短暂继续写时,先移除动态 `standby_cluster` 并启用 `synchronous_mode=quorum`,核实备用领导者已成为主和每个入口已转向后,才让旧主只读并停库。入口用 HAProxy 原生 `on-marked-up shutdown-backup-sessions` 关闭旧主备用连接;进行中的事务可能报错,这项设置不保证客户端零失败。旧主 clean stop 后整份改名保留数据目录,为新目录全量拷贝加入,不在旧目录上执行 rewind / reinit。生产逐步命令、影响及回退在 one 的首次迁移清单。
独立单机彩排使用独立 `PT_SCOPE`、全新的 `PT_DATA_DIR` 和配置卷,`PT_SYNC=false`;默认数据目录与默认同步模式保持不变。证书调用 one 的 `scripts/patroni_certs.py --key-prefix PATRONI_REHEARSAL`,CA 只使用该前缀的密钥字段;测试数据与所有测试密钥必须在卸载后精确清理。
迁移前逐项核对主库参数。平台清单开放六项容量设置：`PT_MAX_CONNECTIONS`、`PT_MAX_WORKER_PROCESSES`、`PT_MAX_WAL_SENDERS`、`PT_MAX_REPLICATION_SLOTS`、`PT_MAX_PREPARED_TRANSACTIONS`、`PT_MAX_LOCKS_PER_TRANSACTION`；从库不得小于主库。`wal_level=logical` 与 `track_commit_timestamp=off` 是模板固定值，必须与主库核对；不一致时停止换装，先调整模板和配置入口。
etcd 使用双向证书,接管不换口令。`db-config` 卷沿用原 supabase 的,全新机器自动创建。未配置根密钥时不读取、不创建、不修改密钥文件,各成员保留原卷中的那把;显式配置时仍校验格式并拒绝覆盖不同密钥。**启用 vault / pgsodium 加密前必须先统一根密钥**,保存旧密钥、验证可取回与已有密文可解密后再启用。
普通连接名单只放在 Patroni 动态 `postgresql.pg_hba`:本机网段(`samenet`)与库机器地址,复制规则不变。本机 `postgresql` 不得覆盖它,`bootstrap` 兼容名单只用于首次初始化。所有服务改连入口并核实后,经 `scripts/patroni_sync_nodes.py --hba-script <node>` 生成首次加固脚本,由平台 `node.run` 执行(内部用原生 `patronictl edit-config`)。此后平台成功部署的新节点由同一步骤现查节点白名单视图的 Patroni 子集、按当前库机器名单整体替换地址(移出的同步删除)、刷新应急离线清单并安装该机盯守专用钥匙,不另跑手工同步。失败恢复启用前保存的完整动态 HBA 名单,不要删除字段代替回退。同出口的库机器仍可绕入口直连,服务必须只经入口。
