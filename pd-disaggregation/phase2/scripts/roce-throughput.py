#!/usr/bin/env python3
"""Sample RoCE port counters and summarize per-request throughput evidence."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import statistics
import sys
import time
from pathlib import Path


COUNTER_DIR = Path("/sys/class/infiniband/mlx5_0/ports/1/counters")
RX_COUNTER = COUNTER_DIR / "port_rcv_data"
TX_COUNTER = COUNTER_DIR / "port_xmit_data"
COUNTER_UNIT_BYTES = 4


def positive_float(value: str) -> float:
    number = float(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("value must be greater than zero")
    return number


def read_counter(path: Path) -> int:
    return int(path.read_text(encoding="ascii").strip())


def sample(interval_ms: float) -> int:
    for counter in (RX_COUNTER, TX_COUNTER):
        if not counter.is_file():
            raise SystemExit(f"RoCE counter is unavailable: {counter}")

    stopping = False

    def request_stop(_signum: int, _frame: object) -> None:
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)

    interval_seconds = interval_ms / 1000.0
    next_sample = time.monotonic()
    writer = csv.writer(sys.stdout, lineterminator="\n")
    writer.writerow(("monotonic_ns", "port_rcv_data_words", "port_xmit_data_words"))
    sys.stdout.flush()

    try:
        while not stopping:
            now_ns = time.monotonic_ns()
            writer.writerow((now_ns, read_counter(RX_COUNTER), read_counter(TX_COUNTER)))
            sys.stdout.flush()
            next_sample += interval_seconds
            delay = next_sample - time.monotonic()
            if delay > 0:
                time.sleep(delay)
            else:
                next_sample = time.monotonic()
    except (BrokenPipeError, ConnectionResetError):
        # Prevent CPython's final stdout flush from emitting a second broken-pipe
        # warning when the controlling SSH process closes the channel.
        sys.stdout = open(os.devnull, "w", encoding="utf-8")
        return 0
    return 0


def load_samples(path: Path) -> list[tuple[int, int, int]]:
    samples: list[tuple[int, int, int]] = []
    with path.open(newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        required = {
            "monotonic_ns",
            "port_rcv_data_words",
            "port_xmit_data_words",
        }
        if set(reader.fieldnames or ()) != required:
            raise ValueError(f"unexpected CSV columns in {path}")
        for row in reader:
            samples.append(
                (
                    int(row["monotonic_ns"]),
                    int(row["port_rcv_data_words"]),
                    int(row["port_xmit_data_words"]),
                )
            )
    if len(samples) < 2:
        raise ValueError(f"fewer than two RoCE samples in {path}")
    return samples


def active_window(
    path: Path,
    direction: str,
    expected_payload_bytes: int,
) -> dict[str, float | int | str]:
    samples = load_samples(path)
    sample_interval_ms = statistics.median(
        (samples[index][0] - samples[index - 1][0]) / 1_000_000
        for index in range(1, len(samples))
    )
    counter_index = 1 if direction == "rx" else 2
    # Ignore tiny control-plane changes at the edges. A real 6 GiB KV movement is
    # many orders of magnitude larger; 64 KiB retains even slow data intervals.
    active_step_bytes = 64 * 1024
    active_indices: list[int] = []
    busy_seconds = 0.0
    for index in range(1, len(samples)):
        delta_words = samples[index][counter_index] - samples[index - 1][counter_index]
        if delta_words > 0 and delta_words * COUNTER_UNIT_BYTES >= active_step_bytes:
            active_indices.append(index)
            busy_seconds += (samples[index][0] - samples[index - 1][0]) / 1_000_000_000
    if not active_indices:
        raise ValueError(f"no significant {direction.upper()} RoCE activity in {path}")

    first = active_indices[0] - 1
    last = active_indices[-1]
    delta_words = samples[last][counter_index] - samples[first][counter_index]
    if delta_words < 0:
        raise ValueError(f"RoCE counter decreased in {path}")
    counter_bytes = delta_words * COUNTER_UNIT_BYTES
    if counter_bytes < expected_payload_bytes * 0.90:
        raise ValueError(
            f"only {counter_bytes} {direction.upper()} bytes observed in {path}; "
            f"expected approximately {expected_payload_bytes}"
        )
    activity_span_seconds = (samples[last][0] - samples[first][0]) / 1_000_000_000
    if busy_seconds <= 0 or activity_span_seconds <= 0:
        raise ValueError(f"invalid activity duration in {path}")
    return {
        "counter": f"port_{'rcv' if direction == 'rx' else 'xmit'}_data",
        "direction": direction,
        "counter_bytes": counter_bytes,
        "busy_seconds": busy_seconds,
        "activity_span_seconds": activity_span_seconds,
        "sample_count": len(samples),
        "sample_interval_ms": sample_interval_ms,
        "busy_interval_count": len(active_indices),
    }


def throughput_record(
    label: str,
    path_name: str,
    measurement: dict[str, float | int | str],
    duration_seconds: float,
    duration_source: str,
) -> dict[str, float | int | str]:
    counter_bytes = int(measurement["counter_bytes"])
    return {
        "label": label,
        "path": path_name,
        **measurement,
        "duration_seconds": duration_seconds,
        "duration_source": duration_source,
        "throughput_mib_per_second": counter_bytes / (1024**2) / duration_seconds,
        "throughput_gigabits_per_second": counter_bytes * 8 / 1_000_000_000 / duration_seconds,
        "activity_span_mib_per_second": counter_bytes
        / (1024**2)
        / float(measurement["activity_span_seconds"]),
        "sampled_busy_lower_bound_mib_per_second": counter_bytes
        / (1024**2)
        / float(measurement["busy_seconds"]),
        "sampled_busy_lower_bound_gigabits_per_second": counter_bytes
        * 8
        / 1_000_000_000
        / float(measurement["busy_seconds"]),
    }


def nixl_transfer_times(decode_log: Path, count: int) -> list[float]:
    pattern = re.compile(
        r"KV Transfer metrics:.*?Avg xfer time \(ms\)=([0-9.]+).*?"
        r"Avg MB per transfer=([0-9.]+)"
    )
    matches = [
        (float(match.group(1)), float(match.group(2)))
        for match in pattern.finditer(decode_log.read_text(encoding="utf-8", errors="replace"))
    ]
    if len(matches) < count:
        raise ValueError(
            f"found {len(matches)} NIXL transfer metrics in {decode_log}, need {count}"
        )
    return [milliseconds / 1000.0 for milliseconds, _mib in matches[-count:]]


def display_label(label: str) -> str:
    if label == "cold":
        return "Cold"
    if label == "warm":
        return "Warm 1"
    return label.replace("warm-", "Warm ")


def format_record(prefix: str, record: dict[str, float | int | str]) -> str:
    mib = int(record["counter_bytes"]) / (1024**2)
    seconds = float(record["duration_seconds"])
    mibps = float(record["throughput_mib_per_second"])
    gbps = float(record["throughput_gigabits_per_second"])
    return (
        f"{prefix:<23}: {mib:,.1f} MiB / {seconds:.3f} s "
        f"= {mibps:,.1f} MiB/s ({gbps:.2f} Gbps)"
    )


def format_busy_lower_bound(prefix: str, record: dict[str, float | int | str]) -> str:
    busy_seconds = float(record["busy_seconds"])
    mibps = float(record["sampled_busy_lower_bound_mib_per_second"])
    gbps = float(record["sampled_busy_lower_bound_gigabits_per_second"])
    return (
        f"{prefix:<23}: >= {mibps:,.1f} MiB/s (>= {gbps:.2f} Gbps); "
        f"{busy_seconds:.3f} s occupied sample bins"
    )


def summarize(run_dir: Path, output: Path | None) -> int:
    comparison_path = run_dir / "comparison.json"
    decode_log = run_dir / "decode.log"
    with comparison_path.open(encoding="utf-8") as handle:
        comparison = json.load(handle)

    warm_count = int(comparison.get("warm_sample_count", 1))
    labels = ["cold"] + ["warm" if index == 1 else f"warm-{index}" for index in range(1, warm_count + 1)]
    expected_pd_bytes = int(round(float(comparison["expected_pd_mib"]) * 1024**2))
    expected_gds_bytes = int(round(float(comparison["expected_gds_mib"]) * 1024**2))
    transfer_times = nixl_transfer_times(decode_log, len(labels))

    p_to_d: list[dict[str, float | int | str]] = []
    reloads: list[dict[str, float | int | str]] = []
    offload: dict[str, float | int | str] | None = None
    for index, label in enumerate(labels):
        node2_csv = run_dir / f"roce-{label}-node2.csv"
        pd_measurement = active_window(node2_csv, "rx", expected_pd_bytes)
        p_to_d.append(
            throughput_record(
                display_label(label),
                "Prefill->Decode",
                pd_measurement,
                transfer_times[index],
                "NIXL Avg xfer time",
            )
        )

        node3_csv = run_dir / f"roce-{label}-node3.csv"
        if label == "cold":
            nfs_measurement = active_window(node3_csv, "rx", expected_gds_bytes)
            offload = throughput_record(
                "Cold",
                "Prefill->NFS Offload",
                nfs_measurement,
                float(nfs_measurement["activity_span_seconds"]),
                "node3 RX first-to-last RoCE activity",
            )
        else:
            nfs_measurement = active_window(node3_csv, "tx", expected_gds_bytes)
            reloads.append(
                throughput_record(
                    display_label(label),
                    "NFS->Prefill Reload",
                    nfs_measurement,
                    float(nfs_measurement["activity_span_seconds"]),
                    "node3 TX first-to-last RoCE activity",
                )
            )

    assert offload is not None
    result = {
        "measurement": {
            "counter_source": "/sys/class/infiniband/mlx5_0/ports/1/counters/port_{rcv,xmit}_data",
            "counter_unit_bytes": COUNTER_UNIT_BYTES,
            "meaning": "RoCE port data bytes observed by the NIC; includes transport overhead",
        },
        "prefill_to_decode": p_to_d,
        "prefill_to_nfs_offload": offload,
        "nfs_to_prefill_reload": reloads,
        "warm_medians": {
            "prefill_to_decode_mib_per_second": statistics.median(
                float(item["throughput_mib_per_second"]) for item in p_to_d[1:]
            ),
            "prefill_to_decode_gigabits_per_second": statistics.median(
                float(item["throughput_gigabits_per_second"]) for item in p_to_d[1:]
            ),
            "nfs_to_prefill_reload_mib_per_second": statistics.median(
                float(item["throughput_mib_per_second"]) for item in reloads
            ),
            "nfs_to_prefill_reload_gigabits_per_second": statistics.median(
                float(item["throughput_gigabits_per_second"]) for item in reloads
            ),
        },
    }
    output_path = output or run_dir / "roce-throughput.json"
    output_path.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")

    print("\n=== Measured RoCE throughput (NIC hardware port counters) ===")
    for record in p_to_d:
        print(format_record(f"P->D {record['label']}", record))
    print(format_record("NFS Offload Cold", offload))
    print(format_busy_lower_bound("  sampled-busy floor", offload))
    for record in reloads:
        print(format_record(f"NFS Reload {record['label']}", record))
        print(format_busy_lower_bound("  sampled-busy floor", record))
    print(
        f"P->D Warm median       : "
        f"{result['warm_medians']['prefill_to_decode_mib_per_second']:,.1f} MiB/s "
        f"({result['warm_medians']['prefill_to_decode_gigabits_per_second']:.2f} Gbps)"
    )
    print(
        f"NFS Reload Warm median : "
        f"{result['warm_medians']['nfs_to_prefill_reload_mib_per_second']:,.1f} MiB/s "
        f"({result['warm_medians']['nfs_to_prefill_reload_gigabits_per_second']:.2f} Gbps)"
    )
    print(
        "Measurement scope      : NIC RoCE bytes; P->D uses NIXL xfer time, "
        "NFS uses first-to-last NIC activity"
    )
    print(
        f"NFS sampling resolution : {float(offload['sample_interval_ms']):.1f} ms; "
        "busy rate is a conservative lower bound"
    )
    print(f"RoCE evidence JSON     : {output_path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    sample_parser = subparsers.add_parser("sample")
    sample_parser.add_argument("--interval-ms", type=positive_float, default=50.0)

    summarize_parser = subparsers.add_parser("summarize")
    summarize_parser.add_argument("--run-dir", type=Path, required=True)
    summarize_parser.add_argument("--output", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.command == "sample":
        return sample(args.interval_ms)
    if args.command == "summarize":
        return summarize(args.run_dir, args.output)
    raise AssertionError(args.command)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, KeyError) as error:
        print(f"ERROR: cannot calculate RoCE throughput: {error}", file=sys.stderr)
        raise SystemExit(1)
