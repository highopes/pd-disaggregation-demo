# Near-40K Cold Prefill vs Warm GDS Reload

| Metric | Cold GPU Prefill | Warm GDS Reload |
|---|---:|---:|
| Input tokens | 39994 | 39994 |
| Correct answer | True | True |
| TTFT | 31.766 s | 8.059 s |
| Total | 33.965 s | 10.259 s |
| Cached/matched request tokens | 0 | 39936 |
| Device→Disk offload blocks | 312.0 | — |
| Disk→Device onboard blocks | — | 312.0 |

- Run ID: `0726202258-80709f`
- Payload SHA-256: `7966b4f55efc9e380a5d0191ea994e2b6132cab50e54f70f7ae5488395e003be`
- Expected/Cold/Warm: `PHASE2_0726202258-80709f_5693` / `PHASE2_0726202258-80709f_5693` / `PHASE2_0726202258-80709f_5693`
- TTFT saved: 23.707 s
- TTFT speedup: 3.941x
- Total saved: 23.706 s
- Total speedup: 3.311x
- Raw KVBM matched-token counter delta: 79872.0 (runtime-internal cumulative accounting)
