# Patroni 服务

库自动选主 = 三台库机器各部署一次本服务(Patroni + etcd 投票成员 + 库入口 HAProxy),`.deploy.patroni.yaml` 是平台部署清单。
加第四台库机器 = 在该机再部署一次(每机配置里不带 `COMPOSE_PROFILES=etcd`,投票组仍是三票);所有库入口里的 confd 盯着 etcd 里 Patroni 的成员表,几秒内自动认识新机器,没有要手工维护的后端表。
证书:`../tls/gen-certs.sh` 生成私有 CA 与每机节点证书,按 base64 填进每机配置(`TLS_CRT_B64` / `TLS_KEY_B64`)和服务配置(`TLS_CA_B64`)。
应急操作(状态 / 设为主库 / 暂停恢复 / 停掉这台 / 重新加入)走 one 的应急系统能力 `supabase.patroni_*`,不在这里。
迁移期:`ENTRY_BACKUP`(旧主库 IP:端口)让库入口把旧主库当备用后端,服务先改连入口再切主;迁移完清空。`secrets` 里的超级用户口令取自 system_config,不在这里抄第二份。
etcd 使用双向证书,接管不换口令。`db-config` 卷沿用原 supabase 的,全新机器自动创建;旧卷根密钥不一致时须先按迁移清单停从库、保存旧密钥到密钥库并统一为主库密钥,容器启动不会自行覆盖。
