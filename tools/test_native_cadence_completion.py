import json
from pathlib import Path
import tempfile
import threading
import unittest
from unittest.mock import patch

from native_cadence_completion import finish_cadence_fixture


class CompletionTest(unittest.TestCase):
    def fixture(self, directory):
        (directory / 'result.json').write_text(json.dumps(dict(
            failed=0, cadence=dict(window_start=10, window_end=11))))
        (directory / 'cadence-producer.json').write_text(json.dumps(dict(
            events=[dict(sequence=1680, accepted_ns=10_999_000_000)])))

    def test_late_checkpoint_is_retained_before_cleanup(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory)
            def publish():
                path = directory / 'next.json'
                path.write_text(json.dumps(dict(events=[dict(sequence=1800, accepted_ns=11_500_000_000)])))
                path.replace(directory / 'cadence-producer.json')
            timer = threading.Timer(.1, publish)
            timer.start()
            try:
                finish_cadence_fixture(directory)
            finally:
                timer.join()
            receipt = json.loads((directory / 'cadence-completion.json').read_text())
            self.assertEqual([r['sequence'] for r in receipt['observations']], [1680, 1800])
            self.assertGreaterEqual(receipt['waited_seconds'], .09)

    def test_incomplete_receipt_is_not_accepted_at_timeout(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            self.fixture(directory)
            with patch('native_cadence_completion.time.monotonic', side_effect=[0, 4, 4]):
                with self.assertRaisesRegex(RuntimeError, 'did not cover'):
                    finish_cadence_fixture(directory)
            receipt = json.loads((directory / 'cadence-completion.json').read_text())
            self.assertTrue(receipt['status'].startswith('failed:'))


if __name__ == '__main__':
    unittest.main()
