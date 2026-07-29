import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path


CONTROL_FILE_NAME = "recovery_shield_control.txt"
STATUS_FILE_NAME = "recovery_shield_status.txt"
EVENT_LOG_FILE_NAME = "recovery_shield_events.csv"
CYCLE_LOG_FILE_NAME = "recovery_shield_cycles.csv"
MODEL_FILE_NAME = "recovery_shield_model.txt"
VERSION_FILE_NAME = "recovery_shield_version.txt"
_ROW_COUNT_CACHE = {}
APP_VERSION = "v1.0.7"
EA_BUILD_NUMBER = "10"
EA_VERSION = f"{APP_VERSION}_{EA_BUILD_NUMBER}"

DEFAULT_CONTROL = {
    "enabled": "0",
    "close_all": "0",
    "initial_lot": "0.01",
    "zone_height": "500",
    "multiplier": "1",
    "target_usd": "0.50",
    "quick_target_usd": "0.25",
    "max_loss_usd": "3.00",
    "allow_recovery": "0",
    "take_profit_points": "200",
    "stop_loss_points": "300",
    "max_lot": "0.02",
    "max_same_side": "2",
    "min_same_side_distance": "150",
    "max_turns": "1",
    "max_spread": "300",
}

CONTROL_PRESETS = {
    "quick_safe": {
        "enabled": "1",
        "close_all": "0",
        "initial_lot": "0.01",
        "zone_height": "500",
        "multiplier": "1",
        "target_usd": "0.50",
        "quick_target_usd": "0.20",
        "max_loss_usd": "1.00",
        "allow_recovery": "0",
        "take_profit_points": "250",
        "stop_loss_points": "250",
        "max_lot": "0.01",
        "max_same_side": "1",
        "min_same_side_distance": "400",
        "max_turns": "1",
        "max_spread": "200",
    },
    "quick_now": {
        "enabled": "1",
        "close_all": "0",
        "initial_lot": "0.01",
        "zone_height": "500",
        "multiplier": "1",
        "target_usd": "0.40",
        "quick_target_usd": "0.15",
        "max_loss_usd": "2.00",
        "allow_recovery": "0",
        "take_profit_points": "150",
        "stop_loss_points": "250",
        "max_lot": "0.02",
        "max_same_side": "2",
        "min_same_side_distance": "150",
        "max_turns": "1",
        "max_spread": "400",
    },
}


class SettingsError(ValueError):
    pass


def env_flag(name, default=False):
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def debug_log(message):
    if not env_flag("DASHBOARD_DEBUG", False):
        return
    timestamp = datetime.now().strftime("%H:%M:%S")
    print(f"[dashboard {timestamp}] {message}", flush=True)


def common_files_dir():
    configured = os.environ.get("MT5_COMMON_FILES_DIR")
    if configured:
        return Path(configured).expanduser()

    appdata = os.environ.get("APPDATA")
    if appdata:
        return Path(appdata) / "MetaQuotes" / "Terminal" / "Common" / "Files"

    return Path.cwd() / "mt5_common_files"


def control_file_path():
    return common_files_dir() / CONTROL_FILE_NAME


def status_file_path():
    return common_files_dir() / STATUS_FILE_NAME


def event_log_file_path():
    return common_files_dir() / EVENT_LOG_FILE_NAME


def cycle_log_file_path():
    return common_files_dir() / CYCLE_LOG_FILE_NAME


def model_file_path():
    return common_files_dir() / MODEL_FILE_NAME


def version_file_path():
    return common_files_dir() / VERSION_FILE_NAME


def runtime_paths():
    return {
        "common_files_dir": common_files_dir(),
        "control_file": control_file_path(),
        "status_file": status_file_path(),
        "event_log_file": event_log_file_path(),
        "cycle_log_file": cycle_log_file_path(),
        "model_file": model_file_path(),
        "version_file": version_file_path(),
    }


def read_key_values(path):
    values = {}
    if not path.exists():
        debug_log(f"read missing file: {path}")
        return values

    debug_log(f"read file: {path}")
    try:
        text = path.read_text(encoding="utf-8", errors="ignore")
    except OSError as exc:
        debug_log(f"read failed: {path} {exc}")
        return values

    for raw_line in text.splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key.strip().lstrip("\ufeff")] = value.strip()
    return values


def safe_write_text(target, text):
    tmp = target.with_suffix(".tmp")
    tmp.write_text(text, encoding="utf-8")

    try:
        os.replace(tmp, target)
    except OSError as exc:
        debug_log(f"atomic replace failed, writing directly: {target} {exc}")
        target.write_text(text, encoding="utf-8")


def read_control():
    values = DEFAULT_CONTROL.copy()
    values.update(read_key_values(control_file_path()))
    return values


def read_status():
    return read_key_values(status_file_path())


def read_model():
    values = {
        "enabled": "0",
        "reason": "No model file yet.",
        "trained_rows": "0",
        "wins": "0",
        "losses": "0",
        "threshold": "0.55",
        "trained_at": "-",
        "threshold_source": "default",
        "validation_rows": "0",
        "validation_selected": "0",
        "validation_f1": "0.0000",
        "validation_avg_profit": "0.00",
        "validation_total_profit": "0.00",
        "training_selected": "0",
        "training_coverage": "0.0000",
        "training_accuracy": "0.0000",
        "training_f1": "0.0000",
        "training_avg_profit": "0.00",
        "training_total_profit": "0.00",
    }
    values.update(read_key_values(model_file_path()))
    return values


