import os
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path


CONTROL_FILE_NAME = "recovery_shield_control.txt"
STATUS_FILE_NAME = "recovery_shield_status.txt"

DEFAULT_CONTROL = {
    "enabled": "0",
    "close_all": "0",
    "initial_lot": "0.01",
    "zone_height": "500",
    "multiplier": "1.6",
    "target_usd": "0.50",
    "max_turns": "3",
    "max_spread": "500",
}


class SettingsError(ValueError):
    pass


def debug_log(message):
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


def read_key_values(path):
    values = {}
    if not path.exists():
        debug_log(f"read missing file: {path}")
        return values

    debug_log(f"read file: {path}")
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if "=" not in raw_line:
            continue
        key, value = raw_line.split("=", 1)
        values[key.strip()] = value.strip()
    return values


def read_control():
    values = DEFAULT_CONTROL.copy()
    values.update(read_key_values(control_file_path()))
    return values


def read_status():
    return read_key_values(status_file_path())


def write_control(values):
    target = control_file_path()
    target.parent.mkdir(parents=True, exist_ok=True)

    clean = DEFAULT_CONTROL.copy()
    clean.update(values)
    clean["updated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    clean["updated_by"] = "django"

    lines = [f"{key}={value}" for key, value in clean.items()]
    tmp = target.with_suffix(".tmp")
    tmp.write_text("\n".join(lines) + "\n", encoding="utf-8")
    os.replace(tmp, target)
    debug_log(
        "wrote control: "
        f"path={target} enabled={clean['enabled']} close_all={clean['close_all']} "
        f"lot={clean['initial_lot']} max_spread={clean['max_spread']}"
    )
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


def validate_control(post_data):
    return {
        "initial_lot": decimal_value(post_data, "initial_lot", minimum=Decimal("0.01")),
        "zone_height": int_value(post_data, "zone_height", minimum=1, maximum=100000),
        "multiplier": decimal_value(post_data, "multiplier", minimum=Decimal("1.0")),
        "target_usd": decimal_value(post_data, "target_usd", minimum=Decimal("0.01")),
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
