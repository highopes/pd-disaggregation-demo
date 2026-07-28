# RAM storage sizing

最终配置：node3 使用 8 GiB `/dev/ram0`、ext4 label `DYNAMO_G4_RAM`、挂载点 `/srv/dynamo-g4`；KVBM disk cache 为 7 GB，保存一份完整 near-40K BF16 KV。

## 容量计算

- 模型权重是 `Qwen/Qwen3-14B-FP8`；只有 KV cache 使用 BF16（2 bytes/element）。
- 每个 256-token block：`40 layers × K/V × 256 × 8 KV heads × 128 head dim × 2 bytes = 40 MiB`。
- 最终请求 input=38,874；完整可复用 prefix=`floor(38,874/256)×256=38,656 tokens`。
- `38,656/256=151 blocks`，每份完整 KV=`151×40=6,040 MiB=6,333,399,040 bytes`。
- KVBM 7,000,000,000-byte cache 足以保存该 KV；8 GiB ext4 实测约 7.8 GiB usable，也能容纳预分配文件和文件系统开销。
- vLLM GPU KV pool=39,168 tokens/153 blocks/5.99 GiB；请求保留物理 block 和输出 margin，避免 exact-capacity 请求永不启动或运行时 OOM。

## 历史证据更正

2026-07-25 的 128-token logical / 64-token FlashInfer physical 配置只实际写入/读取 1,560 MiB；这不是显示层少一半。后续 64-token/FP8 完整性配置能够传输 3,120 MiB，但 Warm 仍受 49,920 个 64 KiB 分层 I/O 限制。最终 BF16/256-token 配置把分层 I/O 降为 12,080 个 512 KiB 操作，并以 6,040 MiB 完整数据量通过 Gate。

启动脚本仍限制 RAM device 为 `/dev/ramN`、挂载点为 `/srv/dynamo-g4`，并要求 8 GiB 请求不超过物理内存 25%、保留至少 35%/16 GiB 可用内存。NFS server 最终使用 64 个 nfsd threads；回滚在卸载前验证 block device、marker、export 和 open users。

最终证据：[`20260728-final-nfsd64-samples3`](runs/20260728-final-nfsd64-samples3/comparison.md)。历史原始证据仍保留在 [`20260725-135015`](runs/20260725-135015/)。
