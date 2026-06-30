import json
import os
import time
import socket

GLOBAL_RANK_TABLE_ENV = 'GLOBAL_RANK_TABLE_FILE_PATH'

def wait_and_get_completed_global_rank_table():
    global_rank_table_path = os.environ.get(GLOBAL_RANK_TABLE_ENV)
    if not global_rank_table_path:
        print('read env "{}" failed'.format(GLOBAL_RANK_TABLE_ENV))
        return None

    while True:
        try:
            rank_table = get_rank_table(global_rank_table_path)
            if rank_table is not None:
                return rank_table
        except Exception:
            pass # 忽略中间的文件未就绪报错，继续等待
        time.sleep(1)

def get_rank_table(global_rank_table_path):
    with open(global_rank_table_path, 'r') as file:
        buf = file.read()
    if not buf:
        return None
    rank_table = json.loads(buf)
    if rank_table.get("status") == "completed":
        return rank_table
    return None

def get_p_and_d_ips():
    rank_table = wait_and_get_completed_global_rank_table()
    if not rank_table:
        return "", ""
    all_ips = []
    for group in rank_table.get('server_group_list', []):
        for server in group.get('server_list', []):
            all_ips.append(server['server_ip'])
            

    local_ip = socket.gethostbyname(socket.gethostname())

    if local_ip in all_ips:
        p_ip = local_ip
        # 在列表中过滤掉本地 IP，剩下的就是 D 节点的 IP
        d_ips = [ip for ip in all_ips if ip != local_ip]
        d_ip = d_ips[0] if d_ips else local_ip
    else:
        # 兜底机制：万一 local_ip 没匹配上，按顺序取前两个
        p_ip = all_ips[0]
        d_ip = all_ips[1] if len(all_ips) > 1 else all_ips[0]

    return p_ip, d_ip

if __name__ == '__main__':
    p_ip, d_ip = get_p_and_d_ips()
    # 以空格分隔输出，Shell 可以直接 read 到两个变量中
    print(f"{p_ip} {d_ip}")
