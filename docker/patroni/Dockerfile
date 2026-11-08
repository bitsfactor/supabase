# supabase postgres(生产同版本) + Patroni。数据目录、配置文件位置与原镜像一致,
# Patroni 接管启停;原镜像的 docker-entrypoint.sh 不再参与(只有空目录首次初始化才用得到)。
FROM supabase/postgres:15.8.1.085
USER root
# iptables / iproute2 只给测试环境的断网演练用,生产可去掉。
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3-pip python3-dev iptables iproute2 \
 && pip3 install --no-cache-dir -U pip \
 && pip3 install --no-cache-dir "patroni[etcd3]==4.1.1" psycopg2-binary \
 && rm -rf /var/lib/apt/lists/*
COPY render.py patroni.yml /opt/patroni/
COPY on-role-change.sh entrypoint.sh /opt/patroni/
RUN chmod +x /opt/patroni/*.sh
# Patroni 自带的 postgresql.conf 会改名成 postgresql.base.conf,这里只需给它一个可写目录。
ENTRYPOINT ["/opt/patroni/entrypoint.sh"]
# 基础镜像的 CMD(postgres ...)不能继承:入口脚本无参数时只启动 Patroni
CMD []
