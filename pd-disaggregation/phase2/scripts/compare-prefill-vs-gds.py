#!/usr/bin/env python3
"""Create and run a strict near-40K KVBM/GDS reuse test."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import secrets
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


MODEL = "Qwen/Qwen3-14B-FP8"
NAMESPACE = "ai-serving"
PREFILL_SELECTOR = "app=dynamo-qwen-prefill"
SERVICE = "qwen3-14b-pd-frontend"
MAX_CONTEXT = 39168
MAX_TOKENS = 32
TARGET_MIN = 38500
# Leave one physical block free.  At exactly all allocated blocks the
# PD/KVBM scheduler accepts the request but vLLM never starts it.
TARGET_MAX = MAX_CONTEXT - MAX_TOKENS - 256
UNIT = "天地玄黄宇宙洪荒。"
EVICTION_UNIT = "日月盈昃辰宿列张。"
KV_BLOCK_SIZE_TOKENS = 256
NUM_LAYERS = 40
KV_OUTER_DIM = 2  # K and V
NUM_KV_HEADS = 8
HEAD_DIM = 128
KV_DTYPE_WIDTH_BYTES = 2  # BF16 KV cache; model weights remain FP8.
MIB = 1024 * 1024


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def run_checked(args: list[str], *, input_bytes: bytes | None = None) -> str:
    try:
        result = subprocess.run(
            args,
            input=input_bytes,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=True,
        )
    except FileNotFoundError as exc:
        fail(f"required command not found: {args[0]} ({exc})")
    except subprocess.CalledProcessError as exc:
        stderr = exc.stderr.decode("utf-8", errors="replace").strip()
        fail(f"command failed ({' '.join(args)}): {stderr}")
    return result.stdout.decode("utf-8")


def discover_prefill_pod() -> str:
    raw = run_checked(
        [
            "kubectl",
            "-n",
            NAMESPACE,
            "get",
            "pod",
            "-l",
            PREFILL_SELECTOR,
            "-o",
            "json",
        ]
    )
    items = json.loads(raw).get("items", [])
    ready = [
        item
        for item in items
        if item.get("status", {}).get("phase") == "Running"
        and item.get("status", {}).get("containerStatuses", [{}])[0].get("ready")
    ]
    if len(ready) != 1:
        fail(f"expected one Ready Prefill pod, found {len(ready)}")
    return ready[0]["metadata"]["name"]


def resolve_endpoint() -> str:
    cluster_ip = run_checked(
        [
            "kubectl",
            "-n",
            NAMESPACE,
            "get",
            "service",
            SERVICE,
            "-o",
            "jsonpath={.spec.clusterIP}",
        ]
    ).strip()
    if not cluster_ip or cluster_ip == "None":
        fail(f"service {SERVICE} has no ClusterIP")
    return f"http://{cluster_ip}:8000"


TOKENIZER_HELPER = r'''
import json
import sys
from transformers import AutoTokenizer

cfg = json.load(sys.stdin)
tokenizer = AutoTokenizer.from_pretrained(cfg["model"], trust_remote_code=True)
unit = cfg["unit"]
run_id = cfg["run_id"]
checkpoints = cfg["checkpoints"]

def build(n):
    expected = "|".join(checkpoints)
    base, remainder = divmod(n, 4)
    lengths = [base + (1 if i < remainder else 0) for i in range(4)]
    prefix = (
        "这是一次远端KV缓存一致性验证。下面正文只用于形成长上下文；"
        "不要续写、翻译或解释正文。\n"
        f"RUN_ID={run_id}\nBEGIN_CONTEXT\n"
    )
    context = (
        (unit * lengths[0])
        + f"\nCHECKPOINT_ALPHA={checkpoints[0]}\n"
        + (unit * lengths[1])
        + f"\nCHECKPOINT_BETA={checkpoints[1]}\n"
        + (unit * lengths[2])
        + f"\nCHECKPOINT_GAMMA={checkpoints[2]}\n"
        + (unit * lengths[3])
    )
    suffix = (
        "\nEND_CONTEXT\n"
        f"RUN_ID={run_id}\n"
        f"重复次数={n}\n"
        "请找出正文中的 CHECKPOINT_ALPHA、CHECKPOINT_BETA、CHECKPOINT_GAMMA；"
        "只输出三个值并用竖线连接，不要输出标签、引号、标点、解释或其他文字。"
    )
    return prefix + context + suffix, expected

def count(n):
    prompt, _ = build(n)
    encoded = tokenizer.apply_chat_template(
        [{"role": "user", "content": prompt}],
        tokenize=True,
        add_generation_prompt=True,
        enable_thinking=False,
    )
    ids = encoded["input_ids"] if hasattr(encoded, "keys") else encoded
    if ids and isinstance(ids[0], list):
        ids = ids[0]
    return len(ids)

low, high = 1, 8192
while count(high) < cfg["target_max"]:
    high *= 2
    if high > 100000:
        raise RuntimeError("could not bracket token target")
while low <= high:
    mid = (low + high) // 2
    if count(mid) <= cfg["target_max"]:
        low = mid + 1
    else:
        high = mid - 1
n = high
tokens = count(n)
if tokens < cfg["target_min"]:
    raise RuntimeError(f"best token count {tokens} is below target")
prompt, expected = build(n)
print(json.dumps({
    "repeat_count": n,
    "input_tokens": tokens,
    "prompt": prompt,
    "expected_answer": expected,
    "tokenizer_name_or_path": tokenizer.name_or_path,
    "tokenizer_revision": tokenizer.init_kwargs.get("_commit_hash"),
}, ensure_ascii=False))
'''


def prepare_payload(
    pod: str,
    run_id: str,
    unit: str,
    checkpoints: list[str],
) -> tuple[bytes, dict[str, Any]]:
    cfg = {
        "model": MODEL,
        "unit": unit,
        "run_id": run_id,
        "checkpoints": checkpoints,
        "target_min": TARGET_MIN,
        "target_max": TARGET_MAX,
    }
    token_result = json.loads(
        run_checked(
            [
                "kubectl",
                "-n",
                NAMESPACE,
                "exec",
                "-i",
                pod,
                "--",
                "python3",
                "-c",
                TOKENIZER_HELPER,
            ],
            input_bytes=json.dumps(cfg, ensure_ascii=False).encode("utf-8"),
        )
    )
    prompt = token_result.pop("prompt")
    expected_answer = token_result.pop("expected_answer")
    payload = {
        "model": MODEL,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": MAX_TOKENS,
        "temperature": 0,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    payload_bytes = json.dumps(
        payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")
    result = {
        **token_result,
        "expected_answer": expected_answer,
        "payload_sha256": hashlib.sha256(payload_bytes).hexdigest(),
        "prompt_characters": len(prompt),
        "repeat_unit": unit,
        "checkpoints": checkpoints,
    }
    return payload_bytes, result


def prepare(
    output_dir: Path, run_id: str | None, *, performance_only: bool = False
) -> None:
    output_dir.mkdir(parents=True, exist_ok=True)
    if any(output_dir.iterdir()):
        fail(f"output directory is not empty: {output_dir}")
    actual_run_id = run_id or f"{time.strftime('%m%d%H%M%S')}-{secrets.token_hex(3)}"
    pod = discover_prefill_pod()
    primary_checkpoints = [secrets.token_hex(3).upper() for _ in range(3)]
    eviction_checkpoints = [secrets.token_hex(3).upper() for _ in range(3)]
    payload_bytes, primary = prepare_payload(
        pod, actual_run_id, UNIT, primary_checkpoints
    )
    if performance_only:
        # The customer performance path deliberately omits the unrelated B
        # request.  Keep the metadata schema stable without paying a second
        # near-40K tokenization cost.
        eviction_payload_bytes = payload_bytes
        eviction = dict(primary)
    else:
        eviction_payload_bytes, eviction = prepare_payload(
            pod, f"{actual_run_id}-evict", EVICTION_UNIT, eviction_checkpoints
        )
    input_tokens = int(primary["input_tokens"])
    eviction_input_tokens = int(eviction["input_tokens"])
    expected_cached_tokens = (input_tokens // KV_BLOCK_SIZE_TOKENS) * KV_BLOCK_SIZE_TOKENS
    expected_eviction_cached_tokens = (
        eviction_input_tokens // KV_BLOCK_SIZE_TOKENS
    ) * KV_BLOCK_SIZE_TOKENS
    expected_kv_blocks = expected_cached_tokens // KV_BLOCK_SIZE_TOKENS
    expected_eviction_kv_blocks = (
        expected_eviction_cached_tokens // KV_BLOCK_SIZE_TOKENS
    )
    bytes_per_block = (
        NUM_LAYERS
        * KV_OUTER_DIM
        * KV_BLOCK_SIZE_TOKENS
        * NUM_KV_HEADS
        * HEAD_DIM
        * KV_DTYPE_WIDTH_BYTES
    )
    if bytes_per_block % MIB:
        fail(f"KV block size is not an integer MiB: {bytes_per_block} bytes")
    mib_per_block = bytes_per_block // MIB
    metadata = {
        "run_id": actual_run_id,
        "performance_only": performance_only,
        "model": MODEL,
        "repeat_count": int(primary["repeat_count"]),
        "repeat_unit": primary["repeat_unit"],
        "prompt_characters": primary["prompt_characters"],
        "predicted_input_tokens": input_tokens,
        "eviction_repeat_count": int(eviction["repeat_count"]),
        "eviction_repeat_unit": eviction["repeat_unit"],
        "eviction_prompt_characters": eviction["prompt_characters"],
        "eviction_predicted_input_tokens": eviction_input_tokens,
        "max_context_tokens": MAX_CONTEXT,
        "max_output_tokens": MAX_TOKENS,
        "context_margin_tokens": MAX_CONTEXT - input_tokens - MAX_TOKENS,
        "expected_answer": primary["expected_answer"],
        "eviction_expected_answer": eviction["expected_answer"],
        "checkpoints": primary["checkpoints"],
        "eviction_checkpoints": eviction["checkpoints"],
        "tokenizer_name_or_path": primary.get("tokenizer_name_or_path"),
        "tokenizer_revision": primary.get("tokenizer_revision"),
        "payload_sha256": primary["payload_sha256"],
        "eviction_payload_sha256": eviction["payload_sha256"],
        "kv_block_size_tokens": KV_BLOCK_SIZE_TOKENS,
        "kv_mib_per_block": mib_per_block,
        "expected_cached_tokens": expected_cached_tokens,
        "expected_eviction_cached_tokens": expected_eviction_cached_tokens,
        "expected_kv_blocks": expected_kv_blocks,
        "expected_eviction_kv_blocks": expected_eviction_kv_blocks,
        "expected_gds_mib": expected_kv_blocks * mib_per_block,
        "expected_eviction_gds_mib": expected_eviction_kv_blocks * mib_per_block,
        "expected_gds_ops": expected_kv_blocks * NUM_LAYERS * KV_OUTER_DIM,
        "expected_eviction_gds_ops": (
            expected_eviction_kv_blocks * NUM_LAYERS * KV_OUTER_DIM
        ),
        "expected_pd_mib": (
            (input_tokens + KV_BLOCK_SIZE_TOKENS - 1) // KV_BLOCK_SIZE_TOKENS
        )
        * mib_per_block,
        "expected_pd_descriptors": (
            (input_tokens + KV_BLOCK_SIZE_TOKENS - 1) // KV_BLOCK_SIZE_TOKENS
        )
        * NUM_LAYERS
        * KV_OUTER_DIM,
        "expected_eviction_pd_mib": (
            (
                eviction_input_tokens + KV_BLOCK_SIZE_TOKENS - 1
            )
            // KV_BLOCK_SIZE_TOKENS
        )
        * mib_per_block,
        "expected_eviction_pd_descriptors": (
            (
                eviction_input_tokens + KV_BLOCK_SIZE_TOKENS - 1
            )
            // KV_BLOCK_SIZE_TOKENS
        )
        * NUM_LAYERS
        * KV_OUTER_DIM,
        "prefill_pod": pod,
        "created_at_epoch": time.time(),
    }
    (output_dir / "payload.json").write_bytes(payload_bytes)
    (output_dir / "eviction-payload.json").write_bytes(eviction_payload_bytes)
    (output_dir / "metadata.json").write_text(
        json.dumps(metadata, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps(metadata, ensure_ascii=False, indent=2))


def request_once(output_dir: Path, label: str, endpoint: str | None) -> None:
    if label not in {"cold", "evict", "warm"}:
        fail("label must be cold, evict, or warm")
    is_eviction = label == "evict"
    payload_path = output_dir / (
        "eviction-payload.json" if is_eviction else "payload.json"
    )
    metadata_path = output_dir / "metadata.json"
    if not payload_path.is_file() or not metadata_path.is_file():
        fail(f"prepared payload is absent in {output_dir}")
    payload_bytes = payload_path.read_bytes()
    metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
    payload_hash = hashlib.sha256(payload_bytes).hexdigest()
    expected_payload_hash = metadata[
        "eviction_payload_sha256" if is_eviction else "payload_sha256"
    ]
    expected_answer = metadata[
        "eviction_expected_answer" if is_eviction else "expected_answer"
    ]
    if payload_hash != expected_payload_hash:
        fail("payload hash no longer matches metadata")
    base_url = (
        endpoint or os.environ.get("PHASE2_ENDPOINT") or resolve_endpoint()
    ).rstrip("/")
    sent_request_id = (
        f"phase2-{metadata['run_id']}-{label}-{secrets.token_hex(4)}"
    )
    http_request = urllib.request.Request(
        f"{base_url}/v1/chat/completions",
        data=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "X-Request-ID": sent_request_id,
        },
        method="POST",
    )
    started = time.perf_counter()
    first_event_seconds: float | None = None
    ttft_seconds: float | None = None
    content_parts: list[str] = []
    raw_lines: list[str] = []
    usage: dict[str, Any] = {}
    response_id: str | None = None
    finish_reason: str | None = None
    try:
        with urllib.request.urlopen(http_request, timeout=1200) as response:
            http_status = response.status
            response_request_id = response.headers.get("X-Request-ID")
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
                raw_lines.append(line)
                if not line.startswith("data:"):
                    continue
                data = line[5:].strip()
                if data == "[DONE]":
                    break
                if first_event_seconds is None:
                    first_event_seconds = time.perf_counter() - started
                if not data:
                    continue
                event = json.loads(data)
                response_id = event.get("id") or response_id
                if event.get("usage"):
                    usage = event["usage"]
                choices = event.get("choices") or []
                if choices:
                    delta = choices[0].get("delta") or {}
                    text = delta.get("content")
                    if text:
                        if ttft_seconds is None:
                            ttft_seconds = time.perf_counter() - started
                        content_parts.append(text)
                    finish_reason = choices[0].get("finish_reason") or finish_reason
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        fail(f"{label} request HTTP {exc.code}: {body[:1000]}")
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as exc:
        fail(f"{label} streaming request failed: {exc}")
    total_seconds = time.perf_counter() - started
    answer = "".join(content_parts).strip()
    result = {
        "label": label,
        "http_status": http_status,
        "endpoint": base_url,
        "sent_request_id": sent_request_id,
        "response_x_request_id": response_request_id,
        "dynamo_response_id": response_id,
        "payload_sha256": payload_hash,
        "ttft_seconds": ttft_seconds,
        "first_event_seconds": first_event_seconds,
        "total_seconds": total_seconds,
        "answer": answer,
        "expected_answer": expected_answer,
        "answer_correct": answer == expected_answer,
        "finish_reason": finish_reason,
        "usage": usage,
    }
    (output_dir / f"{label}.sse.log").write_text(
        "\n".join(raw_lines) + "\n", encoding="utf-8"
    )
    (output_dir / f"{label}.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if http_status != 200 or not result["answer_correct"] or ttft_seconds is None:
        raise SystemExit(2)


def prometheus_value(path: Path, name: str) -> float:
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith(name + " "):
            return float(line.rsplit(" ", 1)[1])
    fail(f"metric {name} missing from {path}")


def summarize_performance(output_dir: Path, metadata: dict[str, Any]) -> None:
    """Summarize the minimum-overhead Cold A -> Warm A customer demo."""
    cold = json.loads((output_dir / "cold.json").read_text(encoding="utf-8"))
    warm_paths = [output_dir / "warm.json", *sorted(output_dir.glob("warm-[0-9]*.json"))]
    warm_samples = [json.loads(path.read_text(encoding="utf-8")) for path in warm_paths]
    warm_samples.sort(key=lambda result: float(result["ttft_seconds"]))
    warm = warm_samples[len(warm_samples) // 2]
    warm_sample_count = len(warm_samples)
    warm_ttft_samples = [float(result["ttft_seconds"]) for result in warm_samples]
    metrics_paths = {
        "before": output_dir / "metrics-before.txt",
        "cold": output_dir / "metrics-after-cold.txt",
        "warm": output_dir / "metrics-after-warm.txt",
    }
    missing = [str(path) for path in metrics_paths.values() if not path.is_file()]
    if missing:
        fail(f"required metric snapshots are absent: {', '.join(missing)}")
    names = [
        "kvbm_offload_blocks_d2d",
        "kvbm_onboard_blocks_d2d",
        "kvbm_matched_tokens",
        "kvbm_disk_cache_hit_rate",
    ]
    metrics = {
        f"{snapshot}_{name}": prometheus_value(path, name)
        for snapshot, path in metrics_paths.items()
        for name in names
    }
    cold_ttft = float(cold["ttft_seconds"])
    warm_ttft = float(warm["ttft_seconds"])
    cold_total = float(cold["total_seconds"])
    warm_total = float(warm["total_seconds"])
    actual_cold_tokens = cold.get("usage", {}).get("prompt_tokens")
    actual_warm_tokens = warm.get("usage", {}).get("prompt_tokens")
    cold_cached_tokens = (
        (cold.get("usage", {}).get("prompt_tokens_details") or {}).get(
            "cached_tokens"
        )
        or 0
    )
    warm_cached_tokens = (
        (warm.get("usage", {}).get("prompt_tokens_details") or {}).get(
            "cached_tokens"
        )
        or 0
    )
    cold_offload_delta = (
        metrics["cold_kvbm_offload_blocks_d2d"]
        - metrics["before_kvbm_offload_blocks_d2d"]
    )
    warm_onboard_delta = (
        metrics["warm_kvbm_onboard_blocks_d2d"]
        - metrics["cold_kvbm_onboard_blocks_d2d"]
    )
    matched_delta = (
        metrics["warm_kvbm_matched_tokens"]
        - metrics["cold_kvbm_matched_tokens"]
    )
    summary: dict[str, Any] = {
        "run_id": metadata["run_id"],
        "performance_only": True,
        "payload_sha256": metadata["payload_sha256"],
        "predicted_input_tokens": metadata["predicted_input_tokens"],
        "cold_input_tokens": actual_cold_tokens,
        "warm_input_tokens": actual_warm_tokens,
        "cold_cached_tokens": cold_cached_tokens,
        "warm_cached_tokens": warm_cached_tokens,
        "expected_answer": metadata["expected_answer"],
        "cold_answer": cold["answer"],
        "warm_answer": warm["answer"],
        "cold_answer_correct": cold["answer_correct"],
        "warm_answer_correct": warm["answer_correct"],
        "cold_ttft_seconds": cold_ttft,
        "warm_gds_ttft_seconds": warm_ttft,
        "warm_best_ttft_seconds": min(warm_ttft_samples),
        "warm_ttft_samples_seconds": warm_ttft_samples,
        "warm_sample_count": warm_sample_count,
        "cold_total_seconds": cold_total,
        "warm_gds_total_seconds": warm_total,
        "ttft_saved_seconds": cold_ttft - warm_ttft,
        "ttft_saved_percent": (cold_ttft - warm_ttft) / cold_ttft * 100,
        "ttft_speedup": cold_ttft / warm_ttft if warm_ttft else None,
        "total_saved_seconds": cold_total - warm_total,
        "total_speedup": cold_total / warm_total if warm_total else None,
        "cold_x_request_id": cold.get("response_x_request_id"),
        "warm_x_request_id": warm.get("response_x_request_id"),
        "cold_dynamo_response_id": cold.get("dynamo_response_id"),
        "warm_dynamo_response_id": warm.get("dynamo_response_id"),
        "kv_block_size_tokens": metadata["kv_block_size_tokens"],
        "kv_mib_per_block": metadata["kv_mib_per_block"],
        "expected_cached_tokens": metadata["expected_cached_tokens"],
        "expected_kv_blocks": metadata["expected_kv_blocks"],
        "expected_gds_mib": metadata["expected_gds_mib"],
        "expected_gds_ops": metadata["expected_gds_ops"],
        "expected_pd_mib": metadata["expected_pd_mib"],
        "expected_pd_descriptors": metadata["expected_pd_descriptors"],
        "cold_offload_blocks_d2d_delta": cold_offload_delta,
        "warm_onboard_blocks_d2d_delta": warm_onboard_delta,
        "warm_onboard_blocks_per_request": metadata["expected_kv_blocks"],
        "kvbm_matched_tokens_counter_delta": matched_delta,
        "warm_disk_cache_hit_rate": metrics["warm_kvbm_disk_cache_hit_rate"],
        "metrics": metrics,
    }
    (output_dir / "comparison.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    markdown = f"""# Near-40K Cold Prefill vs Warm Direct GDS Reload

