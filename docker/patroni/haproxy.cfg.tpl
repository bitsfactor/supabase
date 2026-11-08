# 库入口(Patroni 官方 HAProxy 模板的写法):每秒问每个成员 /primary,只转给主;
# 一个后端被判下线的那一刻掐断所有经它的连接,客户端连接池立刻重连到新主。
global
    maxconn 4000
    # 平滑重载后旧进程最多再活 3 秒,其上连着已不该连的后端的连接一并断开
    hard-stop-after 3s
    stats socket /tmp/haproxy.sock mode 600 level admin

defaults
    mode tcp
    log global
    retries 2
    timeout connect 3s
    timeout client 1h
    timeout server 1h
    timeout check 2s
    option clitcpka
    option srvtcpka

listen pg_primary
    bind *:$ENTRY_PORT
$BACKENDS
