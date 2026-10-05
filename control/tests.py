import importlib.util
import os
import re
import subprocess
import tempfile
from pathlib import Path

from unittest import mock

from django.conf import settings
from django.contrib.staticfiles import finders
from decimal import Decimal

from django.contrib.auth import get_user_model
from django.core.cache import cache
from django.core.management import call_command
from django.test import SimpleTestCase, TestCase, override_settings

from .services import (
    APP_VERSION,
    DEFAULT_CONTROL,
    EA_BUILD_NUMBER,
    EA_VERSION,
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

class CrossFieldValidationTests(SimpleTestCase):

    def test_max_lot_below_initial_lot_is_rejected(self):
        form = dict(VALID_FORM, initial_lot="0.10", max_lot="0.05")
        with self.assertRaises(SettingsError):
            validate_control(form)

    def test_max_lot_equal_to_initial_lot_is_accepted(self):
        form = dict(VALID_FORM, initial_lot="0.05", max_lot="0.05")
        self.assertEqual(validate_control(form)["max_lot"], "0.05")

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
            self.assertEqual(read_version()["ea_version"], "v1.0.7_17")
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

    def test_zero_max_lot_is_rejected(self):
        self.assert_rejected("max_lot", "0")

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

    def test_training_rows_are_capped_to_the_most_recent(self):
        trainer = self.load_trainer()
        rows = list(range(trainer.MAX_TRAINING_ROWS + 250))

        limited = trainer.limit_rows(rows)

        self.assertEqual(len(limited), trainer.MAX_TRAINING_ROWS)
        self.assertEqual(limited[-1], rows[-1])
        self.assertEqual(limited[0], rows[250])

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

        self.assertContains(response, "v1.0.7_17")

    def test_status_api_reports_the_compiled_version(self):
        self.use_temp_common_dir()

        payload = self.client.get("/api/status/").json()

        self.assertEqual(payload["version"]["ea_version"], "v1.0.7_17")
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
            {"ea_version": "v1.0.7_17"},
            {"ea_version": "v1.0.7_17"},
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


class DashboardTileTests(CommonFilesDirMixin, TestCase):
    def write_status(self, directory, text):
        (directory / "recovery_shield_status.txt").write_text(text, encoding="utf-8")

    def test_atr_tile_prefers_the_entry_timeframe_value(self):
        directory = self.use_temp_common_dir()
        self.write_status(directory, "atr_points=999.0\nentry_atr_points=123.0\n")

        response = self.client.get("/")

        self.assertContains(response, '<dd id="atr-points">123.0</dd>')

    def test_atr_tile_falls_back_to_the_chart_value(self):
        directory = self.use_temp_common_dir()
        self.write_status(directory, "atr_points=77.0\n")

        response = self.client.get("/")

        self.assertContains(response, '<dd id="atr-points">77.0</dd>')

    def test_requested_target_and_target_points_are_shown(self):
        directory = self.use_temp_common_dir()
        self.write_status(
            directory,
            "quick_target_usd=0.72\nrequested_quick_target_usd=0.25\neffective_target_points=310\n",
        )

        response = self.client.get("/")

        self.assertContains(response, '<dd id="quick-target">0.72</dd>')
        self.assertContains(response, '<dd id="requested-quick-target">0.25</dd>')
        self.assertContains(response, '<dd id="target-points">310</dd>')

    def test_tiles_show_a_dash_before_the_ea_reports(self):
        self.use_temp_common_dir()

        response = self.client.get("/")

        self.assertContains(response, '<dd id="requested-quick-target">-</dd>')
        self.assertContains(response, '<dd id="target-points">-</dd>')


class ControlWriteFailureTests(CommonFilesDirMixin, TestCase):
    def test_unwritable_control_file_becomes_a_page_message(self):
        self.use_temp_common_dir()

        with mock.patch.object(views, "write_control", side_effect=PermissionError("denied")):
            response = self.client.post("/", dict(VALID_FORM, action="start"), follow=True)

        self.assertEqual(response.status_code, 200)
        self.assertContains(response, "Could not write the control file")
        self.assertNotContains(response, "EA start command sent.")

    def test_failed_preset_write_does_not_claim_success(self):
        self.use_temp_common_dir()

        with mock.patch.object(views, "write_control", side_effect=OSError("disk full")):
            response = self.client.post("/", {"action": "quick_now"}, follow=True)

        self.assertContains(response, "Could not write the control file")
        self.assertNotContains(response, "preset applied")


class TrainerWeightTests(SimpleTestCase):
    def test_class_weights_use_the_real_loss_count_when_there_are_no_wins(self):
        trainer = TrainerTests.load_trainer()
        rows = [{"features": [1.0], "label": 0, "profit": -0.2} for _ in range(4)]

        weights = trainer.build_sample_weights(rows)

        self.assertEqual(len(weights), 4)
        for weight in weights:
            self.assertAlmostEqual(weight, 1.0)


class SourceHygieneTests(SimpleTestCase):
    @staticmethod
    def ea_source():
        return (Path(settings.BASE_DIR) / "volatilty.mq5").read_text(encoding="utf-8")

    def test_ea_source_has_no_comments(self):
        source = self.ea_source()

        self.assertNotIn("//", source)
        self.assertNotIn("/*", source)

    def test_ea_and_dashboard_versions_match(self):
        source = self.ea_source()
        build = re.search(r"#define\s+EA_BUILD_NUMBER\s+(\d+)", source).group(1)
        app = re.search(r'#define\s+EA_APP_VERSION\s+"([^"]+)"', source).group(1)
        full = re.search(r'#define\s+EA_BUILD_VERSION\s+"([^"]+)"', source).group(1)

        self.assertEqual(build, EA_BUILD_NUMBER)
        self.assertEqual(app, APP_VERSION)
        self.assertEqual(full, EA_VERSION)


class LoginProtectionTests(CommonFilesDirMixin, TestCase):
    def setUp(self):
        cache.clear()
        self.use_temp_common_dir()
        self.user = get_user_model().objects.create_user("owner", password="correct-horse-battery")

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True)
    def test_page_redirects_anonymous_visitors_to_sign_in(self):
        response = self.client.get("/")

        self.assertEqual(response.status_code, 302)
        self.assertTrue(response["Location"].startswith("/login/"))

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True)
    def test_status_api_answers_401_instead_of_redirecting(self):
        self.assertEqual(self.client.get("/api/status/").status_code, 401)

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True)
    def test_post_actions_are_blocked_without_sign_in(self):
        directory = self.use_temp_common_dir()
        response = self.client.post("/", {"action": "close_all"})

        self.assertEqual(response.status_code, 302)
        self.assertFalse((directory / "recovery_shield_control.txt").exists())

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True)
    def test_signed_in_user_reaches_the_dashboard(self):
        self.client.login(username="owner", password="correct-horse-battery")

        self.assertEqual(self.client.get("/").status_code, 200)
        self.assertEqual(self.client.get("/api/status/").status_code, 200)

    @override_settings(DASHBOARD_REQUIRE_LOGIN=False)
    def test_dashboard_stays_open_when_login_is_not_required(self):
        self.assertEqual(self.client.get("/").status_code, 200)

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True, LOGIN_MAX_FAILURES=3)
    def test_repeated_failures_lock_sign_in(self):
        for _ in range(3):
            response = self.client.post("/login/", {"username": "owner", "password": "wrong"})
            self.assertEqual(response.status_code, 200)

        locked = self.client.post("/login/", {"username": "owner", "password": "correct-horse-battery"})

        self.assertEqual(locked.status_code, 429)

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True, LOGIN_MAX_FAILURES=3)
    def test_successful_sign_in_resets_the_failure_counter(self):
        self.client.post("/login/", {"username": "owner", "password": "wrong"})
        ok = self.client.post("/login/", {"username": "owner", "password": "correct-horse-battery"})

        self.assertEqual(ok.status_code, 302)
        self.assertEqual(cache.get("dashboard-login-failures:127.0.0.1", 0), 0)


