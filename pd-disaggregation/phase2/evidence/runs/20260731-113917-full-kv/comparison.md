# Near-40K Cold Prefill vs Warm Direct GDS Reload

| Metric | Cold | Warm |
|---|---:|---:|
| Input tokens | 38876 | 38876 |
| Correct answer | True | True |
| TTFT | 51.772 s | 7.901 s (median) |
| Total | 53.493 s | 9.626 s |
| Cached/matched request tokens | 0 | 38656 |
| Device→Disk offload blocks | 151 | — |
| Disk→Device onboard blocks | — | 151 per request / 453 total |

- Run ID: `0731113923-1f9081`
- Payload SHA-256 (byte-identical Cold/Warm): `d9d617566de617048356e3401d654cffdde8e5ec761eb984bf0305d3b11b548a`
- Expected/Cold/Warm: `1AD861|C4C0F6|FF7829` / `1AD861|C4C0F6|FF7829` / `1AD861|C4C0F6|FF7829`
- Complete-KV gate: `151` blocks × `40` MiB = `6040` MiB actual GDS write/read
- Warm samples (sorted): 7.465 s, 7.901 s, 8.214 s; reported value is the median, best=7.465 s
- TTFT saved: 43.871 s (84.7%)
- TTFT speedup: 6.553x
- KVBM matched-token delta: 231936
