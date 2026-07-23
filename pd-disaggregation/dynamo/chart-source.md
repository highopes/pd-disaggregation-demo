# Dynamo 1.2.1 artifacts

- Helm artifact: `dynamo-platform-1.2.1.tgz`
- SHA-256: `7d7c9c9efce2aefe5fe9d0eaa2d1638e24fceda752dc29283531e71892a124e1`
- Chart `version` / `appVersion`: `1.2.1` / `1.2.1`
- Runtime image used by the official v1.2.1 examples: `nvcr.io/nvidia/ai-dynamo/vllm-runtime:1.2.1`
- CPU Frontend image: `nvcr.io/nvidia/ai-dynamo/dynamo-frontend:1.2.1`
- Operator image rendered by the chart: `nvcr.io/nvidia/ai-dynamo/kubernetes-operator:1.2.1`
- Multinode orchestration: bundled Grove `v0.1.0-alpha.8` and KAI Scheduler `v0.13.4`.

The chart was fetched directly from NVIDIA NGC. The exact v1.2.1 source tag was inspected at commit `919682da679aa699d5bca9c872f4c1d9a530bbc0` to derive the DGD schema and runtime arguments.

The site Internet link is stable but very slow. Download the duplicate worker
image on `csco-k8s-01` once, then run
`pd-disaggregation/scripts/copy-image-over-roce.sh` to
stream an OCI archive to `csco-k8s-02` over `172.31.230.0/24`. The script
checks that the route uses the CX-7 and creates no large intermediate file.
