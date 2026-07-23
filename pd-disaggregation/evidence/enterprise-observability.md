# ISOVALENT Enterprise observability baseline

时间：2026-07-23（Asia/Shanghai）。本任务没有安装或替换任何开源版 Cilium、Hubble 或 Tetragon 组件。

实际已部署组件：

- Cilium Helm chart/app `1.18.7`；agent 镜像内置 CLI 报告 `hubble v1.18.7-cee.1`。
- `hubble-enterprise` chart `1.13.4`，四节点 DaemonSet 全部 Running。
- Hubble Relay Running；NodePort `31234`。
- Hubble UI chart `1.3.12`，NodePort `31235`。
- Hubble Timescape chart `1.8.4`，`hubble-timescape-lite-0` 为 `2/2 Running`。
- Tetragon chart/app `1.18.0`，四节点 agent 与 operator 均 Running；本任务未改动它们。
- `kube-prometheus-stack 72.8.0` 已部署；现有 ServiceMonitor 包含 `cilium-agent`、`cilium-envoy`、`hubble`、`hubble-relay` 和 `vllm-qwen-openai`。

node3 企业版 Cilium agent 内置 Hubble API 验证：

```text
Healthcheck (via unix:///var/run/cilium/hubble.sock): Ok
Current/Max Flows: 4095/4095
```

现有 Hubble UI Enterprise NodePort `http://192.168.160.113:31235/` 实测返回 HTTP 200。

最终 API 流量使用相同 CEE agent 内置 CLI、Hubble UI Enterprise/Timescape 和现有 Prometheus/Grafana 验证；不会向该企业版集群安装社区版 CLI 或 chart。

最终实测中，CEE agent 内置 Hubble CLI 捕获到：

```text
192.168.160.183 (world) -> ai-serving/qwen3-14b-pd Frontend:8000
GET /v1/models
FORWARDED
```

同一目标还观察到 `prometheus-k8s-0` 和 fsomonitor Prometheus 对 `/metrics` 的 `FORWARDED` 流量。`192.168.160.183` 请求没有 Token 且 HTTP 200，符合澄清后的访问边界。

当前环境另有两套既存 Prometheus Operator（v0.55.1 与 v0.82.2）同时跨命名空间 reconcile，导致部分第二副本反复重建；`prometheus-k8s-0` 仍为 `2/2 Running`。此控制面竞争不由 `ai-serving` CNP 引起，本任务没有修改 operator 或 Prometheus CR。
