from django.contrib import messages
from django.http import JsonResponse
from django.shortcuts import redirect, render

from .services import (
    SettingsError,
    common_files_dir,
    control_file_path,
    debug_log,
    file_debug_info,
    read_control,
    read_status,
    status_file_path,
    validate_control,
    write_control,
)


def dashboard(request):
    control = read_control()

    if request.method == "POST":
        action = request.POST.get("action", "save")
        debug_log(f"button pressed: action={action}")
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
    context = {
        "control": control,
        "status": status,
        "common_files_dir": common_files_dir(),
        "control_file": control_file_path(),
        "status_file": status_file_path(),
        "control_file_info": file_debug_info(control_file_path()),
        "status_file_info": file_debug_info(status_file_path()),
    }
    return render(request, "control/dashboard.html", context)


def status_api(request):
    control = read_control()
    status = read_status()
    debug_log(
        "status poll: "
        f"enabled={control.get('enabled')} close_all={control.get('close_all')} "
        f"ea_message={status.get('ea_message', 'NO_STATUS_FILE')}"
    )
    return JsonResponse(
        {
            "control": control,
            "status": status,
            "paths": {
                "common_files_dir": str(common_files_dir()),
                "control_file": str(control_file_path()),
                "status_file": str(status_file_path()),
            },
            "files": {
                "control": file_debug_info(control_file_path()),
                "status": file_debug_info(status_file_path()),
            },
        }
    )
