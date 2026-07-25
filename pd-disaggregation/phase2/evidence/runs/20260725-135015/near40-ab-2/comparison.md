# Near-40K Cold Prefill vs Warm GDS Reload

| Metric | Cold GPU Prefill | Warm GDS Reload |
|---|---:|---:|
| Input tokens | 39995 | 39995 |
| Correct answer | True | True |
| TTFT | 31.133 s | 10.597 s |
| Total | 33.172 s | 12.644 s |
| Cached/matched request tokens | 0 | 39936 |
| Device→Disk offload blocks | 312.0 | — |
| Disk→Device onboard blocks | — | 312.0 |

- Run ID: `0725165826-fee6b3`
- Payload SHA-256: `03549eff83e50ca2853329fd2f7e5d3eaaf5e6c0d317d321452f22a9d636f88c`
- Expected/Cold/Warm: `PHASE2_0725165826-fee6b3_5694` / `PHASE2_0725165826-fee6b3_5694` / `PHASE2_0725165826-fee6b3_5694`
- TTFT saved: 20.536 s
- TTFT speedup: 2.938x
- Total saved: 20.528 s
- Total speedup: 2.624x
- Raw KVBM matched-token counter delta: 79872.0 (runtime-internal cumulative accounting)
