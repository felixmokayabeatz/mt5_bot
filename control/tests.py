import os
from tempfile import TemporaryDirectory

from django.test import SimpleTestCase

from .services import common_files_dir, validate_control


class ServiceTests(SimpleTestCase):
    def test_validate_control_accepts_valid_values(self):
        cleaned = validate_control(
            {
                "initial_lot": "0.02",
                "zone_height": "600",
                "multiplier": "1.8",
                "target_usd": "1.25",
                "max_turns": "4",
                "max_spread": "350",
            }
        )

        self.assertEqual(cleaned["initial_lot"], "0.02")
        self.assertEqual(cleaned["max_turns"], "4")

    def test_common_files_dir_uses_override(self):
        with TemporaryDirectory() as temp_dir:
            previous = os.environ.get("MT5_COMMON_FILES_DIR")
            os.environ["MT5_COMMON_FILES_DIR"] = temp_dir
            try:
                self.assertEqual(str(common_files_dir()), temp_dir)
            finally:
                if previous is None:
                    os.environ.pop("MT5_COMMON_FILES_DIR", None)
                else:
                    os.environ["MT5_COMMON_FILES_DIR"] = previous
