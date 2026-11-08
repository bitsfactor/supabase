#!/usr/bin/env bash
# 在目标机器上装证书包(从标准输入读 gen-certs.sh 生成的 <机器>.tar.gz):解到 /opt/patroni/{tls,machine.env},私钥 0600。
# 生产里由部署管线调用(包的内容来自平台密钥库,见 store-secrets.sh);本脚本不接触网络。
set -euo pipefail
D=${PATRONI_DIR:-/opt/patroni}
umask 077
install -d -m 0700 "$D"
tar -xz -C "$D"
chmod 700 "$D/tls"; chmod 600 "$D"/tls/*.key "$D"/tls/*.pem "$D/machine.env" 2>/dev/null || true
chmod 644 "$D"/tls/*.crt
echo "installed: $(ls "$D/tls" | tr '\n' ' ')"