| Metric | Cold | Warm |
|---|---:|---:|
| Input tokens | {actual_cold_tokens} | {actual_warm_tokens} |
| Correct answer | {cold['answer_correct']} | {warm['answer_correct']} |
| TTFT | {cold_ttft:.3f} s | {warm_ttft:.3f} s (median) |
| Total | {cold_total:.3f} s | {warm_total:.3f} s |
| Cached/matched request tokens | {cold_cached_tokens} | {warm_cached_tokens} |
| Device→Disk offload blocks | {cold_offload_delta:.0f} | — |
| Disk→Device onboard blocks | — | {metadata['expected_kv_blocks']} per request / {warm_onboard_delta:.0f} total |

- Run ID: `{metadata['run_id']}`
- Payload SHA-256 (byte-identical Cold/Warm): `{metadata['payload_sha256']}`
- Expected/Cold/Warm: `{metadata['expected_answer']}` / `{cold['answer']}` / `{warm['answer']}`
- Complete-KV gate: `{metadata['expected_kv_blocks']}` blocks × `{metadata['kv_mib_per_block']}` MiB = `{metadata['expected_gds_mib']}` MiB actual GDS write/read
- Warm samples (sorted): {', '.join(f'{value:.3f} s' for value in warm_ttft_samples)}; reported value is the median, best={min(warm_ttft_samples):.3f} s
- TTFT saved: {summary['ttft_saved_seconds']:.3f} s ({summary['ttft_saved_percent']:.1f}%)
- TTFT speedup: {summary['ttft_speedup']:.3f}x
- KVBM matched-token delta: {matched_delta:.0f}
"""
    (output_dir / "comparison.md").write_text(markdown, encoding="utf-8")
    print(markdown)
    valid = (
        cold["http_status"] == 200
        and all(result["http_status"] == 200 for result in warm_samples)
        and cold["answer_correct"]
        and all(result["answer_correct"] for result in warm_samples)
        and all(
            cold["payload_sha256"] == result["payload_sha256"]
            for result in warm_samples
        )
        and cold["payload_sha256"] == metadata["payload_sha256"]
        and all(
            actual_cold_tokens == result.get("usage", {}).get("prompt_tokens")
            for result in warm_samples
        )
        and actual_cold_tokens == metadata["predicted_input_tokens"]
        and TARGET_MIN <= int(actual_cold_tokens or 0) <= TARGET_MAX
        and int(cold_cached_tokens) == 0
        and all(
            int(
                (result.get("usage", {}).get("prompt_tokens_details") or {}).get(
                    "cached_tokens", 0
                )
            )
            == int(metadata["expected_cached_tokens"])
            for result in warm_samples
        )
        and int(cold_offload_delta) == int(metadata["expected_kv_blocks"])
        and int(warm_onboard_delta)
        == int(metadata["expected_kv_blocks"]) * warm_sample_count
        and int(matched_delta)
        >= int(metadata["expected_cached_tokens"]) * warm_sample_count
    )
    if not valid:
        raise SystemExit(2)


def summarize(output_dir: Path) -> None:
    metadata = json.loads((output_dir / "metadata.json").read_text(encoding="utf-8"))
    if metadata.get("performance_only"):
        summarize_performance(output_dir, metadata)
        return
    cold = json.loads((output_dir / "cold.json").read_text(encoding="utf-8"))
    evict = json.loads((output_dir / "evict.json").read_text(encoding="utf-8"))
    warm = json.loads((output_dir / "warm.json").read_text(encoding="utf-8"))
    metrics_paths = {
        "before": output_dir / "metrics-before.txt",
        "cold": output_dir / "metrics-after-cold.txt",
        "evict": output_dir / "metrics-after-evict.txt",
        "warm": output_dir / "metrics-after-warm.txt",
    }
    metrics: dict[str, float] = {}
    missing_metrics = [str(path) for path in metrics_paths.values() if not path.is_file()]
    if missing_metrics:
        fail(f"required metric snapshots are absent: {', '.join(missing_metrics)}")
    names = [
        "kvbm_offload_blocks_d2d",
        "kvbm_onboard_blocks_d2d",
        "kvbm_matched_tokens",
        "kvbm_disk_cache_hit_rate",
    ]
    for snapshot, path in metrics_paths.items():
        for name in names:
            metrics[f"{snapshot}_{name}"] = prometheus_value(path, name)
    cold_ttft = float(cold["ttft_seconds"])
    warm_ttft = float(warm["ttft_seconds"])
    cold_total = float(cold["total_seconds"])
    evict_total = float(evict["total_seconds"])
    warm_total = float(warm["total_seconds"])
    actual_cold_tokens = cold.get("usage", {}).get("prompt_tokens")
    actual_evict_tokens = evict.get("usage", {}).get("prompt_tokens")
    actual_warm_tokens = warm.get("usage", {}).get("prompt_tokens")
    cold_cached_tokens = (
        (cold.get("usage", {}).get("prompt_tokens_details") or {}).get("cached_tokens")
        or 0
    )
    warm_cached_tokens = (
        (warm.get("usage", {}).get("prompt_tokens_details") or {}).get("cached_tokens")
        or 0
    )
    evict_cached_tokens = (
        (evict.get("usage", {}).get("prompt_tokens_details") or {}).get("cached_tokens")
        or 0
    )
    summary: dict[str, Any] = {
        "run_id": metadata["run_id"],
        "payload_sha256": metadata["payload_sha256"],
        "eviction_payload_sha256": metadata["eviction_payload_sha256"],
        "predicted_input_tokens": metadata["predicted_input_tokens"],
        "eviction_predicted_input_tokens": metadata[
            "eviction_predicted_input_tokens"
        ],
        "cold_input_tokens": actual_cold_tokens,
        "eviction_input_tokens": actual_evict_tokens,
        "warm_input_tokens": actual_warm_tokens,
        "cold_cached_tokens": cold_cached_tokens,
        "eviction_cached_tokens": evict_cached_tokens,
        "warm_cached_tokens": warm_cached_tokens,
        "expected_answer": metadata["expected_answer"],
        "eviction_expected_answer": metadata["eviction_expected_answer"],
        "cold_answer": cold["answer"],
        "eviction_answer": evict["answer"],
        "warm_answer": warm["answer"],
        "cold_answer_correct": cold["answer_correct"],
        "eviction_answer_correct": evict["answer_correct"],
        "warm_answer_correct": warm["answer_correct"],
        "cold_ttft_seconds": cold_ttft,
        "eviction_ttft_seconds": float(evict["ttft_seconds"]),
        "warm_gds_ttft_seconds": warm_ttft,
        "cold_total_seconds": cold_total,
        "eviction_total_seconds": evict_total,
        "warm_gds_total_seconds": warm_total,
        "ttft_saved_seconds": cold_ttft - warm_ttft,
        "ttft_speedup": cold_ttft / warm_ttft if warm_ttft else None,
        "total_saved_seconds": cold_total - warm_total,
        "total_speedup": cold_total / warm_total if warm_total else None,
        "cold_x_request_id": cold.get("response_x_request_id"),
        "eviction_x_request_id": evict.get("response_x_request_id"),
        "warm_x_request_id": warm.get("response_x_request_id"),
        "cold_dynamo_response_id": cold.get("dynamo_response_id"),
        "eviction_dynamo_response_id": evict.get("dynamo_response_id"),
        "warm_dynamo_response_id": warm.get("dynamo_response_id"),
        "kv_block_size_tokens": metadata["kv_block_size_tokens"],
        "kv_mib_per_block": metadata["kv_mib_per_block"],
        "expected_cached_tokens": metadata["expected_cached_tokens"],
        "expected_kv_blocks": metadata["expected_kv_blocks"],
        "expected_eviction_kv_blocks": metadata["expected_eviction_kv_blocks"],
        "expected_gds_mib": metadata["expected_gds_mib"],
        "expected_eviction_gds_mib": metadata["expected_eviction_gds_mib"],
        "expected_gds_ops": metadata["expected_gds_ops"],
        "expected_eviction_gds_ops": metadata["expected_eviction_gds_ops"],
        "expected_pd_mib": metadata["expected_pd_mib"],
        "expected_pd_descriptors": metadata["expected_pd_descriptors"],
        "expected_eviction_pd_mib": metadata["expected_eviction_pd_mib"],
        "expected_eviction_pd_descriptors": metadata[
            "expected_eviction_pd_descriptors"
        ],
        "metrics": metrics,
    }
    if metrics:
        summary["cold_offload_blocks_d2d_delta"] = (
            metrics["cold_kvbm_offload_blocks_d2d"]
            - metrics["before_kvbm_offload_blocks_d2d"]
        )
        summary["eviction_offload_blocks_d2d_delta"] = (
            metrics["evict_kvbm_offload_blocks_d2d"]
            - metrics["cold_kvbm_offload_blocks_d2d"]
        )
        summary["warm_onboard_blocks_d2d_delta"] = (
            metrics["warm_kvbm_onboard_blocks_d2d"]
            - metrics["evict_kvbm_onboard_blocks_d2d"]
        )
        summary["kvbm_matched_tokens_counter_delta"] = (
            metrics["warm_kvbm_matched_tokens"]
            - metrics["evict_kvbm_matched_tokens"]
        )
        summary["warm_disk_cache_hit_rate"] = metrics[
            "warm_kvbm_disk_cache_hit_rate"
        ]
    (output_dir / "comparison.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    markdown = f"""# Near-40K Cold Prefill vs Warm GDS Reload

