import os
import subprocess
import sys
from datetime import datetime, timezone

from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .services import (
    SettingsError,
    common_files_dir,
    control_file_path,
    csv_data_row_count,
    debug_log,
    cycle_log_file_path,
    event_log_file_path,
    file_debug_info,
    file_info_bundle,
    model_file_path,
    read_control,
    read_model,
    read_status,
    read_version,
    runtime_paths,
    runtime_state,
    status_file_path,
    validate_control,
    write_control,
)


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
                messages.error(request, "Model training failed. Check the terminal output.")
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


def run_model_training():
    env = os.environ.copy()
    existing_pythonpath = env.get("PYTHONPATH", "")
    root = os.getcwd()
    env["PYTHONPATH"] = root if not existing_pythonpath else root + os.pathsep + existing_pythonpath

    command = [sys.executable, "scripts/train_model.py"]
    debug_log("training command: " + " ".join(command))
    result = subprocess.run(
        command,
        cwd=root,
        env=env,
        text=True,
        capture_output=True,
        timeout=120,
    )

    if result.stdout:
        for line in result.stdout.splitlines():
            debug_log("[trainer stdout] " + line)

    if result.stderr:
        for line in result.stderr.splitlines():
            debug_log("[trainer stderr] " + line)

    debug_log(f"training exited with code {result.returncode}")
    return result
