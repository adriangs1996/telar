import hashlib
import importlib.util
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
import zipfile
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / 'bootstrap-cpp.py'
spec = importlib.util.spec_from_file_location('cpp_bootstrap', MODULE)
bootstrap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bootstrap)


def archive(name='package/bin/tool', link=None):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as package:
        entry = tarfile.TarInfo(name)
        if link:
            entry.type = tarfile.SYMTYPE
            entry.linkname = link
            package.addfile(entry)
        else:
            data = b'verified tool\n'
            entry.size = len(data)
            entry.mode = 0o755
            package.addfile(entry, io.BytesIO(data))
    return output.getvalue()


class BootstrapIntegrity(unittest.TestCase):
    def test_flat_zip_preserves_the_executable_after_publication(self):
        output = io.BytesIO()
        with zipfile.ZipFile(output, 'w') as package:
            package.writestr('ninja', b'verified executable')
        data = output.getvalue()
        pin = {'url': 'https://example.invalid/ninja.zip', 'sha256': hashlib.sha256(data).hexdigest()}
        with tempfile.TemporaryDirectory() as directory:
            with patch.object(bootstrap.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                target = bootstrap.prepare('ninja', pin, Path(directory))
            self.assertEqual((target / 'ninja').read_bytes(), b'verified executable')
            self.assertTrue((target / 'ninja').stat().st_mode & 0o111)

    def prepare(self, directory, data, digest=None):
        pin = {'url': 'https://example.invalid/tool.tar.gz',
               'sha256': digest or hashlib.sha256(data).hexdigest()}
        with patch.object(bootstrap.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
            return bootstrap.prepare('test', pin, Path(directory))

    def test_verified_install_is_reused_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            data = archive()
            target = self.prepare(directory, data)
            self.assertEqual((target / 'bin/tool').read_bytes(), b'verified tool\n')
            self.assertTrue((target / 'bin/tool').stat().st_mode & 0o111)
            with patch.object(bootstrap.urllib.request, 'urlopen', side_effect=AssertionError('unexpected download')):
                pin = {'url': 'https://example.invalid/tool.tar.gz', 'sha256': hashlib.sha256(data).hexdigest()}
                self.assertEqual(bootstrap.prepare('test', pin, Path(directory)), target)

    def test_mismatched_download_is_not_published(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'SHA-256 mismatch'):
                self.prepare(directory, archive(), '0' * 64)
            self.assertFalse(list(Path(directory).glob('test-*/.complete')))

    def test_archive_path_cannot_escape_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'Unsafe archive'):
                self.prepare(directory, archive('../../escape'))

    def test_archive_link_chain_cannot_escape_cache(self):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w:gz') as package:
            for name, target in (('a', '.'), ('b', 'a/../escape')):
                entry = tarfile.TarInfo(name)
                entry.type = tarfile.SYMTYPE
                entry.linkname = target
                package.addfile(entry)
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'Unsafe archive link'):
                self.prepare(directory, output.getvalue())

    def test_archive_symlink_cannot_escape_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, 'Unsafe archive link'):
                self.prepare(directory, archive('package/link', '/tmp/escape'))


if __name__ == '__main__':
    unittest.main()
