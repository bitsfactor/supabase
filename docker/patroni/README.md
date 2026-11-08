# docker/patroni

库自动选主的镜像与配置:`Dockerfile`(supabase postgres + Patroni)、`Dockerfile.haproxy`(库入口 / 盯守 / 证书落地)、`service/`(平台标准部署用的 compose,清单见仓库根 `.deploy.patroni.yaml`)、`tls/gen-certs.sh`(私有 CA 与节点证书)、`guard.py`(两机房同时坏接管后的盯守)、`clients/` + `Dockerfile.clients`(演练用持续写入客户端)。
方案与演练结果见 one 仓 `docs/db-switchover-smooth-progress.md`;应急操作走 one 的应急系统能力 `supabase.patroni_*`。
