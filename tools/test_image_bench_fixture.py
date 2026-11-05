import base64
import copy
import io
import json
import mmap
import os
import re
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import _posixshmem

import image_bench_fixture as benchmark
from gui_tui_latency import finish_image_fixture, validate_image_receipt


class ImageFixtureTest(unittest.TestCase):
    def test_inline_publications_reconstruct_exact_pixels_across_chunk_boundaries(self):
        for width in (1, 768, 769):
            with self.subTest(width=width), tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
                fixture = benchmark.ImageFixture(Path(directory), (width, 1), transport='inline')
                fixture.size = os.terminal_size((82, 21))
                fixture.phase = 'ready'
                output = io.BytesIO()
                try:
                    with patch.object(benchmark.sys, 'stdout', SimpleNamespace(buffer=output)):
                        fixture.draw_marker()
                        fixture.handle_marker_input(b'x')
                    fixture.record()
                    result = dict(fixtures=[json.loads(fixture.receipt.read_text())], gpu_ms=[1],
                                  endpoint='gpu', image_transport='inline')
                    validate_image_receipt(result, (width, 1))
                    publications = []
                    pending = bytearray()
                    for header, payload in re.findall(rb'\x1b_G([^;]*);([^\x1b]*)\x1b\\', output.getvalue()):
                        fields = dict(field.split(b'=', 1) for field in header.split(b','))
                        if not pending:
                            self.assertEqual(fields[b'a'], b'T')
                            self.assertEqual(fields[b't'], b'd')
                            self.assertEqual(fields[b's'], str(width).encode())
                            self.assertEqual(fields[b'v'], b'1')
                        self.assertLessEqual(len(payload), benchmark.INLINE_CHUNK_BYTES)
                        pending.extend(base64.b64decode(payload, validate=True))
                        if fields[b'm'] == b'0':
                            publications.append(bytes(pending))
                            pending.clear()
                        else:
                            self.assertEqual(fields[b'm'], b'1')
                    self.assertEqual(pending, b'')
                    self.assertEqual(publications, list(fixture.frames[:2]))
                    self.assertEqual(fixture.shared_names, [])
                    result['image_transport'] = 'shared-memory'
                    with self.assertRaises(ValueError):
                        validate_image_receipt(result, (width, 1))
                finally:
                    fixture.close()
                cleanup = json.loads((Path(directory) / 'image-cleanup.json').read_text())
                self.assertEqual(cleanup['names'], 0)
                self.assertEqual(cleanup['unadopted_names'], [])

    def test_alpha_patterns_publish_magnified_pixels_with_independent_markers(self):
        for pattern in ('alpha-edge', 'alpha-gradient'):
            with self.subTest(pattern=pattern), tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {}, clear=True):
                fixture = benchmark.ImageFixture(Path(directory), (16, 16), pattern)
                fixture.size = os.terminal_size((82, 21))
                fixture.phase = 'ready'
                output = io.BytesIO()
                try:
                    with patch.object(benchmark.sys, 'stdout', SimpleNamespace(buffer=output)):
                        fixture.draw_marker()
                        fixture.handle_marker_input(b'x')
                    fixture.record()
                    receipt = json.loads(fixture.receipt.read_text())
                    result = dict(fixtures=[receipt], gpu_ms=[1], endpoint='gpu', image_pattern=pattern)
                    validate_image_receipt(result, (16, 16))
                    self.assertIn(b',c=8,r=4;', output.getvalue())
                    for frame, marker in zip(fixture.frames, benchmark.COLORS):
                        self.assertEqual(frame[:4], bytes(benchmark.image_patterns.BORDER_COLOR))
                        offset = (8 * 16 + 8) * 4
                        self.assertEqual(frame[offset:offset + 4], bytes(marker))
                    for field, value in [('pattern', 'opaque'), ('placement_cells', [4, 8])]:
                        corrupted = copy.deepcopy(result)
                        corrupted['fixtures'][0]['image'][field] = value
                        with self.assertRaises(ValueError):
                            validate_image_receipt(corrupted, (16, 16))
                finally:
                    fixture.close()

    def test_alpha_patterns_require_the_qualified_extent(self):
        with self.assertRaises(ValueError):
            benchmark.image_patterns.frames((1024, 1024), 'alpha-edge')
        with self.assertRaises(ValueError):
            benchmark.image_patterns.frames((16, 16), 'unknown')

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
