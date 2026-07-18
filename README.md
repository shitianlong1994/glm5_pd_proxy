此脚本为glm5.2-w4a8c8 mooncake部署方案

# 脚本部署
## mooncake服务拉起
脚本在:`GLM5_Script/exec/mooncache_pool`
1. 在p主节点启动mooncake master服务
```bash
cd GLM5_Script/exec/mooncache_pool
# host_ip为P节点ip
bash run_master_service.sh --${host_ip}
```

## vllm服务拉起
### p节点服务拉起
```bash
cd GLM5_Script/exec/1p1d_200k_1k
bash run_server_p_200k_1k_0601.sh
```

### d节点服务拉起
```bash
cd GLM5_Script/exec/1p1d_200k_1k
bash run_server_d_200k_1k_0601.sh
```

### proxy服务拉起
修改`GLM5_Script/modules/get_ips.py`中的,为P的ip和D的ip
```python
def get_p_and_d_ips():
    return "192.168.0.48" , "192.168.0.47"
```

```bash
cd GLM5_Script/exec/1p1d_200k_1k
bash run_proxy_200k_1k_0601.sh
```