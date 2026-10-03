import os
import subprocess
import sys
from datetime import datetime, timezone

from django.conf import settings
from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

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
    validate_control,
    write_control,
)

TRAINING_TIMEOUT_SECONDS = 300


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
            write_control(control)
            if action == "quick_now":
                messages.warning(request, "Quick Now preset applied.")
            else:
                messages.success(request, "Safe Quick preset applied.")
            return redirect("dashboard")

        try:
            control.update(validate_control(request.POST))
        except SettingsError as exc:
            debug_log(f"validation failed: {exc}")
            messages.error(request, str(exc))
            return redirect("dashboard")

        if action == "start":
            control["enabled"] = "1"
            control["close_all"] = "0"
            messages.success(request, "EA start command sent.")
        elif action == "pause":
            control["enabled"] = "0"
            control["close_all"] = "0"
            messages.success(request, "EA pause command sent.")
        elif action == "close_all":
            control["enabled"] = "0"
            control["close_all"] = "1"
            messages.warning(request, "Close-all command sent.")
        else:
            messages.success(request, "Settings saved.")

        write_control(control)
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
        "runtime_state": runtime_state(control, status, version),
        **paths,
        **file_info,
        "event_rows": csv_data_row_count(event_log_file_path()),
        "cycle_rows": csv_data_row_count(cycle_log_file_path()),
    }
    return render(request, "control/dashboard.html", context)


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
            "runtime_state": runtime_state(control, status, version),
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
    """Last useful line of trainer output, so the dashboard can show why it failed."""
    for stream in (result.stderr, result.stdout):
        lines = [line.strip() for line in (stream or "").splitlines() if line.strip()]
        if lines:
            return lines[-1][:300]
    return "no output from the trainer."


def run_model_training():
    root = str(settings.BASE_DIR)
    script = os.path.join(root, "scripts", "train_model.py")

    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH", "")
    env["PYTHONPATH"] = root if not existing_pythonpath else root + os.pathsep + existing_pythonpath

    command = [sys.executable, script]
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
