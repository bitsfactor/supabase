# Patroni 服务

库自动选主 = 三台库机器各部署一次本服务(Patroni + etcd 投票成员 + 库入口 HAProxy),`.deploy.patroni.yaml` 是平台部署清单。
加第四台库机器 = 在该机再部署一次(每机配置里不带 `COMPOSE_PROFILES=etcd`,投票组仍是三票)。
证书:`../tls/gen-certs.sh` 生成私有 CA 与每机节点证书,按 base64 填进每机配置(`TLS_CRT_B64` / `TLS_KEY_B64`)和服务配置(`TLS_CA_B64`)。
应急操作(状态 / 设为主库 / 暂停恢复 / 停掉这台 / 重新加入)走 one 的应急系统能力 `supabase.patroni_*`,不在这里。
