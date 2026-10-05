import os
import subprocess
import sys
from datetime import datetime, timezone

from django.conf import settings
from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .auth import dashboard_access

from .services import (
    SettingsError,
    apply_control_preset,
    csv_data_row_count,
    cycle_log_file_path,
    debug_log,
    event_log_file_path,
    file_info_bundle,
    read_control,
    read_model,
    read_status,
    read_version,
    runtime_paths,
    runtime_state,
    status_file_age_seconds,
    validate_control,
    write_control,
)

TRAINING_TIMEOUT_SECONDS = 900
EMERGENCY_ACTIONS = {"pause", "close_all"}
TRAINER_SCRIPT = os.path.join("scripts", "train_model.py")

def store_control(request, control):
    try:
        write_control(control)
    except OSError as exc:
        debug_log(f"control write failed: {exc}")
        messages.error(request, f"Could not write the control file: {exc}")
        return False

    return True

@dashboard_access
def dashboard(request):
    control = read_control()

    if request.method == "POST":
        action = request.POST.get("action", "save")
        debug_log(f"button pressed: action={action}")

        if action == "train_model":
            result = run_model_training()
            if result.returncode == 0:
                messages.success(request, "Model training finished. Check the AI panel.")
            else:
                messages.error(request, "Model training failed: " + training_failure_reason(result))
            return redirect("dashboard")

        if action in {"quick_safe", "quick_now"}:
            control = apply_control_preset(control, action)
            if not store_control(request, control):
                return redirect("dashboard")

            if action == "quick_now":
                messages.warning(request, "Quick Now preset applied. EA start command sent.")
            else:
                messages.success(request, "Safe Quick preset applied. EA start command sent.")
            return redirect("dashboard")

        try:
            control.update(validate_control(request.POST))
        except SettingsError as exc:
            debug_log(f"validation failed: {exc}")
            if action not in EMERGENCY_ACTIONS:
                messages.error(request, str(exc))
                return redirect("dashboard")

            messages.warning(
                request, f"{exc} Settings were not saved, but the command was sent."
            )

        if action == "start":
            control["enabled"] = "1"
            control["close_all"] = "0"
            notify, text = messages.success, "EA start command sent."
        elif action == "pause":
            control["enabled"] = "0"
            control["close_all"] = "0"
            notify, text = messages.success, "EA pause command sent."
        elif action == "close_all":
            control["enabled"] = "0"
            control["close_all"] = "1"
            notify, text = messages.warning, "Close-all command sent."
        else:
            control["close_all"] = "0"
            notify, text = messages.success, "Settings saved."

        if not store_control(request, control):
            return redirect("dashboard")

        notify(request, text)
        return redirect("dashboard")

    debug_log("dashboard opened")
    status = read_status()
    version = read_version()
    paths = runtime_paths()
    file_info = file_info_bundle(paths)
    context = {
        "control": control,
        "status": status,
        "model": read_model(),
        "version": version,
        "runtime_state": runtime_state(
            control, status, version, status_file_age_seconds()
        ),
        **paths,
        **file_info,
        "event_rows": csv_data_row_count(event_log_file_path()),
        "cycle_rows": csv_data_row_count(cycle_log_file_path()),
    }
    return render(request, "control/dashboard.html", context)

@dashboard_access
def status_api(request):
    control = read_control()
    status = read_status()
    version = read_version()
    paths = runtime_paths()
    file_info = file_info_bundle(paths)
    debug_log(
        "status poll: "
        f"enabled={control.get('enabled')} close_all={control.get('close_all')} "
        f"ea_message={status.get('ea_message', 'NO_STATUS_FILE')}"
    )
    return JsonResponse(
        {
            "control": control,
            "status": status,
            "model": read_model(),
            "version": version,
            "runtime_state": runtime_state(
                control, status, version, status_file_age_seconds()
            ),
            "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
            "paths": {key: str(value) for key, value in paths.items()},
            "files": {
                "control": file_info["control_file_info"],
                "status": file_info["status_file_info"],
                "event_log": file_info["event_log_file_info"],
                "cycle_log": file_info["cycle_log_file_info"],
                "model": file_info["model_file_info"],
                "version": file_info["version_file_info"],
            },
            "counts": {
                "events": csv_data_row_count(event_log_file_path()),
                "cycles": csv_data_row_count(cycle_log_file_path()),
            },
        }
    )

def training_failure_reason(result):
    for stream in (result.stderr, result.stdout):
        lines = [line.strip() for line in (stream or "").splitlines() if line.strip()]
        if lines:
            return lines[-1][:300]
    return "no output from the trainer."

def run_model_training():
    root = str(settings.BASE_DIR)

    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = root if not existing_pythonpath else root + os.pathsep + existing_pythonpath

    command = [sys.executable, TRAINER_SCRIPT]
    debug_log("training command: " + " ".join(command))

    try:
        result = subprocess.run(
            command,
            cwd=root,
            env=env,
            text=True,
            capture_output=True,
            timeout=TRAINING_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        debug_log(f"training timed out after {TRAINING_TIMEOUT_SECONDS}s")
        return subprocess.CompletedProcess(
            command,
            1,
            stdout="",
            stderr=f"trainer timed out after {TRAINING_TIMEOUT_SECONDS} seconds.",
        )
    except OSError as exc:
        debug_log(f"training could not start: {exc}")
        return subprocess.CompletedProcess(
            command, 1, stdout="", stderr=f"trainer could not start: {exc}"
        )

    if result.stdout:
        for line in result.stdout.splitlines():
            debug_log("[trainer stdout] " + line)

    if result.stderr:
        for line in result.stderr.splitlines():
            debug_log("[trainer stderr] " + line)

    debug_log(f"training exited with code {result.returncode}")
    return result