class EnsureDashboardUserTests(TestCase):
    @override_settings(DASHBOARD_REQUIRE_LOGIN=False)
    def test_nothing_is_created_when_login_is_not_required(self):
        call_command("ensure_dashboard_user")

        self.assertFalse(get_user_model().objects.exists())

    @override_settings(DASHBOARD_REQUIRE_LOGIN=True)
    def test_account_is_created_from_environment(self):
        with mock.patch.dict(os.environ, {"DASHBOARD_USER": "boss", "DASHBOARD_PASSWORD": "s3cret-pass-123"}):
            call_command("ensure_dashboard_user")

        self.assertTrue(get_user_model().objects.get(username="boss").is_superuser)


class StaticServingTests(SimpleTestCase):
    def test_static_files_are_served_without_debug(self):
        self.assertFalse(settings.DEBUG)
        response = self.client.get("/static/control/dashboard.js")

        self.assertEqual(response.status_code, 200)


class CloseAllProtocolTests(CommonFilesDirMixin, SimpleTestCase):
    def test_close_all_is_pending_until_the_ea_echoes_the_stamp(self):
        control = {"enabled": "0", "close_all": "1", "updated_at": "2026-10-05T10:00:00+00:00"}

        pending = runtime_state(control, {}, {"ea_version": EA_VERSION}, 0)
        handled = runtime_state(control, {"close_all_ack": control["updated_at"]}, {"ea_version": EA_VERSION}, 0)

        self.assertTrue(pending["close_all_pending"])
        self.assertFalse(handled["close_all_pending"])

    def test_close_all_is_not_pending_when_not_requested(self):
        control = {"enabled": "0", "close_all": "0", "updated_at": "x"}

        self.assertFalse(runtime_state(control, {}, {"ea_version": EA_VERSION}, 0)["close_all_pending"])


