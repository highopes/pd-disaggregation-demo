# RAM storage sizing

结论：node3 使用 8 GiB `/dev/ram0`，ext4 label `DYNAMO_G4_RAM`，挂载到 `/srv/dynamo-g4`；KVBM 配置 6 GB disk cache。该容量通过实际 39,994-token Prefix 的完整 offload/reload，而非按字符数估算。

## 依据

- node3 `MemTotal=49,331,120 kB`（约 47.0 GiB）。建立 RAM block 后的初始 `MemAvailable=28,868,960 kB`。
- 最终 KVBM 持有 5,997,854,720 bytes 的已分配临时文件；ext4 显示 7.8 GiB usable、6.0 GiB used、1.5 GiB available。
- 最终 node3 `MemAvailable=21,032,412 kB`（约 20.1 GiB），Kubernetes `MemoryPressure=False`。
- vLLM 每个 worker 的 GPU KV pool 是 54,016 tokens / 4.12 GiB；应用最大上下文仍是 40,960，完整 39,994-token Prefix 可装入单个 6 GB KVBM cache。
- 冷请求实际 offload 312 blocks、1,560 MiB Direct GDS writes；热请求实际 onboard 312 blocks、1,560 MiB Direct GDS reads。缓存容量留有文件系统和运行期开销余量。

启动脚本限制 RAM device 只能为 `/dev/ramN`、挂载点只能为 `/srv/dynamo-g4`，并要求请求容量不超过物理内存 25%、保留至少 35%/16 GiB 可用内存。回滚在卸载前验证 block device、marker、export 和 open users，避免误操作真实业务文件系统。

原始证据：[`node3-start-ram-storage.txt`](runs/20260725-135015/node3-start-ram-storage.txt)、[`node3-kubernetes-memory.txt`](runs/20260725-135015/node3-kubernetes-memory.txt)、[`persistence-after.txt`](runs/20260725-135015/persistence-after.txt)。