def read_version():
    values = {
        "app_version": APP_VERSION,
        "ea_version": EA_VERSION,
        "build_number": EA_BUILD_NUMBER,
        "compiled_at": "-",
        "compiled_ex5": "-",
        "version_source": "dashboard-default",
    }
    values.update(read_key_values(version_file_path()))
    return values


def runtime_state(control, status, version):
    command_enabled = control.get("enabled") == "1"
    compiled_version = version.get("ea_version") or EA_VERSION
    running_version = status.get("ea_version", "").strip()
    status_seen = bool(status)
    ea_confirmed = command_enabled and running_version == compiled_version
    version_mismatch = running_version != compiled_version

    if not command_enabled:
        badge_label = "Paused"
        badge_state = "paused"
    elif ea_confirmed:
        badge_label = "EA Confirmed"
        badge_state = "confirmed"
    elif running_version:
        badge_label = "Version Mismatch"
        badge_state = "warning"
    elif status_seen:
        badge_label = "Old EA / Unknown"
        badge_state = "warning"
    else:
        badge_label = "No EA Status"
        badge_state = "warning"

    return {
        "command_enabled": command_enabled,
        "compiled_version": compiled_version,
        "running_version": running_version or "unknown / old EA",
        "status_seen": status_seen,
        "ea_confirmed": ea_confirmed,
        "version_mismatch": version_mismatch,
        "badge_label": badge_label,
        "badge_state": badge_state,
    }


def csv_data_row_count(path):
    if not path.exists():
        return 0

    try:
        stat = path.stat()
    except OSError:
        return 0

    cache_key = str(path)
    cache_state = (stat.st_mtime_ns, stat.st_size)
    cached = _ROW_COUNT_CACHE.get(cache_key)
    if cached and cached["state"] == cache_state:
        return cached["count"]

    try:
        line_count = sum(1 for _ in path.open("r", encoding="utf-8", errors="ignore"))
    except OSError:
        return 0

    count = max(line_count - 1, 0)
    _ROW_COUNT_CACHE[cache_key] = {"state": cache_state, "count": count}

    return count


def write_control(values):
    target = control_file_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    clean = DEFAULT_CONTROL.copy()
    clean.update(values)
    clean["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    clean["updated_by"] = "django"

    lines = [f"{key}={value}" for key, value in clean.items()]
    safe_write_text(target, "\n".join(lines) + "\n")
    debug_log(
        "wrote control: "
        f"path={target} enabled={clean['enabled']} close_all={clean['close_all']} "
        f"lot={clean['initial_lot']} max_spread={clean['max_spread']}"
    )
    return clean


def apply_control_preset(values, preset_name):
    if preset_name not in CONTROL_PRESETS:
        raise SettingsError("Unknown control preset.")

    clean = values.copy()
    clean.update(CONTROL_PRESETS[preset_name])
    return clean


def file_debug_info(path):
    if not path.exists():
        return {"exists": False, "path": str(path), "size": 0, "modified": "-"}

    stat = path.stat()
    modified = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    return {
        "exists": True,
        "path": str(path),
        "size": stat.st_size,
        "modified": modified,
    }


def file_info_bundle(paths):
    return {
        "control_file_info": file_debug_info(paths["control_file"]),
        "status_file_info": file_debug_info(paths["status_file"]),
        "event_log_file_info": file_debug_info(paths["event_log_file"]),
        "cycle_log_file_info": file_debug_info(paths["cycle_log_file"]),
        "model_file_info": file_debug_info(paths["model_file"]),
        "version_file_info": file_debug_info(paths["version_file"]),
    }


def validate_control(post_data):
    return {
        "initial_lot": decimal_value(post_data, "initial_lot", minimum=Decimal("0.01")),
        "zone_height": int_value(post_data, "zone_height", minimum=1, maximum=100000),
        "multiplier": decimal_value(post_data, "multiplier", minimum=Decimal("1.0")),
        "target_usd": decimal_value(post_data, "target_usd", minimum=Decimal("0.01")),
        "quick_target_usd": decimal_value(post_data, "quick_target_usd", minimum=Decimal("0")),
        "max_loss_usd": decimal_value(post_data, "max_loss_usd", minimum=Decimal("0")),
        "allow_recovery": int_value(post_data, "allow_recovery", minimum=0, maximum=1),
        "take_profit_points": int_value(post_data, "take_profit_points", minimum=0, maximum=100000),
        "stop_loss_points": int_value(post_data, "stop_loss_points", minimum=0, maximum=100000),
        "max_lot": decimal_value(post_data, "max_lot", minimum=Decimal("0")),
        "max_same_side": int_value(post_data, "max_same_side", minimum=0, maximum=20),
        "min_same_side_distance": int_value(
            post_data, "min_same_side_distance", minimum=0, maximum=100000
        ),
        "max_turns": int_value(post_data, "max_turns", minimum=1, maximum=20),
        "max_spread": int_value(post_data, "max_spread", minimum=1, maximum=10000),
    }


def decimal_value(post_data, field, minimum):
    raw = str(post_data.get(field, "")).strip()
    try:
        value = Decimal(raw)
    except InvalidOperation as exc:
        raise SettingsError(f"{field.replace('_', ' ')} must be a number.") from exc

    if value < minimum:
        raise SettingsError(f"{field.replace('_', ' ')} must be at least {minimum}.")

    return format(value.normalize(), "f")


def int_value(post_data, field, minimum, maximum):
    raw = str(post_data.get(field, "")).strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise SettingsError(f"{field.replace('_', ' ')} must be a whole number.") from exc

    if value < minimum or value > maximum:
        raise SettingsError(
            f"{field.replace('_', ' ')} must be between {minimum} and {maximum}."
        )

    return str(value)
