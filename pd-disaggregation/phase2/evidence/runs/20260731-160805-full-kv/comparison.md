# Near-40K Cold Prefill vs Warm Direct GDS Reload

| Metric | Cold | Warm |
|---|---:|---:|
| Input tokens | 38877 | 38877 |
| Correct answer | True | True |
| TTFT | 50.255 s | 8.384 s (median) |
| Total | 52.175 s | 10.302 s |
| Cached/matched request tokens | 0 | 38656 |
| Device→Disk offload blocks | 151 | — |
| Disk→Device onboard blocks | — | 151 per request / 453 total |

- Run ID: `0731160810-3b8799`
- Payload SHA-256 (byte-identical Cold/Warm): `d546927a32d8066af6cda3f81f0f310a9f218835db66fefd9b2e1eddced9f987`
- Expected/Cold/Warm: `888414|E2F687|A91807` / `888414|E2F687|A91807` / `888414|E2F687|A91807`
- Complete-KV gate: `151` blocks × `40` MiB = `6040` MiB actual GDS write/read
- Warm samples (sorted): 8.362 s, 8.384 s, 8.411 s; reported value is the median, best=8.362 s
- TTFT saved: 41.871 s (83.3%)
- TTFT speedup: 5.994x
- KVBM matched-token delta: 231936
