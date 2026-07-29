# Near-40K Cold Prefill vs Warm Direct GDS Reload

| Metric | Cold | Warm |
|---|---:|---:|
| Input tokens | 38875 | 38875 |
| Correct answer | True | True |
| TTFT | 50.139 s | 6.020 s (median) |
| Total | 51.863 s | 7.744 s |
| Cached/matched request tokens | 0 | 38656 |
| Device→Disk offload blocks | 151 | — |
| Disk→Device onboard blocks | — | 151 per request / 453 total |

- Run ID: `0729165453-d7f4b5`
- Payload SHA-256 (byte-identical Cold/Warm): `f28fc57faa2e887025481b6b8e992a6307014b6e962834fb43a9b634f6cc95af`
- Expected/Cold/Warm: `ED360D|6EF941|563971` / `ED360D|6EF941|563971` / `ED360D|6EF941|563971`
- Complete-KV gate: `151` blocks × `40` MiB = `6040` MiB actual GDS write/read
- Warm samples (sorted): 5.874 s, 6.020 s, 6.299 s; reported value is the median, best=5.874 s
- TTFT saved: 44.119 s (88.0%)
- TTFT speedup: 8.328x
- KVBM matched-token delta: 231936
