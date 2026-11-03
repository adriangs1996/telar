import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from PIL import Image, ImageDraw

from image_capture_oracle import BORDER_RGBA, compare


class ImageCaptureOracleTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.image = Image.new('RGBA', (80, 80), (16, 16, 16, 255))
        ImageDraw.Draw(self.image).rectangle((12, 12, 67, 67), outline=BORDER_RGBA)
        self.result = dict(
            endpoint='presented', failed=0, error='', capture_witness_verified=True,
            setup_complete=True, display_sync=dict(observed=True, enabled=True, disabled=False),
            presentation_clock='MTLDrawable.presentedTime', presentation_ms=[10.0],
            presentation_drawable_ids=[2], geometry_epoch=1, marker=[40, 40], viewport=[80, 80],
            requested_viewport=[80, 80], backing_scale=2, pty_cells=[10, 10], image_size=[16, 16],
            scene_pixels=[80, 80], native_view_pixels=[80, 80],
            window_key_start=[True], window_key_end=[True], app_active_start=[True], app_active_end=[True],
            initial_presentation=dict(geometry_requested_at=1, gpu_completed_at=2, presented_at=3,
                                      setup_completed_at=4, first_input_at=5, geometry_epoch=1,
                                      viewport=[80, 80], marker=[40, 40], drawable_id=1,
                                      clock='MTLDrawable.presentedTime'),
            fixtures=[dict(role='primary', error=None,
                           image=dict(width=16, height=16, format='RGBA8888', bytes_per_image=1024,
                                      payload_sha256=[hashlib.sha256(bytes([n])).hexdigest() for n in range(3)],
                                      transport='kitty-shared-memory'))])
        self.reference = self.write('reference', self.result, self.image)

    def write(self, label, result, image):
        result = copy.deepcopy(result)
        capture = self.root / (label + '.png')
        image.save(capture)
        result['capture'] = dict(path=str(capture), sha256=hashlib.sha256(capture.read_bytes()).hexdigest())
        path = self.root / (label + '.json')
        path.write_text(json.dumps(result))
        return path

    def test_exact_pixels(self):
        report = compare(self.reference, self.write('candidate', self.result, self.image))
        self.assertTrue(report['exact'])
        self.assertEqual(report['captures']['reference']['bounds'], [12, 12, 68, 68])

    def test_pixel_difference_is_reported(self):
        self.image.putpixel((30, 30), (17, 16, 16, 255))
        report = compare(self.reference, self.write('candidate', self.result, self.image))
        self.assertFalse(report['exact'])
        self.assertEqual(report['different_pixels'], 1)
        self.assertEqual(report['maximum_channel_difference'], 1)

    def test_centroid_shift_does_not_hide_pixel_difference(self):
        self.result['marker'] = [41, 40]
        self.result['initial_presentation']['marker'] = [41, 40]
        self.image.putpixel((30, 30), (20, 16, 16, 255))
        report = compare(self.reference, self.write('candidate', self.result, self.image))
        self.assertFalse(report['exact'])
        self.assertEqual(report['maximum_channel_difference'], 4)

    def test_tampered_capture_is_rejected(self):
        candidate = self.write('candidate', self.result, self.image)
        (self.root / 'candidate.png').write_bytes(b'changed after capture')
        with self.assertRaisesRegex(ValueError, 'digest'):
            compare(self.reference, candidate)

    def test_different_payload_is_rejected(self):
        self.result['fixtures'][0]['image']['payload_sha256'][0] = '0' * 64
        with self.assertRaisesRegex(ValueError, 'payloads'):
            compare(self.reference, self.write('candidate', self.result, self.image))

    def test_geometry_mismatch_is_rejected(self):
        self.result['backing_scale'] = 1
        with self.assertRaisesRegex(ValueError, 'geometry'):
            compare(self.reference, self.write('candidate', self.result, self.image))

    def test_actual_capture_dimensions_are_checked(self):
        resized = self.image.resize((81, 80))
        with self.assertRaisesRegex(ValueError, 'dimensions'):
            compare(self.reference, self.write('candidate', self.result, resized))

    def test_shifted_footprint_is_rejected(self):
        shifted = Image.new('RGBA', self.image.size, (16, 16, 16, 255))
        ImageDraw.Draw(shifted).rectangle((13, 12, 68, 67), outline=BORDER_RGBA)
        with self.assertRaisesRegex(ValueError, 'footprints'):
            compare(self.reference, self.write('candidate', self.result, shifted))

    def test_missing_and_ambiguous_borders_are_rejected(self):
        empty = Image.new('RGBA', self.image.size, (16, 16, 16, 255))
        with self.assertRaisesRegex(ValueError, 'one connected'):
            compare(self.reference, self.write('candidate', self.result, empty))
        ImageDraw.Draw(self.image).rectangle((20, 20, 59, 59), outline=BORDER_RGBA)
        with self.assertRaisesRegex(ValueError, 'one connected'):
            compare(self.reference, self.write('candidate', self.result, self.image))

    def test_native_faults_are_rejected(self):
        mutations = (
            lambda r: r.update(capture_witness_verified=False),
            lambda r: r.update(failed=1),
            lambda r: r.update(endpoint='gpu'),
            lambda r: r['initial_presentation'].update(presented_at=0),
            lambda r: r['display_sync'].update(enabled=False),
            lambda r: r.update(window_key_end=[False]),
            lambda r: r.update(app_active_start=[]),
        )
        for mutate in mutations:
            result = copy.deepcopy(self.result)
            mutate(result)
            with self.subTest(result=result), self.assertRaises(ValueError):
                compare(self.reference, self.write('candidate', result, self.image))


if __name__ == '__main__':
    unittest.main()
