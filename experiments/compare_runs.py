#!/usr/bin/env python3
"""Validate and compare at least three equivalent experiment runs."""

from __future__ import annotations

import argparse
import csv
import json
import pathlib
import statistics


COMPARABLE_PARAMETER_KEYS = (
    "model",
    "tenants",
    "tenant_selection",
    "configured_tenant_count",
    "warmup_seconds",
    "steady_seconds",
    "cooldown_seconds",
    "vus_per_tenant",
    "think_time_min_seconds",
    "think_time_max_seconds",
    "think_time_distribution",
    "authentication",
    "k6_mode",
    "k6_version",
    "experiment_protocol",
    "experiment_batch_id",
    "profile_cpus",
    "profile_memory_mib",
    "profile_disk",
    "images_lock_sha256",
)

FIXED_COST_V2_TENANTS = {
    "iso": ["arm"],
    "shared": [
        "amazon",
        "amd",
        "apple",
        "azure",
        "google",
        "meta",
        "netflix",
        "nvidia",
        "paypal",
        "reddit",
    ],
}


def load_json_value(path: pathlib.Path) -> object:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_json(path: pathlib.Path) -> dict[str, object]:
    payload = load_json_value(path)
    if not isinstance(payload, dict):
        raise ValueError(f"{path} must contain a JSON object")
    return payload


def comparable_parameters(parameters: dict[str, object]) -> dict[str, object]:
    return {
        key: parameters.get(key)
        for key in COMPARABLE_PARAMETER_KEYS
        if key in parameters
    }


def image_signature(images: object, path: pathlib.Path) -> list[tuple[str, str, str]]:
    if not isinstance(images, list):
        raise ValueError(f"{path} must contain a JSON array")

    signature = set()
    for image in images:
        if not isinstance(image, dict):
            raise ValueError(f"{path} contains a non-object image entry")
        signature.add(
            (
                str(image.get("container", "")),
                str(image.get("image", "")),
                str(image.get("image_id", "")),
            )
        )
    return sorted(signature)


def nested_metric(
    summary: dict[str, object], metric: str, value: str
) -> float | None:
    metrics = summary.get("metrics")
    if not isinstance(metrics, dict):
        return None
    item = metrics.get(metric)
    if not isinstance(item, dict):
        return None
    values = item.get("values")
    if not isinstance(values, dict):
        return None
    result = values.get(value)
    return float(result) if isinstance(result, (int, float)) else None


