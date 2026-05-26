import os
from pathlib import Path

from django.test import SimpleTestCase

from .services import common_files_dir, read_version, validate_control


class ServiceTests(SimpleTestCase):
    def test_validate_control_accepts_valid_values(self):
        cleaned = validate_control(
            {
                "initial_lot": "0.02",
                "zone_height": "600",
                "multiplier": "1.8",
                "target_usd": "1.25",
                "quick_target_usd": "0.50",
                "max_loss_usd": "0",
                "max_lot": "0.05",
                "max_same_side": "2",
                "min_same_side_distance": "300",
                "max_turns": "4",
                "max_spread": "350",
            }
        )

        self.assertEqual(cleaned["initial_lot"], "0.02")
        self.assertEqual(cleaned["quick_target_usd"], "0.5")
        self.assertEqual(cleaned["max_lot"], "0.05")
        self.assertEqual(cleaned["max_same_side"], "2")
        self.assertEqual(cleaned["max_turns"], "4")

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
            self.assertEqual(read_version()["app_version"], "v1.0.1")
            self.assertEqual(read_version()["ea_version"], "v1.0.1_2")
        finally:
            if previous is None:
                os.environ.pop("MT5_COMMON_FILES_DIR", None)
            else:
                os.environ["MT5_COMMON_FILES_DIR"] = previous
