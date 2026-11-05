import hashlib
from pathlib import Path
import tempfile
import unittest

from qt_framework_receipt import verify_loaded_qt_images


class QtFrameworkReceiptTest(unittest.TestCase):
    def test_frozen_paths_bytes_and_negative_controls(self):
        with tempfile.TemporaryDirectory() as directory:
            expected = {}
            images = []
            for name in ('QtCore', 'QtGui', 'QtQuick'):
                path = Path(directory) / f'{name}.framework/Versions/A/{name}'
                path.parent.mkdir(parents=True)
                path.write_bytes(name.encode())
                expected[name] = dict(path=str(path), sha256=hashlib.sha256(path.read_bytes()).hexdigest())
                images.append(str(path))
            self.assertEqual(set(verify_loaded_qt_images(dict(loaded_images=images), expected)), set(expected))
            for invalid in (None, [], images[:-1], images + [images[0]], images + ['relative/path'], images + [False]):
                with self.subTest(images=invalid), self.assertRaises(ValueError):
                    verify_loaded_qt_images(dict(loaded_images=invalid), expected)
            wrong = {key: dict(value) for key, value in expected.items()}
            wrong['QtGui']['path'] = expected['QtCore']['path']
            with self.assertRaises(ValueError):
                verify_loaded_qt_images(dict(loaded_images=images), wrong)
            wrong['QtGui']['path'] = expected['QtGui']['path']
            wrong['QtGui']['sha256'] = '0' * 64
            with self.assertRaises(ValueError):
                verify_loaded_qt_images(dict(loaded_images=images), wrong)
            unknown = Path(directory) / 'QtUnknown.framework/Versions/A/QtUnknown'
            with self.assertRaises(ValueError):
                verify_loaded_qt_images(dict(loaded_images=images + [str(unknown)]), expected)
            Path(expected['QtGui']['path']).write_bytes(b'modified after freezing')
            with self.assertRaises(ValueError):
                verify_loaded_qt_images(dict(loaded_images=images), expected)


if __name__ == '__main__':
    unittest.main()
