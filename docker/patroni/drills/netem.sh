#!/usr/bin/env bash
# 注入站点间延迟(往返 ms,单向取一半):ny-mia 35、ny-la 65、mia-la 70、x-ny 20、x-mia 40、x-la 45。
# 用法:netem.sh on | off(对当前存在的 pt-* 容器;新起的客户端容器需再跑一次 on)。
source "$(dirname "$0")/lib.sh"
site_of() { case $1 in
  pt-ny1|pt-ha-ny1|pt-etcd-ny1|pt-cli-ny-*) echo ny;; pt-mia|pt-ha-mia|pt-etcd-mia) echo mia;;
  pt-los|pt-ha-los|pt-etcd-los|pt-cli-la-*) echo la;; pt-etcd-x|pt-etcd-x2) echo x;; esac; }
cidr_of() { case $1 in ny) echo 10.77.0.0/26;; mia) echo 10.77.0.64/26;; la) echo 10.77.0.128/26;; x) echo 10.77.0.192/26;; esac; }
rtt() { case "$1-$2" in ny-mia|mia-ny) echo 35;; ny-la|la-ny) echo 65;; mia-la|la-mia) echo 70;; x-ny|ny-x) echo 20;; x-mia|mia-x) echo 40;; x-la|la-x) echo 45;; esac; }
apply() {
  local c=$1 s; s=$(site_of "$c"); [ -z "$s" ] && return 0
  local cmd="tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root handle 1: prio bands 5 priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0"
  local band=2 t
  if [ "$2" = on ]; then
    for t in ny mia la x; do
      [ "$t" = "$s" ] && continue
      local half=$(( $(rtt "$s" "$t") / 2 ))
      cmd="$cmd; tc qdisc add dev eth0 parent 1:$band handle $((band*10)): netem delay ${half}ms 1ms; tc filter add dev eth0 protocol ip parent 1: prio 1 u32 match ip dst $(cidr_of "$t") flowid 1:$band"
      band=$((band+1))
    done
  else cmd="tc qdisc del dev eth0 root 2>/dev/null; true"; fi
  docker run --rm --memory 64m --cap-add NET_ADMIN --network "container:$c" pt-clients:latest sh -c "$cmd"
}
for c in $(docker ps --format '{{.Names}}' | grep -E '^pt-(ny1|mia|los|ha-|etcd-|cli-)'); do apply "$c" "${1:-on}"; done
