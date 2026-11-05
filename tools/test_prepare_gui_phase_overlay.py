import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import prepare_gui_phase_overlay as overlay


class GuiPhaseOverlayTest(unittest.TestCase):
    def test_overlay_preserves_production_sources_and_bounds_the_recorder(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'trace'
            path = overlay.prepare(output)
            manifest = json.loads((output / 'manifest.json').read_text())
            self.assertEqual(len(json.loads(path.read_text())['roots']), 3)
            for name, digest in manifest['inputs'].items():
                self.assertEqual(hashlib.sha256(Path(name).read_bytes()).hexdigest(), digest)
            header = (output / 'gui_phase_trace.hpp').read_text()
            self.assertIn('capacity = 262144', header)
            self.assertIn('TGB_GUI_PHASE_TRACE', header)
            self.assertNotIn('TELAR_RUNTIME_PHASE_TRACE', header)
            self.assertIn('Buffer() { calibrate(); }', header)
            self.assertIn('~Buffer() {\n    calibrate();', header)
            with self.assertRaises(FileExistsError):
                overlay.prepare(output)

    def test_changed_source_anchor_fails_closed(self):
        original = overlay.replace_once

        def incompatible(source, before, after):
            if before == '  WindowImages::forWindow(window);\n':
                source = source.replace(before, '')
            return original(source, before, after)

        with tempfile.TemporaryDirectory() as directory, patch.object(overlay, 'replace_once', incompatible):
            with self.assertRaisesRegex(ValueError, 'instrumentation anchor'):
                overlay.prepare(Path(directory) / 'trace')


if __name__ == '__main__':
    unittest.main()
