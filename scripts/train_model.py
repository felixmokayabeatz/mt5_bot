import csv
import math
import os
import sys
from datetime import datetime, timezone
from pathlib import Path


FEATURES = [
    "spread",
    "hour",
    "day_of_week",
    "atr_points",
    "last_range_points",
    "ma_delta_points",
    "rsi14",
    "feature_zone_height",
    "feature_multiplier",
    "feature_max_turns",
]

MIN_ROWS = 30
MIN_CLASS_ROWS = 5
TRAINING_STEPS = 2500
LEARNING_RATE = 0.05
L2 = 0.001


def env_float(name, default):
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


THRESHOLD = env_float("MODEL_THRESHOLD", 0.55)


def common_files_dir():
    configured = os.environ.get("MT5_COMMON_FILES_DIR")
    if configured:
        return Path(configured).expanduser()

    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"

    return Path.cwd() / "mt5_common_files"


def cycle_log_path():
    return common_files_dir() / "recovery_shield_cycles.csv"


def model_path():
    return common_files_dir() / "recovery_shield_model.txt"


def parse_float(row, key, default=0.0):
    try:
        return float(str(row.get(key, "")).strip())
    except ValueError:
        return default


def load_rows(path):
    if not path.exists():
        return []

    rows = []
    with path.open("r", newline="", encoding="utf-8", errors="ignore") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            if not row:
                continue

            profit = parse_float(row, "exit_profit")
            features = [parse_float(row, name) for name in FEATURES]
            rows.append(
                {
                    "features": features,
                    "label": 1 if profit >= 0.0 else 0,
                    "profit": profit,
                }
            )

    return rows


def write_model(enabled, reason, rows, weights=None, bias=0.0, mean=None, scale=None):
    target = model_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    weights = weights or [0.0 for _ in FEATURES]
    mean = mean or [0.0 for _ in FEATURES]
    scale = scale or [1.0 for _ in FEATURES]
    wins = sum(1 for row in rows if row["label"] == 1)
    losses = len(rows) - wins

    lines = {
        "enabled": "1" if enabled else "0",
        "reason": reason,
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "trained_rows": str(len(rows)),
        "wins": str(wins),
        "losses": str(losses),
        "threshold": f"{THRESHOLD:.6f}",
        "features": ",".join(FEATURES),
        "mean": ",".join(f"{value:.10f}" for value in mean),
        "scale": ",".join(f"{value:.10f}" for value in scale),
        "weights": ",".join(f"{value:.10f}" for value in weights),
        "bias": f"{bias:.10f}",
    }

    target.write_text(
        "\n".join(f"{key}={value}" for key, value in lines.items()) + "\n",
        encoding="utf-8",
    )
    return target


def normalize(rows):
    columns = list(zip(*(row["features"] for row in rows)))
    mean = [sum(column) / len(column) for column in columns]
    scale = []

    for index, column in enumerate(columns):
        variance = sum((value - mean[index]) ** 2 for value in column) / len(column)
        std = math.sqrt(variance)
        scale.append(std if std > 1e-9 else 1.0)

    normalized = []
    for row in rows:
        normalized.append(
            [
                (value - mean[index]) / scale[index]
                for index, value in enumerate(row["features"])
            ]
        )

    return normalized, mean, scale


def sigmoid(value):
    if value > 30.0:
        return 1.0
    if value < -30.0:
        return 0.0
    return 1.0 / (1.0 + math.exp(-value))


def train(rows):
    x_values, mean, scale = normalize(rows)
    y_values = [row["label"] for row in rows]
    weights = [0.0 for _ in FEATURES]
    bias = 0.0
    sample_count = len(rows)

    for _ in range(TRAINING_STEPS):
        grad_weights = [0.0 for _ in FEATURES]
        grad_bias = 0.0

        for features, label in zip(x_values, y_values):
            prediction = sigmoid(sum(w * x for w, x in zip(weights, features)) + bias)
            error = prediction - label
            grad_bias += error

            for index, value in enumerate(features):
                grad_weights[index] += error * value

        bias -= LEARNING_RATE * grad_bias / sample_count

        for index in range(len(weights)):
            gradient = (grad_weights[index] / sample_count) + (L2 * weights[index])
            weights[index] -= LEARNING_RATE * gradient

    return weights, bias, mean, scale


def main():
    path = cycle_log_path()
    rows = load_rows(path)
    wins = sum(1 for row in rows if row["label"] == 1)
    losses = len(rows) - wins

    print(f"[trainer] cycle log: {path}", flush=True)
    print(f"[trainer] rows={len(rows)} wins={wins} losses={losses}", flush=True)

    if len(rows) < MIN_ROWS:
        reason = f"Need at least {MIN_ROWS} closed cycles before enabling model."
        target = write_model(False, reason, rows)
        print(f"[trainer] {reason}", flush=True)
        print(f"[trainer] wrote recording-only model: {target}", flush=True)
        return 0

    if wins < MIN_CLASS_ROWS or losses < MIN_CLASS_ROWS:
        reason = f"Need at least {MIN_CLASS_ROWS} wins and {MIN_CLASS_ROWS} losses."
        target = write_model(False, reason, rows)
        print(f"[trainer] {reason}", flush=True)
        print(f"[trainer] wrote recording-only model: {target}", flush=True)
        return 0

    weights, bias, mean, scale = train(rows)
    target = write_model(True, "Logistic model trained from demo cycle outcomes.", rows, weights, bias, mean, scale)
    print(f"[trainer] model enabled and written: {target}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
