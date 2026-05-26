import csv
import math
import os
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
VALIDATION_MIN_ROWS = 10
VALIDATION_FRACTION = 0.25
TRAINING_STEPS = 2500
LEARNING_RATE = 0.05
L2 = 0.001
DEFAULT_THRESHOLD = 0.55


def env_float(name, default=None):
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError:
        return default


THRESHOLD_OVERRIDE = env_float("MODEL_THRESHOLD")


def clamp_threshold(value):
    return min(max(value, 0.01), 0.99)


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
    except (TypeError, ValueError):
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


def active_threshold():
    if THRESHOLD_OVERRIDE is not None:
        return clamp_threshold(THRESHOLD_OVERRIDE)

    return DEFAULT_THRESHOLD


def safe_write_text(target, text):
    tmp = target.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8")

    try:
        os.replace(tmp, target)
    except OSError:
        target.write_text(text, encoding="utf-8")


def write_model(
    enabled,
    reason,
    rows,
    weights=None,
    bias=0.0,
    mean=None,
    scale=None,
    threshold=None,
    metadata=None,
):
    target = model_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    weights = weights or [0.0 for _ in FEATURES]
    mean = mean or [0.0 for _ in FEATURES]
    scale = scale or [1.0 for _ in FEATURES]
    threshold = active_threshold() if threshold is None else threshold
    metadata = metadata or {}
    wins = sum(1 for row in rows if row["label"] == 1)
    losses = len(rows) - wins

    lines = {
        "enabled": "1" if enabled else "0",
        "reason": reason,
        "trained_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "trained_rows": str(len(rows)),
        "wins": str(wins),
        "losses": str(losses),
        "threshold": f"{threshold:.6f}",
        "features": ",".join(FEATURES),
        "mean": ",".join(f"{value:.10f}" for value in mean),
        "scale": ",".join(f"{value:.10f}" for value in scale),
        "weights": ",".join(f"{value:.10f}" for value in weights),
        "bias": f"{bias:.10f}",
    }

    for key, value in metadata.items():
        lines[key] = str(value)

    safe_write_text(target, "\n".join(f"{key}={value}" for key, value in lines.items()) + "\n")
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


def median(values):
    ordered = sorted(values)
    if not ordered:
        return 0.0

    midpoint = len(ordered) // 2
    if len(ordered) % 2:
        return ordered[midpoint]

    return (ordered[midpoint - 1] + ordered[midpoint]) / 2.0


def build_sample_weights(rows):
    wins = max(sum(1 for row in rows if row["label"] == 1), 1)
    losses = max(len(rows) - wins, 1)
    abs_profits = [abs(row["profit"]) for row in rows if abs(row["profit"]) > 0.0]
    median_abs_profit = max(median(abs_profits), 0.01)
    weights = []

    for row in rows:
        class_count = wins if row["label"] == 1 else losses
        class_weight = len(rows) / (2.0 * class_count)
        profit_weight = 1.0 + min(abs(row["profit"]) / median_abs_profit, 2.0)
        weights.append(class_weight * profit_weight)

    return weights


def train(rows):
    x_values, mean, scale = normalize(rows)
    y_values = [row["label"] for row in rows]
    sample_weights = build_sample_weights(rows)
    weights = [0.0 for _ in FEATURES]
    bias = 0.0
    total_weight = sum(sample_weights) or 1.0

    for _ in range(TRAINING_STEPS):
        grad_weights = [0.0 for _ in FEATURES]
        grad_bias = 0.0

        for features, label, sample_weight in zip(x_values, y_values, sample_weights):
            prediction = sigmoid(sum(w * x for w, x in zip(weights, features)) + bias)
            error = (prediction - label) * sample_weight
            grad_bias += error

            for index, value in enumerate(features):
                grad_weights[index] += error * value

        bias -= LEARNING_RATE * grad_bias / total_weight

        for index in range(len(weights)):
            gradient = (grad_weights[index] / total_weight) + (L2 * weights[index])
            weights[index] -= LEARNING_RATE * gradient

    return weights, bias, mean, scale


def score_features(features, weights, bias, mean, scale):
    z_value = bias

    for index, value in enumerate(features):
        feature_scale = scale[index] if scale[index] > 1e-9 else 1.0
        z_value += weights[index] * ((value - mean[index]) / feature_scale)

    return sigmoid(z_value)


def evaluate_rows(rows, weights, bias, mean, scale, threshold):
    if not rows:
        return {
            "rows": 0,
            "selected": 0,
            "coverage": 0.0,
            "accuracy": 0.0,
            "precision": 0.0,
            "recall": 0.0,
            "f1": 0.0,
            "win_rate": 0.0,
            "avg_profit": 0.0,
            "total_profit": 0.0,
        }

    scores = [score_features(row["features"], weights, bias, mean, scale) for row in rows]
    selected = [row for row, score in zip(rows, scores) if score >= threshold]
    selected_wins = sum(1 for row in selected if row["label"] == 1)
    selected_losses = len(selected) - selected_wins
    rejected_wins = sum(
        1 for row, score in zip(rows, scores) if score < threshold and row["label"] == 1
    )
    rejected_losses = sum(
        1 for row, score in zip(rows, scores) if score < threshold and row["label"] == 0
    )
    precision = selected_wins / len(selected) if selected else 0.0
    total_wins = selected_wins + rejected_wins
    recall = selected_wins / total_wins if total_wins else 0.0
    f1 = (2.0 * precision * recall / (precision + recall)) if precision + recall else 0.0
    accuracy = (selected_wins + rejected_losses) / len(rows)
    total_profit = sum(row["profit"] for row in selected)
    avg_profit = total_profit / len(selected) if selected else 0.0

    return {
        "rows": len(rows),
        "selected": len(selected),
        "coverage": len(selected) / len(rows),
        "accuracy": accuracy,
        "precision": precision,
        "recall": recall,
        "f1": f1,
        "win_rate": selected_wins / len(selected) if selected else 0.0,
        "avg_profit": avg_profit,
        "total_profit": total_profit,
        "selected_losses": selected_losses,
    }


