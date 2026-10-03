import importlib.util
import os
import subprocess
import tempfile
from pathlib import Path

from unittest import mock

from django.conf import settings
from django.contrib.staticfiles import finders
from django.test import SimpleTestCase, TestCase

from .services import (
    SettingsError,
    apply_control_preset,
    common_files_dir,
    csv_data_row_count,
    read_control,
    read_version,
    runtime_state,
    validate_control,
    write_control,
)
from . import views
from .views import training_failure_reason

VALID_FORM = {
    "initial_lot": "0.02",
    "zone_height": "600",
    "multiplier": "1.8",
    "target_usd": "1.25",
    "quick_target_usd": "0.50",
    "max_loss_usd": "10",
    "allow_recovery": "0",
    "take_profit_points": "300",
    "stop_loss_points": "900",
    "max_lot": "0.05",
    "max_same_side": "1",
    "min_same_side_distance": "300",
    "max_turns": "1",
    "max_spread": "350",
}

class CommonFilesDirMixin:

    def use_temp_common_dir(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        previous = os.environ.get("MT5_COMMON_FILES_DIR")
        os.environ["MT5_COMMON_FILES_DIR"] = temp.name

        def restore():
            if previous is None:
                os.environ.pop("MT5_COMMON_FILES_DIR", None)
            else:
                os.environ["MT5_COMMON_FILES_DIR"] = previous

        self.addCleanup(restore)
        return Path(temp.name)

class ServiceTests(SimpleTestCase):
    def test_validate_control_accepts_valid_values(self):
        cleaned = validate_control(
            {
                "initial_lot": "0.02",
                "zone_height": "600",
                "multiplier": "1.8",
                "target_usd": "1.25",
                "quick_target_usd": "0.50",
                "max_loss_usd": "10",
                "allow_recovery": "0",
                "take_profit_points": "300",
                "stop_loss_points": "900",
                "max_lot": "0.05",
                "max_same_side": "1",
                "min_same_side_distance": "300",
                "max_turns": "1",
                "max_spread": "350",
            }
        )

        self.assertEqual(cleaned["initial_lot"], "0.02")
        self.assertEqual(cleaned["quick_target_usd"], "0.5")
        self.assertEqual(cleaned["allow_recovery"], "0")
        self.assertEqual(cleaned["take_profit_points"], "300")
        self.assertEqual(cleaned["max_lot"], "0.05")
        self.assertEqual(cleaned["max_same_side"], "1")
        self.assertEqual(cleaned["max_turns"], "1")

    def test_common_files_dir_uses_override(self):
        temp_dir = str(Path.cwd() / ".tmp" / "common-files-override")
        previous = os.environ.get("MT5_COMMON_FILES_DIR")
        os.environ["MT5_COMMON_FILES_DIR"] = temp_dir
        try:
            self.assertEqual(str(common_files_dir()), temp_dir)
        finally:
            if previous is None:
                os.environ.pop("MT5_COMMON_FILES_DIR", None)
            else:
                os.environ["MT5_COMMON_FILES_DIR"] = previous

    def test_read_version_has_default_build_label(self):
        temp_dir = str(Path.cwd() / ".tmp" / "version-default")
        previous = os.environ.get("MT5_COMMON_FILES_DIR")
        os.environ["MT5_COMMON_FILES_DIR"] = temp_dir
        try:
            self.assertEqual(read_version()["app_version"], "v1.0.7")
            self.assertEqual(read_version()["ea_version"], "v1.0.7_13")
        finally:
            if previous is None:
                os.environ.pop("MT5_COMMON_FILES_DIR", None)
            else:
                os.environ["MT5_COMMON_FILES_DIR"] = previous

    def test_runtime_state_requires_matching_live_ea_version(self):
        state = runtime_state(
            {"enabled": "1"},
            {"ea_message": "Waiting: spread is above the max allowed."},
            {"ea_version": "v1.0.7_8"},
        )

        self.assertEqual(state["badge_state"], "warning")
        self.assertEqual(state["badge_label"], "Old EA / Unknown")
        self.assertFalse(state["ea_confirmed"])

        confirmed = runtime_state(
            {"enabled": "1"},
            {"ea_version": "v1.0.7_8"},
            {"ea_version": "v1.0.7_8"},
        )

        self.assertEqual(confirmed["badge_state"], "confirmed")
        self.assertTrue(confirmed["ea_confirmed"])

    def test_quick_now_preset_opens_spread_gate_for_current_test_spread(self):
        control = apply_control_preset({"max_spread": "100"}, "quick_now")

        self.assertEqual(control["enabled"], "1")
        self.assertEqual(control["quick_target_usd"], "0.75")
        self.assertEqual(control["max_loss_usd"], "1.10")
        self.assertEqual(control["allow_recovery"], "0")
        self.assertEqual(control["take_profit_points"], "150")
        self.assertEqual(control["stop_loss_points"], "250")
        self.assertEqual(control["max_spread"], "400")

class ValidationHardeningTests(SimpleTestCase):
    def assert_rejected(self, field, value):
        form = dict(VALID_FORM)
        form[field] = value
        with self.assertRaises(SettingsError):
            validate_control(form)

    def test_nan_is_rejected_instead_of_crashing(self):
        self.assert_rejected("target_usd", "NaN")
        self.assert_rejected("max_loss_usd", "nan")

    def test_infinity_is_rejected(self):
        self.assert_rejected("quick_target_usd", "Infinity")
        self.assert_rejected("max_lot", "-Infinity")

    def test_absurd_magnitudes_are_rejected(self):
        self.assert_rejected("target_usd", "1e999999")
        self.assert_rejected("initial_lot", "5000")
        self.assert_rejected("multiplier", "101")

    def test_non_numbers_are_rejected(self):
        self.assert_rejected("initial_lot", "")
        self.assert_rejected("initial_lot", "abc")

    def test_large_whole_numbers_keep_plain_formatting(self):
        form = dict(VALID_FORM)
        form["max_loss_usd"] = "100"
        self.assertEqual(validate_control(form)["max_loss_usd"], "100")

class ControlFileTests(CommonFilesDirMixin, SimpleTestCase):
    def test_write_control_drops_stale_ea_acknowledgement(self):
        directory = self.use_temp_common_dir()
        (directory / "recovery_shield_control.txt").write_text(
            "enabled=0\nclose_all=0\nack=close_all\nack_at=2026.01.01 00:00:00\n",
            encoding="utf-8",
        )

        written = write_control(read_control())
        text = (directory / "recovery_shield_control.txt").read_text(encoding="utf-8")

        self.assertNotIn("ack", written)
        self.assertNotIn("ack=", text)
        self.assertNotIn("ack_at=", text)
        self.assertIn("updated_by=django", text)

    def test_write_control_leaves_no_temp_file_behind(self):
        directory = self.use_temp_common_dir()
        write_control(read_control())
        self.assertEqual(sorted(path.name for path in directory.iterdir()), ["recovery_shield_control.txt"])

    def test_csv_row_count_ignores_header_and_tracks_changes(self):
        directory = self.use_temp_common_dir()
        log = directory / "rows.csv"

        self.assertEqual(csv_data_row_count(log), 0)

        log.write_text("a,b\n1,2\n3,4\n", encoding="utf-8")
        self.assertEqual(csv_data_row_count(log), 2)

        log.write_text("a,b\n1,2\n3,4\n5,6\n", encoding="utf-8")
        self.assertEqual(csv_data_row_count(log), 3)

class TrainerTests(CommonFilesDirMixin, SimpleTestCase):
    @staticmethod
    def load_trainer():
        path = Path(settings.BASE_DIR) / "scripts" / "train_model.py"
        spec = importlib.util.spec_from_file_location("train_model_under_test", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_rows_without_a_readable_result_are_skipped_not_counted_as_wins(self):
        trainer = self.load_trainer()
        directory = self.use_temp_common_dir()
        header = ",".join(trainer.FEATURES + ["exit_profit"])
        features = ",".join(["1"] * len(trainer.FEATURES))
        log = directory / "cycles.csv"
        log.write_text(
            "\n".join(
                [
                    header,
                    features + ",0.50",
                    features + ",-0.40",
                    features + ",",
                    features + ",nan",
                    features + ",inf",
                ]
            )
            + "\n",
            encoding="utf-8",
        )

        rows = trainer.load_rows(log)

        self.assertEqual([row["label"] for row in rows], [1, 0])
        self.assertEqual([row["profit"] for row in rows], [0.5, -0.4])

    def test_non_finite_threshold_override_is_ignored(self):
        trainer = self.load_trainer()
        previous = os.environ.get("MODEL_THRESHOLD")
        os.environ["MODEL_THRESHOLD"] = "nan"
        try:
            self.assertIsNone(trainer.env_float("MODEL_THRESHOLD"))
        finally:
            if previous is None:
                os.environ.pop("MODEL_THRESHOLD", None)
            else:
                os.environ["MODEL_THRESHOLD"] = previous

class DashboardViewTests(CommonFilesDirMixin, TestCase):
    def test_nan_in_form_shows_an_error_instead_of_a_server_error(self):
        directory = self.use_temp_common_dir()
        form = dict(VALID_FORM, action="save", target_usd="NaN")

        response = self.client.post("/", form, follow=True)

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "target usd must be a finite number")
        self.assertFalse((directory / "recovery_shield_control.txt").exists())

    def test_valid_save_writes_the_control_file(self):
        directory = self.use_temp_common_dir()

        response = self.client.post("/", dict(VALID_FORM, action="start"), follow=True)

        self.assertEqual(response.status_code, 200)
        text = (directory / "recovery_shield_control.txt").read_text(encoding="utf-8")
        self.assertIn("enabled=1", text)
        self.assertIn("quick_target_usd=0.5", text)

    def test_dashboard_renders_versions_from_the_backend(self):
        self.use_temp_common_dir()

        response = self.client.get("/")

        self.assertContains(response, "v1.0.7_13")

    def test_status_api_reports_the_compiled_version(self):
        self.use_temp_common_dir()

        payload = self.client.get("/api/status/").json()

        self.assertEqual(payload["version"]["ea_version"], "v1.0.7_13")
        self.assertEqual(payload["runtime_state"]["badge_state"], "paused")

    def test_training_failure_message_uses_last_trainer_line(self):
        result = subprocess.CompletedProcess(
            ["x"], 1, stdout="", stderr="Traceback...\nValueError: boom\n"
        )
        self.assertEqual(training_failure_reason(result), "ValueError: boom")
        empty = subprocess.CompletedProcess(["x"], 1, stdout="", stderr="")
        self.assertEqual(training_failure_reason(empty), "no output from the trainer.")

    def test_dashboard_loads_polling_from_a_static_file(self):
        self.use_temp_common_dir()

        response = self.client.get("/")
        html = response.content.decode("utf-8")

        self.assertIn('id="dashboard-script"', html)
        self.assertIn("control/dashboard.js", html)
        self.assertIn('data-status-url="/api/status/"', html)
        self.assertNotIn("await fetch(", html)
        self.assertNotIn("function refreshStatus", html)
        self.assertIsNotNone(finders.find("control/dashboard.js"))


class StaleStatusTests(SimpleTestCase):
    def state(self, enabled, age):
        return runtime_state(
            {"enabled": enabled},
            {"ea_version": "v1.0.7_13"},
            {"ea_version": "v1.0.7_13"},
            status_age_seconds=age,
        )

    def test_old_status_file_is_reported_offline(self):
        state = self.state("1", 120)
        self.assertEqual(state["badge_label"], "EA Offline")
        self.assertEqual(state["badge_state"], "warning")
        self.assertFalse(state["ea_confirmed"])
        self.assertTrue(state["status_stale"])

    def test_fresh_status_file_is_confirmed(self):
        state = self.state("1", 2)
        self.assertEqual(state["badge_state"], "confirmed")
        self.assertFalse(state["status_stale"])

    def test_paused_is_not_overridden_by_stale_status(self):
        self.assertEqual(self.state("0", 999)["badge_state"], "paused")

    def test_missing_age_never_marks_stale(self):
        self.assertFalse(self.state("1", None)["status_stale"])


class EmergencyCommandTests(CommonFilesDirMixin, TestCase):
    def saved(self, directory):
        path = directory / "recovery_shield_control.txt"
        if not path.exists():
            return None
        return dict(
            line.split("=", 1)
            for line in path.read_text(encoding="utf-8").splitlines()
            if "=" in line
        )

    def test_close_all_is_sent_even_when_a_field_is_invalid(self):
        directory = self.use_temp_common_dir()
        form = dict(VALID_FORM, action="close_all", initial_lot="oops")

        self.client.post("/", form)

        saved = self.saved(directory)
        self.assertIsNotNone(saved)
        self.assertEqual(saved["close_all"], "1")
        self.assertEqual(saved["enabled"], "0")
        self.assertEqual(saved["initial_lot"], "0.01")

    def test_pause_is_sent_even_when_a_field_is_invalid(self):
        directory = self.use_temp_common_dir()
        write_control(dict(read_control(), enabled="1"))

        self.client.post("/", dict(VALID_FORM, action="pause", zone_height="x"))

        self.assertEqual(self.saved(directory)["enabled"], "0")

    def test_start_is_rejected_when_a_field_is_invalid(self):
        directory = self.use_temp_common_dir()

        self.client.post("/", dict(VALID_FORM, action="start", initial_lot="NaN"))

        self.assertIsNone(self.saved(directory))

    def test_training_timeout_becomes_a_page_message(self):
        self.use_temp_common_dir()
        timeout = subprocess.TimeoutExpired(cmd="x", timeout=1)

        with mock.patch.object(views.subprocess, "run", side_effect=timeout):
            response = self.client.post("/", {"action": "train_model"}, follow=True)

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "trainer timed out")

    def test_trainer_runs_from_a_project_relative_path(self):
        self.use_temp_common_dir()
        done = subprocess.CompletedProcess(["x"], 0, stdout="", stderr="")

        with mock.patch.object(views.subprocess, "run", return_value=done) as run:
            self.client.post("/", {"action": "train_model"})

        command = run.call_args.args[0]
        self.assertFalse(os.path.isabs(command[1]))
        self.assertEqual(run.call_args.kwargs["cwd"], str(settings.BASE_DIR))

    def test_status_api_reports_staleness_fields(self):
        self.use_temp_common_dir()

        runtime = self.client.get("/api/status/").json()["runtime_state"]

        self.assertIn("status_stale", runtime)
        self.assertIn("status_age_seconds", runtime)

    def test_recovery_setting_is_a_dropdown(self):
        self.use_temp_common_dir()

        response = self.client.get("/")

        self.assertContains(response, '<select name="allow_recovery">')


class ProjectRelativePathTests(SimpleTestCase):
    def test_default_common_dir_does_not_depend_on_working_directory(self):
        environment = {
            key: value
            for key, value in os.environ.items()
            if key not in {"MT5_COMMON_FILES_DIR", "APPDATA"}
        }
        previous = os.getcwd()
        with mock.patch.dict(os.environ, environment, clear=True):
            try:
                os.chdir(tempfile.gettempdir())
                resolved = common_files_dir()
            finally:
                os.chdir(previous)

        self.assertEqual(resolved, Path(settings.BASE_DIR) / "mt5_common_files")


class TrainerRowFilterTests(CommonFilesDirMixin, SimpleTestCase):
    def test_rows_with_no_captured_features_are_skipped(self):
        trainer = TrainerTests.load_trainer()
        directory = self.use_temp_common_dir()
        header = ",".join(trainer.FEATURES + ["exit_profit"])
        real = ",".join(["1"] * len(trainer.FEATURES)) + ",0.50"
        empty = ",".join(["0"] * len(trainer.FEATURES)) + ",-0.50"
        log = directory / "cycles.csv"
        log.write_text("\n".join([header, real, empty]) + "\n", encoding="utf-8")

        rows = trainer.load_rows(log)

        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["label"], 1)
