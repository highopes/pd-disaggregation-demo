# Phase 1 improvement pre-change state

记录时间：2026-07-23（Asia/Shanghai）。本文件不包含 Secret 或设备凭据。

- 四节点 CX-7 backend netdev MTU 为 9000；`ibv_devinfo` 的 RDMA `active_mtu` 已为 4096。
- Nexus 物理端口/default class MTU 为 9216，RoCE no-drop `qos-group 3` 也为 9216。
- Dynamo Frontend 没有 nodeSelector；当时 Pod 恰好位于 `csco-k8s-03`。
- `qwen-openai` 使用 `externalTrafficPolicy: Local`；`qwen-openai` 与 `qwen3-14b-pd-frontend` 都指向同一个 Frontend Endpoint `10.244.2.71`。
- Foundation Deployment 没有 nodeSelector；当时 Pod 恰好位于 `csco-k8s-04`。
- `foundation-instruct-openai` 使用缺省 `externalTrafficPolicy: Cluster`，NodePort 为 30083。

若仅回退本次改进而保留 Phase 1，可把 CX-7 netdev/no-drop class 恢复为本文件记录值，移除两个 nodeSelector，并把 Foundation Service 恢复为 `externalTrafficPolicy: Cluster`。
