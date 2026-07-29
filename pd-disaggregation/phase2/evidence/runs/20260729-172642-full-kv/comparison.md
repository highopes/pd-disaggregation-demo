# Near-40K Cold Prefill vs Warm Direct GDS Reload

| Metric | Cold | Warm |
|---|---:|---:|
| Input tokens | 38876 | 38876 |
| Correct answer | True | True |
| TTFT | 50.364 s | 7.892 s (median) |
| Total | 52.274 s | 9.805 s |
| Cached/matched request tokens | 0 | 38656 |
| Device→Disk offload blocks | 151 | — |
| Disk→Device onboard blocks | — | 151 per request / 453 total |

- Run ID: `0729172648-cf89c3`
- Payload SHA-256 (byte-identical Cold/Warm): `e11415ed46e5a15ae8c329e4e7e0e0296521d7df5843e82d907287f5c0e5b73f`
- Expected/Cold/Warm: `4971C7|445D7F|E465D2` / `4971C7|445D7F|E465D2` / `4971C7|445D7F|E465D2`
- Complete-KV gate: `151` blocks × `40` MiB = `6040` MiB actual GDS write/read
- Warm samples (sorted): 6.082 s, 7.892 s, 8.648 s; reported value is the median, best=6.082 s
- TTFT saved: 42.472 s (84.3%)
- TTFT speedup: 6.382x
- KVBM matched-token delta: 231936
