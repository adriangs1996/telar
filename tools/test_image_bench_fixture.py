import base64
import copy
import io
import json
import mmap
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import _posixshmem

import image_bench_fixture as benchmark
from gui_tui_latency import finish_image_fixture, validate_image_receipt


class ImageFixtureTest(unittest.TestCase):
    def test_publications_own_exact_pixels_and_cleanup_unadopted_memory(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
            fixture = benchmark.ImageFixture(Path(directory), (7, 3))
            fixture.size = os.terminal_size((101, 46))
            fixture.phase = 'ready'
            output = io.BytesIO()
            try:
                with patch.object(benchmark.sys, 'stdout', SimpleNamespace(buffer=output)):
                    fixture.draw_marker()
                    fixture.handle_marker_input(b'x')
                    fixture.handle_marker_input(b'x')
                fixture.record()
                receipt = json.loads(fixture.receipt.read_text())
                result = dict(fixtures=[receipt], gpu_ms=[1, 1], endpoint='gpu')
                validate_image_receipt(result, (7, 3))
                self.assertNotIn(b'48;2;', output.getvalue())
                self.assertEqual(output.getvalue().count(b'f=32,s=7,v=3,t=s'), 3)
                for index, name in enumerate(fixture.shared_names):
                    self.assertIn(base64.standard_b64encode(name.encode()), output.getvalue())
                    descriptor = _posixshmem.shm_open(name, os.O_RDONLY, 0o600)
                    try:
                        self.assertGreaterEqual(os.fstat(descriptor).st_size, 7 * 3 * 4)
                        with mmap.mmap(descriptor, 7 * 3 * 4, access=mmap.ACCESS_READ) as pixels:
                            self.assertEqual(pixels[:], bytes(benchmark.COLORS[index % 2]) * (7 * 3))
                    finally:
                        os.close(descriptor)
                for field, value in [('width', 8), ('bytes_per_image', 0), ('format', 'RGB888'),
                                     ('publications', []), ('payload_sha256', ['0' * 64] * 3)]:
                    corrupted = copy.deepcopy(result)
                    corrupted['fixtures'][0]['image'][field] = value
                    with self.subTest(field=field), self.assertRaises(ValueError):
                        validate_image_receipt(corrupted, (7, 3))
                corrupted = copy.deepcopy(result)
                corrupted['fixtures'][0]['image']['publications'][1]['color'] = 0
                with self.assertRaises(ValueError):
                    validate_image_receipt(corrupted, (7, 3))
            finally:
                names = list(fixture.shared_names)
                fixture.close()
            cleanup = json.loads((Path(directory) / 'image-cleanup.json').read_text())
            self.assertEqual(cleanup['unadopted_names'], names)
            for name in names:
                with self.assertRaises(FileNotFoundError):
                    _posixshmem.shm_open(name, os.O_RDONLY, 0o600)

    def test_requested_dimensions_are_bounded_before_pixel_allocation(self):
        for size in [(0, 1), (1, -1), (8192, 8192)]:
            with self.subTest(size=size), self.assertRaises(ValueError):
                benchmark.image_extent(*size)
        self.assertEqual(benchmark.image_extent(3840, 2160), (3840, 2160))

    def test_cleanup_refuses_a_different_owned_child(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'receipts').mkdir()
            (root / 'receipts' / '123.json').write_text(json.dumps(dict(pid=123)))
            with patch('gui_tui_latency.descendants', return_value={123: (99, 'started', '/bin/sh')}), \
                    patch('gui_tui_latency.os.kill') as kill:
                with self.assertRaisesRegex(ValueError, 'expected owned process'):
                    finish_image_fixture(root, 99)
                kill.assert_not_called()


if __name__ == '__main__':
    unittest.main()