def can_train(rows):
    wins = sum(1 for row in rows if row["label"] == 1)
    losses = len(rows) - wins
    return len(rows) >= MIN_ROWS and wins >= MIN_CLASS_ROWS and losses >= MIN_CLASS_ROWS


def validation_split(rows):
    if len(rows) < MIN_ROWS + VALIDATION_MIN_ROWS:
        return None, None

    validation_count = max(VALIDATION_MIN_ROWS, int(len(rows) * VALIDATION_FRACTION))
    training_rows = rows[:-validation_count]
    validation_rows = rows[-validation_count:]

    if not can_train(training_rows):
        return None, None

    return training_rows, validation_rows


def choose_threshold(rows):
    if THRESHOLD_OVERRIDE is not None:
        return active_threshold(), {
            "threshold_source": "env",
            "validation_rows": "0",
            "validation_selected": "0",
            "validation_f1": "0.0000",
            "validation_avg_profit": "0.00",
            "validation_total_profit": "0.00",
        }

    training_rows, validation_rows = validation_split(rows)
    if not training_rows:
        return DEFAULT_THRESHOLD, {
            "threshold_source": "default",
            "validation_rows": "0",
            "validation_selected": "0",
            "validation_f1": "0.0000",
            "validation_avg_profit": "0.00",
            "validation_total_profit": "0.00",
        }

    weights, bias, mean, scale = train(training_rows)
    best_threshold = DEFAULT_THRESHOLD
    best_stats = None
    best_objective = None
    minimum_selected = max(2, len(validation_rows) // 5)

    for point in range(35, 86):
        threshold = point / 100.0
        stats = evaluate_rows(validation_rows, weights, bias, mean, scale, threshold)
        if stats["selected"] < minimum_selected:
            continue

        objective = (stats["avg_profit"] * math.sqrt(stats["selected"])) + stats["f1"]
        if best_objective is None or objective > best_objective:
            best_objective = objective
            best_threshold = threshold
            best_stats = stats

    if best_stats is None:
        return DEFAULT_THRESHOLD, {
            "threshold_source": "default",
            "validation_rows": str(len(validation_rows)),
            "validation_selected": "0",
            "validation_f1": "0.0000",
            "validation_avg_profit": "0.00",
            "validation_total_profit": "0.00",
        }

    return best_threshold, {
        "threshold_source": "validation",
        "validation_rows": str(best_stats["rows"]),
        "validation_selected": str(best_stats["selected"]),
        "validation_f1": f"{best_stats['f1']:.4f}",
        "validation_accuracy": f"{best_stats['accuracy']:.4f}",
        "validation_precision": f"{best_stats['precision']:.4f}",
        "validation_recall": f"{best_stats['recall']:.4f}",
        "validation_win_rate": f"{best_stats['win_rate']:.4f}",
        "validation_avg_profit": f"{best_stats['avg_profit']:.2f}",
        "validation_total_profit": f"{best_stats['total_profit']:.2f}",
    }


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

    threshold, metadata = choose_threshold(rows)
    weights, bias, mean, scale = train(rows)
    training_stats = evaluate_rows(rows, weights, bias, mean, scale, threshold)
    metadata.update(
        {
            "training_selected": str(training_stats["selected"]),
            "training_coverage": f"{training_stats['coverage']:.4f}",
            "training_accuracy": f"{training_stats['accuracy']:.4f}",
            "training_precision": f"{training_stats['precision']:.4f}",
            "training_recall": f"{training_stats['recall']:.4f}",
            "training_f1": f"{training_stats['f1']:.4f}",
            "training_avg_profit": f"{training_stats['avg_profit']:.2f}",
            "training_total_profit": f"{training_stats['total_profit']:.2f}",
        }
    )

    target = write_model(
        True,
        "Profit-weighted logistic model trained from closed cycle outcomes.",
        rows,
        weights,
        bias,
        mean,
        scale,
        threshold,
        metadata,
    )
    print(
        "[trainer] threshold="
        f"{threshold:.2f} source={metadata.get('threshold_source', 'default')} "
        f"training_f1={metadata['training_f1']} "
        f"training_total_profit={metadata['training_total_profit']}",
        flush=True,
    )
    if metadata.get("validation_rows") != "0":
        print(
            "[trainer] validation "
            f"rows={metadata['validation_rows']} "
            f"selected={metadata['validation_selected']} "
            f"f1={metadata['validation_f1']} "
            f"avg_profit={metadata['validation_avg_profit']}",
            flush=True,
        )
    print(f"[trainer] model enabled and written: {target}", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
