#!/usr/bin/env python3
"""HAProxy 2.8 原生状态文件：启动/重载先 DOWN，实际健康检查通过才接流。"""
import ipaddress
import os
from pathlib import Path
import signal
import sys

STATE_PATH = Path('/tmp/primary-startup.state')


def render_state(configuration):
    rows = ['1', '# be_id be_name srv_id srv_name srv_addr srv_op_state srv_admin_state srv_uweight srv_iweight srv_time_since_last_change srv_check_status srv_check_result srv_check_health srv_check_state srv_agent_state bk_f_forced_id srv_f_forced_id srv_fqdn srv_port srvrecord srv_use_ssl srv_check_port srv_check_addr srv_agent_addr srv_agent_port']
    backend = None
    server_index = 0
    for line in configuration.splitlines():
        fields = line.split()
        if not fields or fields[0].startswith('#'):
            continue
        if fields[0] in ('listen', 'backend', 'frontend', 'defaults', 'global'):
            backend = fields[1] if fields[0] in ('listen', 'backend') else None
        if backend != 'pg_primary' or fields[0] != 'server' or 'backup' in fields:
            continue
        server_index += 1
        host, separator, port = fields[2].rpartition(':')
        if not separator or not port.isdigit() or 'check' not in fields or 'port' not in fields:
            raise ValueError('primary_backend_health_configuration_missing')
        host = str(ipaddress.ip_address(host.strip('[]')))
        check_port = fields[fields.index('port') + 1]
        if not check_port.isdigit() or not 1 <= int(port) <= 65535 or not 1 <= int(check_port) <= 65535:
            raise ValueError('primary_backend_health_port_invalid')
        # 名称匹配，不强制后端/服务器编号；无维护位，检查保持启用，健康计数为零。
        # HCHK_STATUS_INI=1，result UNKNOWN=0；status=0 会使原生检查完成函数直接返回，永远不能恢复。
        rows.append(f'1 pg_primary {server_index} {fields[1]} {host} 0 0 1 1 0 1 0 0 6 0 0 0 - {port} - 0 {check_port} - - 0')
    return '\n'.join(rows) + '\n'


def main():
    content = render_state(Path(sys.argv[1]).read_text())
    temporary = STATE_PATH.with_suffix('.tmp')
    temporary.write_text(content)
    temporary.chmod(0o600)
    temporary.replace(STATE_PATH)
    if len(sys.argv) == 3 and sys.argv[2] == '--reload':
        os.kill(1, signal.SIGUSR2)


if __name__ == '__main__':
    main()
