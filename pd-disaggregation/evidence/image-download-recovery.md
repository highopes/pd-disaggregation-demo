# NVCR 慢链路下载恢复记录

时间：2026-07-23（Asia/Shanghai）。站点互联网连接稳定但吞吐很低。

初始 kubelet 并行拉取 `vllm-runtime:1.2.1` 时，三个主要层分别约 3.09 GB、1.92 GB、2.30 GB。约 48 分钟后 containerd 续开连接，旧认证 realm `https://authn.nvidia.com/token` 返回 401；containerd 删除未提交 ingest，普通重试从 0 开始。

现场重新读取 NVCR registry challenge，实际返回：

```text
Bearer realm="https://nvcr.io/proxy_auth",scope="repository:nvidia/ai-dynamo/vllm-runtime:pull"
```

`proxy_auth` 成功返回 `token` 与 `expires_in` 字段；验证过程中没有输出或持久化 token 值。

恢复方案：

- `snapshot-containerd-ingest.sh` 通过 reflink/copy 保存 active blob partial。
- `resumable-nvcr-pull.sh` 读取 OCI manifest，复用 containerd 已完成 blob，并以 HTTP Range 继续 partial；每次连接重新从当前 challenge realm 取 token。
- OCI layout 完成后直接通过 tar stream 导入本机 `k8s.io` containerd namespace，不创建第二份大 tar。
- `copy-image-over-roce.sh` 将完整 worker 镜像从 node1 经 `172.31.230.0/24` CX-7 流式导入 node2，避免重复互联网下载。

临时 partial 位于 `/tmp/dynamo-nvcr-resume/`，只包含公开镜像 blob，不含凭据。确认 node1/node2/node3 所需镜像均 Ready 后可以删除该临时目录以释放空间。

