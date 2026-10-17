"""Checkout discovery must be independent of cwd and avoid accidental branch fallback."""
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import run_virtual_tests as runner


class FirmwareLocationTest(unittest.TestCase):
    def test_normal_sibling(self):
        with patch.object(runner, 'ROOT', Path('/repos/scrbrd-mobile')), patch.dict(os.environ, {}, clear=True):
            self.assertEqual(runner.resolve_firmware(), Path('/repos/scrbrd'))

    def test_paired_worktree(self):
        with patch.object(runner, 'ROOT', Path('/repos/scrbrd-virtual-mobile')), patch.dict(os.environ, {}, clear=True):
            self.assertEqual(runner.resolve_firmware(), Path('/repos/scrbrd-virtual-firmware'))

    def test_environment_override(self):
        with patch.dict(os.environ, {'SCRBRD_FIRMWARE': '/repos/custom-firmware'}):
            self.assertEqual(runner.resolve_firmware(), Path('/repos/custom-firmware'))

    def test_explicit_override_wins(self):
        with patch.dict(os.environ, {'SCRBRD_FIRMWARE': '/repos/other'}):
            self.assertEqual(runner.resolve_firmware(Path('/repos/chosen')), Path('/repos/chosen'))

    def test_sibling_is_independent_of_cwd(self):
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory:
            try:
                os.chdir(directory)
                with patch.object(runner, 'ROOT', Path('/repos/scrbrd-mobile')), patch.dict(os.environ, {}, clear=True):
                    self.assertEqual(runner.resolve_firmware(), Path('/repos/scrbrd'))
            finally:
                os.chdir(previous)


if __name__ == '__main__':
    unittest.main()
