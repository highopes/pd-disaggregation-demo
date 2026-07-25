# Post-persistence near-40K counter deltas

Run `0725173741-6d792a`，相同 payload SHA-256 `a4e86577fe41acc9f421ff312cb945aa1753090a78c767edc830659f5ba68904`。

## Direct GDS / KVBM

| Interval | KVBM | nvidia-fs | Meaning |
|---|---:|---:|---|
| before → after cold | offload +312 blocks | writes +24,960 ops / +1,560 MiB | Prefill GPU Device→remote Disk |
| after cold → after warm | onboard +312 blocks; request cached tokens 39,936 | reads +24,960 ops / +1,560 MiB | remote Disk→Prefill GPU Device |

`nvidia-fs` error、I/O state error、page-cache write 和 BAR1 map error 均为 0。KVBM 的 raw matched counter 增加 79,872，是此 runtime 的内部累计/双计数；请求级 `usage.prompt_tokens_details.cached_tokens=39,936` 是实际匹配 token 数。

## Host CX-7 byte deltas

| Interval | node1 / Prefill | node2 / Decode | node3 / Storage |
|---|---:|---:|---:|
| cold | TX RDMA +4,995,650,690; TX prio3 +5,000,653,022 | RX RDMA +3,328,926,368; RX prio3 +3,332,126,692 | RX RDMA +1,666,729,518; RX prio3 +1,668,526,586 |
| warm | RX RDMA +1,673,163,124; RX prio3 +1,673,046,700; TX RDMA +3,339,404,010 | RX RDMA +3,328,919,346; RX prio3 +3,332,123,024 | TX RDMA +1,667,328,928; TX prio3 +1,669,126,080 |

Cold 的 node1 TX 同时包含 storage offload 与 P→D；Warm 的 node1 RX/node3 TX 是 storage reload，node1 TX/node2 RX 是后续 P→D。三节点 PHY CRC/error/discard 均为 0。node1/node3 的既有 CQE flush 静态值来自 earlier intentional NFSoRDMA remount，本 A/B 内未增加；node2 adaptive retrans 有小幅增长，但 retry-exceeded、RNR、sequence/CQE/remote-access errors 均为 0。

## Nexus deltas

交换机端口的 `Tx` 是 switch→host，因此冷 offload 在 node3 port Tx 增长，热 reload 在 node3 port In 和 node1 port Tx 增长。

| Interval | Eth1/1/1 node1 | Eth1/1/2 node2 | Eth1/2/1 node3 |
|---|---:|---:|---:|
| cold interface | In +5,000,653,520 | Out +3,332,128,711 | Out +1,668,528,349 |
| cold qos-group 3 Tx | +13,252,650 | +3,332,126,692 | +1,668,526,330 |
| warm interface | Out +1,675,809,877; In +3,343,009,696 | Out +3,332,124,949 | In +1,669,126,329 |
| warm qos-group 3 Tx | +1,673,047,402 | +3,332,124,066 | +10,885,630 background |

三个端口的 FCS、Xmit、Rcv、Symbol、In/Out discard 最终均为 0。

## P→D NIXL

- Cold：3,130 MiB，511.846 ms，6,115.121 MB/s。
- Warm：3,130 MiB，527.194 ms，5,937.093 MB/s。
- 新 Prefill 与既有 Decode 首次连接记录 `NIXL compatibility check passed`。

这些 NIXL transfer 时间只表示 Prefill→Decode KV 搬运，不等于客户端 TTFT。
