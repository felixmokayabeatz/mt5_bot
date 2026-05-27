import os
from pathlib import Path

from django.test import SimpleTestCase

from .services import (
    apply_control_preset,
    common_files_dir,
    read_version,
    runtime_state,
    validate_control,
)


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
            self.assertEqual(read_version()["app_version"], "v1.0.3")
            self.assertEqual(read_version()["ea_version"], "v1.0.3_4")
        finally:
            if previous is None:
                os.environ.pop("MT5_COMMON_FILES_DIR", None)
            else:
                os.environ["MT5_COMMON_FILES_DIR"] = previous

    def test_runtime_state_requires_matching_live_ea_version(self):
        state = runtime_state(
            {"enabled": "1"},
            {"ea_message": "Waiting: spread is above the max allowed."},
            {"ea_version": "v1.0.3_4"},
        )

        self.assertEqual(state["badge_state"], "warning")
        self.assertEqual(state["badge_label"], "Old EA / Unknown")
        self.assertFalse(state["ea_confirmed"])

        confirmed = runtime_state(
            {"enabled": "1"},
            {"ea_version": "v1.0.3_4"},
            {"ea_version": "v1.0.3_4"},
        )

        self.assertEqual(confirmed["badge_state"], "confirmed")
        self.assertTrue(confirmed["ea_confirmed"])

    def test_quick_now_preset_opens_spread_gate_for_current_test_spread(self):
        control = apply_control_preset({"max_spread": "100"}, "quick_now")

        self.assertEqual(control["enabled"], "1")
        self.assertEqual(control["quick_target_usd"], "0.50")
        self.assertEqual(control["max_loss_usd"], "1.20")
        self.assertEqual(control["allow_recovery"], "0")
        self.assertEqual(control["take_profit_points"], "900")
        self.assertEqual(control["stop_loss_points"], "700")
        self.assertEqual(control["max_spread"], "400")
