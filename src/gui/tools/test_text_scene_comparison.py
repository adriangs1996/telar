import argparse
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import compare_text_scene as comparison


class SceneComparisonTest(unittest.TestCase):
    def setUp(self):
        self.options = argparse.Namespace(iterations=10, warmup=2, timeout_seconds=1)
        self.rows = [
            dict(operation=operation, glyphs=glyphs, iterations=10, warmup=2, elapsed_ns=100, scene_sha256='a' * 64)
            for operation in comparison.OPERATIONS
            for glyphs in comparison.GLYPH_COUNTS
        ]

    def output(self):
        return '\n'.join(json.dumps(row) for row in self.rows)

    def test_requires_complete_unique_corpus(self):
        self.assertEqual(len(comparison.index_run(self.output(), self.options)), 9)
        self.rows[-1] = dict(self.rows[0])
        with self.assertRaisesRegex(ValueError, 'all nine unique'):
            comparison.index_run(self.output(), self.options)

    def test_rejects_missing_or_invalid_geometry_proof(self):
        for digest in (None, '', 'a' * 63, 'z' * 64):
            with self.subTest(digest=digest):
                self.rows[0]['scene_sha256'] = digest
                with self.assertRaisesRegex(ValueError, 'geometry digest'):
                    comparison.index_run(self.output(), self.options)

    def test_rejects_unusable_timing_and_changed_workload(self):
        for field, value in (('elapsed_ns', 0), ('elapsed_ns', float('nan')), ('elapsed_ns', float('inf')), ('iterations', 11), ('warmup', 3)):
            with self.subTest(field=field, value=value):
                original = self.rows[0][field]
                self.rows[0][field] = value
                with self.assertRaisesRegex(ValueError, 'counts or timing'):
                    comparison.index_run(self.output(), self.options)
                self.rows[0][field] = original

    def test_timeout_preserves_partial_evidence_and_fails(self):
        failure = subprocess.TimeoutExpired('probe', 1, output=b'partial output\n', stderr=b'render stalled\n')
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            with patch.object(comparison.subprocess, 'run', side_effect=failure) as run:
                with self.assertRaises(subprocess.TimeoutExpired):
                    comparison.read_run(Path('/probe'), self.options, directory, 'baseline')

            self.assertEqual(run.call_args.kwargs['timeout'], self.options.timeout_seconds)
            self.assertEqual((directory / 'baseline.jsonl').read_text(), 'partial output\n')
            self.assertEqual((directory / 'baseline.stderr').read_text(), 'render stalled\n')


if __name__ == '__main__':
    unittest.main()
