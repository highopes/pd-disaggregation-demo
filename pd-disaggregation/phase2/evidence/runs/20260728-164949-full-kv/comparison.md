# Near-40K Cold Prefill vs Warm GDS Reload

| Metric | Cold A | Overwrite B | Warm A |
|---|---:|---:|---:|
| Input tokens | 39997 | 39994 | 39997 |
| Correct answer | True | True | True |
| TTFT | 33.501 s | 33.646 s | 24.280 s |
| Total | 35.022 s | 35.257 s | 25.743 s |
| Cached/matched request tokens | 0 | 0 | 39936 |
| Device→Disk offload blocks | 624.0 | 624.0 | — |
| Disk→Device onboard blocks | — | — | 624.0 |

- Run ID: `0728164955-050376`
- Payload SHA-256: `63567cdd7e27c1c0963834d72a1244dce2f41bb538c884ec8656870444e183b7`
- Overwrite payload SHA-256: `717111211bfda24545241e99baa24f5f9ea7815ce8f18c71f9017f50f60dfb4a`
- Expected/Cold/Warm: `AEF9A6|38DB03|09484C` / `AEF9A6|38DB03|09484C` / `AEF9A6|38DB03|09484C`
- Overwrite expected/actual: `820004|6D37D6|BBA2E3` / `820004|6D37D6|BBA2E3`
- Full-KV gate: `624` blocks × `5` MiB = `3120` MiB actual GDS write/read
- TTFT saved: 9.220 s
- TTFT speedup: 1.380x
- Total saved: 9.280 s
- Total speedup: 1.360x
- Raw KVBM matched-token counter delta: 79872.0 (runtime-internal cumulative accounting)