| Metric | Cold A | Overwrite B | Warm A |
|---|---:|---:|---:|
| Input tokens | {actual_cold_tokens} | {actual_evict_tokens} | {actual_warm_tokens} |
| Correct answer | {cold['answer_correct']} | {evict['answer_correct']} | {warm['answer_correct']} |
| TTFT | {cold_ttft:.3f} s | {float(evict['ttft_seconds']):.3f} s | {warm_ttft:.3f} s |
| Total | {cold_total:.3f} s | {evict_total:.3f} s | {warm_total:.3f} s |
| Cached/matched request tokens | {cold_cached_tokens} | {evict_cached_tokens} | {warm_cached_tokens} |
| Device→Disk offload blocks | {summary.get('cold_offload_blocks_d2d_delta', 'n/a')} | {summary.get('eviction_offload_blocks_d2d_delta', 'n/a')} | — |
| Disk→Device onboard blocks | — | — | {summary.get('warm_onboard_blocks_d2d_delta', 'n/a')} |

- Run ID: `{metadata['run_id']}`
- Payload SHA-256: `{metadata['payload_sha256']}`
- Overwrite payload SHA-256: `{metadata['eviction_payload_sha256']}`
- Expected/Cold/Warm: `{metadata['expected_answer']}` / `{cold['answer']}` / `{warm['answer']}`
- Overwrite expected/actual: `{metadata['eviction_expected_answer']}` / `{evict['answer']}`
- Full-KV gate: `{metadata['expected_kv_blocks']}` blocks × `{metadata['kv_mib_per_block']}` MiB = `{metadata['expected_gds_mib']}` MiB actual GDS write/read
- TTFT saved: {summary['ttft_saved_seconds']:.3f} s
- TTFT speedup: {summary['ttft_speedup']:.3f}x
- Total saved: {summary['total_saved_seconds']:.3f} s
- Total speedup: {summary['total_speedup']:.3f}x
- Raw KVBM matched-token counter delta: {summary.get('kvbm_matched_tokens_counter_delta', 'n/a')} (runtime-internal cumulative accounting)
"""
    (output_dir / "comparison.md").write_text(markdown, encoding="utf-8")
    print(markdown)
    valid = (
        cold["http_status"] == 200
        and evict["http_status"] == 200
        and warm["http_status"] == 200
        and cold["answer_correct"]
        and evict["answer_correct"]
        and warm["answer_correct"]
        and cold["payload_sha256"] == warm["payload_sha256"]
        and cold["payload_sha256"] != evict["payload_sha256"]
        and actual_cold_tokens == actual_warm_tokens
        and actual_cold_tokens == metadata["predicted_input_tokens"]
        and actual_evict_tokens == metadata["eviction_predicted_input_tokens"]
        and TARGET_MIN <= int(actual_cold_tokens or 0) <= TARGET_MAX
        and TARGET_MIN <= int(actual_evict_tokens or 0) <= TARGET_MAX
        and int(cold_cached_tokens) == 0
        and int(evict_cached_tokens) == 0
        and int(warm_cached_tokens) == int(metadata["expected_cached_tokens"])
    )
    if metrics:
        valid = valid and (
            int(summary["cold_offload_blocks_d2d_delta"])
            == int(metadata["expected_kv_blocks"])
            and int(summary["eviction_offload_blocks_d2d_delta"])
            == int(metadata["expected_eviction_kv_blocks"])
            and int(summary["warm_onboard_blocks_d2d_delta"])
            == int(metadata["expected_kv_blocks"])
            and int(summary["kvbm_matched_tokens_counter_delta"])
            >= int(metadata["expected_cached_tokens"])
        )
    if not valid:
        raise SystemExit(2)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    prepare_parser = subparsers.add_parser("prepare")
    prepare_parser.add_argument("--output-dir", required=True, type=Path)
    prepare_parser.add_argument("--run-id")
    prepare_parser.add_argument(
        "--performance-only",
        action="store_true",
        help="prepare only A for the minimum-overhead Cold A -> Warm A path",
    )
    request_parser = subparsers.add_parser("request")
    request_parser.add_argument("--output-dir", required=True, type=Path)
    request_parser.add_argument(
        "--label", required=True, choices=("cold", "evict", "warm")
    )
    request_parser.add_argument("--endpoint")
    summary_parser = subparsers.add_parser("summarize")
    summary_parser.add_argument("--output-dir", required=True, type=Path)
    return parser


def main() -> None:
    args = build_parser().parse_args()
    if args.command == "prepare":
        prepare(
            args.output_dir,
            args.run_id,
            performance_only=args.performance_only,
        )
    elif args.command == "request":
        request_once(args.output_dir, args.label, args.endpoint)
    elif args.command == "summarize":
        summarize(args.output_dir)


if __name__ == "__main__":
    main()