def enriched_metrics(
    prometheus: dict[str, object],
    k6: dict[str, object],
    parameters: dict[str, object],
) -> dict[str, object]:
    metrics = dict(prometheus)
    steady_seconds = parameters.get("steady_seconds")
    tenants = parameters.get("tenants")
    tenant_count = len(tenants) if isinstance(tenants, list) else 0

    steady_requests = nested_metric(k6, "http_reqs{phase:steady}", "count")
    if steady_requests is not None:
        metrics["k6_steady_http_requests"] = steady_requests
        if isinstance(steady_seconds, (int, float)) and steady_seconds > 0:
            metrics["k6_steady_rps"] = steady_requests / steady_seconds

    k6_metric_mapping = {
        "k6_steady_checks_rate": ("checks{phase:steady}", "rate"),
        "k6_steady_error_rate": ("http_req_failed{phase:steady}", "rate"),
        "k6_steady_latency_p50_ms": (
            "http_req_duration{phase:steady}",
            "p(50)",
        ),
        "k6_steady_latency_p95_ms": (
            "http_req_duration{phase:steady}",
            "p(95)",
        ),
        "k6_steady_latency_p99_ms": (
            "http_req_duration{phase:steady}",
            "p(99)",
        ),
    }
    for output_name, (metric_name, value_name) in k6_metric_mapping.items():
        value = nested_metric(k6, metric_name, value_name)
        if value is not None:
            metrics[output_name] = value

    metrics.setdefault("tenant_count", tenant_count)
    rps = metrics.get("rps")
    if isinstance(rps, (int, float)) and tenant_count > 0:
        metrics.setdefault("rps_per_tenant", rps / tenant_count)
        cpu = metrics.get("cpu_cores")
        memory = metrics.get("memory_working_set_bytes")
        if rps > 0 and isinstance(cpu, (int, float)):
            metrics.setdefault("cpu_cores_per_rps", cpu / rps)
        if rps > 0 and isinstance(memory, (int, float)):
            metrics.setdefault("memory_bytes_per_rps", memory / rps)

    return metrics


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Calculate mean and sample standard deviation across experiment runs."
    )
    parser.add_argument("runs", nargs="+", type=pathlib.Path)
    parser.add_argument("--output-prefix", type=pathlib.Path, default=pathlib.Path("comparison"))
    args = parser.parse_args()

    if len(args.runs) < 3:
        parser.error("provide at least three result directories")

    loaded: list[tuple[str, dict[str, object]]] = []
    expected_parameters: dict[str, object] | None = None
    expected_images: list[tuple[str, str, str]] | None = None
    seen_repetitions: set[int] = set()

    for run in args.runs:
        parameters_path = run / "parameters.json"
        images_path = run / "images.json"
        exit_code_path = run / "k6-exit-code.txt"
        parameters = load_json(parameters_path)
        prometheus = load_json(run / "metrics-summary.json")
        k6 = load_json(run / "k6-summary.json")

        exit_code = exit_code_path.read_text(encoding="utf-8").strip()
        if exit_code not in {"0", "99"}:
            parser.error(f"{run}: k6 exited with non-measurement code {exit_code}")

        current_parameters = comparable_parameters(parameters)
        if expected_parameters is None:
            expected_parameters = current_parameters
        elif current_parameters != expected_parameters:
            parser.error(
                f"{run}: parameters do not match the first run\n"
                f"expected: {json.dumps(expected_parameters, sort_keys=True)}\n"
                f"actual:   {json.dumps(current_parameters, sort_keys=True)}"
            )

        current_images = image_signature(load_json_value(images_path), images_path)
        if expected_images is None:
            expected_images = current_images
        elif current_images != expected_images:
            parser.error(f"{run}: container images do not match the first run")

        protocol = parameters.get("experiment_protocol")
        if protocol == "fixed-cost-v1" and parameters.get("tenant_selection") != "full":
            parser.error(f"{run}: fixed-cost-v1 requires the full tenant set")

        if protocol == "fixed-cost-v2":
            model = parameters.get("model")
            expected_tenants = FIXED_COST_V2_TENANTS.get(str(model))
            if expected_tenants is not None and parameters.get("tenants") != expected_tenants:
                parser.error(
                    f"{run}: fixed-cost-v2 {model} tenants must be {expected_tenants}"
                )
            if expected_tenants is None and parameters.get("tenant_selection") != "full":
                parser.error(
                    f"{run}: fixed-cost-v2 secondary models require the full tenant set"
                )

        repetition = parameters.get("experiment_repetition")
        if protocol in {"fixed-cost-v1", "fixed-cost-v2"}:
            if not isinstance(repetition, int):
                parser.error(f"{run}: {protocol} requires a repetition number")
            if repetition in seen_repetitions:
                parser.error(f"{run}: duplicate repetition number {repetition}")
            seen_repetitions.add(repetition)

        run_metrics = enriched_metrics(prometheus, k6, parameters)
        run_metrics["k6_thresholds_passed"] = 1.0 if exit_code == "0" else 0.0
        loaded.append((run.name, run_metrics))

    common_metrics = set.intersection(
        *(set(summary) for _, summary in loaded)
    )
    comparison = {}
    for metric in sorted(common_metrics):
        values = [
            float(summary[metric])
            for _, summary in loaded
            if isinstance(summary.get(metric), (int, float))
        ]
        if len(values) != len(loaded):
            continue
        comparison[metric] = {
            "runs": len(values),
            "mean": statistics.fmean(values),
            "sample_standard_deviation": statistics.stdev(values),
            "minimum": min(values),
            "maximum": max(values),
            "values": [
                {"run": run_name, "value": float(summary[metric])}
                for run_name, summary in loaded
            ],
        }

    json_path = args.output_prefix.with_suffix(".json")
    csv_path = args.output_prefix.with_suffix(".csv")
    json_path.parent.mkdir(parents=True, exist_ok=True)
    with json_path.open("w", encoding="utf-8") as handle:
        json.dump(comparison, handle, indent=2, sort_keys=True)
        handle.write("\n")

    with csv_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(
            ["metric", "runs", "mean", "sample_standard_deviation", "minimum", "maximum"]
        )
        for metric, values in comparison.items():
            writer.writerow(
                [
                    metric,
                    values["runs"],
                    values["mean"],
                    values["sample_standard_deviation"],
                    values["minimum"],
                    values["maximum"],
                ]
            )

    print(f"Wrote {json_path} and {csv_path}")


if __name__ == "__main__":
    main()
