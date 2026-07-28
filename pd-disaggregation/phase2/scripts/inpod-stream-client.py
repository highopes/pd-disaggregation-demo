#!/usr/bin/env python3
"""Measure an OpenAI-compatible SSE request from inside the Frontend pod."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
import urllib.request
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True, type=Path)
    parser.add_argument("--label", required=True)
    parser.add_argument("--request-id", required=True)
    parser.add_argument("--expected-answer", required=True)
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000")
    parser.add_argument("--timeout", type=float, default=600.0)
    args = parser.parse_args()

    payload_bytes = args.payload.read_bytes()
    request = urllib.request.Request(
        f"{args.endpoint.rstrip('/')}/v1/chat/completions",
        data=payload_bytes,
        headers={
            "Content-Type": "application/json",
            "Accept": "text/event-stream",
            "X-Request-ID": args.request_id,
        },
        method="POST",
    )
    started = time.perf_counter()
    first_event = None
    ttft = None
    answer: list[str] = []
    usage = {}
    finish_reason = None
    response_id = None
    with urllib.request.urlopen(request, timeout=args.timeout) as response:
        status = response.status
        response_request_id = response.headers.get("X-Request-ID")
        for raw_line in response:
            line = raw_line.decode("utf-8", errors="replace").rstrip("\r\n")
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                break
            if not data:
                continue
            if first_event is None:
                first_event = time.perf_counter() - started
            event = json.loads(data)
            response_id = event.get("id") or response_id
            if event.get("usage"):
                usage = event["usage"]
            choices = event.get("choices") or []
            if choices:
                text = (choices[0].get("delta") or {}).get("content")
                if text:
                    if ttft is None:
                        ttft = time.perf_counter() - started
                    answer.append(text)
                finish_reason = choices[0].get("finish_reason") or finish_reason

    actual_answer = "".join(answer).strip()
    result = {
        "label": args.label,
        "http_status": status,
        "endpoint": args.endpoint,
        "sent_request_id": args.request_id,
        "response_x_request_id": response_request_id,
        "dynamo_response_id": response_id,
        "payload_sha256": hashlib.sha256(payload_bytes).hexdigest(),
        "first_event_seconds": first_event,
        "ttft_seconds": ttft,
        "total_seconds": time.perf_counter() - started,
        "answer": actual_answer,
        "expected_answer": args.expected_answer,
        "answer_correct": actual_answer == args.expected_answer,
        "finish_reason": finish_reason,
        "usage": usage,
    }
    print(json.dumps(result, ensure_ascii=False, indent=2))
    if status != 200 or ttft is None or not result["answer_correct"]:
        sys.exit(2)


if __name__ == "__main__":
    main()