class TrainerGateTests(CommonFilesDirMixin, SimpleTestCase):
    @staticmethod
    def write_cycles(path, header, reverse_validation):
        lines = [",".join(header)]
        for index in range(100):
            good = index % 2 == 0
            spread = 10 if good else 50
            reversed_row = reverse_validation and index >= 75
            wins = good != reversed_row
            profit = "1.00" if wins else "-1.00"
            values = ["1"] * len(header)
            values[0] = str(spread)
            values[-1] = profit
            lines.append(",".join(values))
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")

    def trainer_with_rows(self, reverse_validation):
        directory = self.use_temp_common_dir()
        trainer = TrainerTests.load_trainer()
        header = trainer.FEATURES + ["exit_profit"]
        self.write_cycles(trainer.cycle_log_path(), header, reverse_validation)
        return trainer, directory

    def test_filter_that_beats_the_baseline_is_enabled(self):
        trainer, _ = self.trainer_with_rows(False)
        _, metadata = trainer.choose_threshold(trainer.load_rows(trainer.cycle_log_path()))

        self.assertEqual(metadata["threshold_source"], "validation")

    def test_filter_that_fails_validation_is_recording_only(self):
        trainer, _ = self.trainer_with_rows(True)

        self.assertEqual(trainer.main(), 0)
        text = trainer.model_path().read_text(encoding="utf-8")

        self.assertIn("enabled=0", text)
        self.assertIn("validation_rejected", text)

    def test_filter_that_beats_the_baseline_is_written_enabled(self):
        trainer, _ = self.trainer_with_rows(False)

        self.assertEqual(trainer.main(), 0)

        self.assertIn("enabled=1", trainer.model_path().read_text(encoding="utf-8"))


class EaDefaultsMatchDashboardTests(SimpleTestCase):
    MAPPING = {
        "InitialLot": "initial_lot",
        "ZoneHeight": "zone_height",
        "Multiplier": "multiplier",
        "TargetUSD": "target_usd",
        "MaxTurns": "max_turns",
        "InpMaxSpread": "max_spread",
        "InpQuickBasketProfitUSD": "quick_target_usd",
        "InpMaxFloatingLossUSD": "max_loss_usd",
        "InpTakeProfitPoints": "take_profit_points",
        "InpStopLossPoints": "stop_loss_points",
        "InpMaxRecoveryLot": "max_lot",
        "InpMaxSameSidePositions": "max_same_side",
        "InpMinSameSideDistancePoints": "min_same_side_distance",
    }

    def test_ea_input_defaults_equal_dashboard_defaults(self):
        source = (Path(settings.BASE_DIR) / "volatilty.mq5").read_text(encoding="utf-8")
        inputs = dict(re.findall(r"^input\s+\w+\s+(\w+)\s*=\s*([^;]+);", source, re.MULTILINE))

        for ea_name, control_key in self.MAPPING.items():
            self.assertEqual(
                Decimal(inputs[ea_name].strip()),
                Decimal(DEFAULT_CONTROL[control_key]),
                ea_name,
            )

        self.assertEqual(inputs["InpAllowRecovery"].strip(), "false")
        self.assertEqual(DEFAULT_CONTROL["allow_recovery"], "0")
