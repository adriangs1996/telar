import tempfile
from pathlib import Path
import unittest

from pty_read_report import BYTE_CAPACITY, HEADER, MAGIC, RECORD, RECORD_CAPACITY, read_trace


def sample():
    data = bytearray(HEADER.size + RECORD_CAPACITY * RECORD.size + BYTE_CAPACITY)
    HEADER.pack_into(data, 0, MAGIC, 1, RECORD_CAPACITY, BYTE_CAPACITY, 1, 3, 0, 1)
    RECORD.pack_into(data, HEADER.size, 1, 2, 42, 7, 16384, 3, 0, 0, 3, 1)
    offset = HEADER.size + RECORD_CAPACITY * RECORD.size
    data[offset:offset + 3] = b'abc'
    return data


class PtyReadReportTest(unittest.TestCase):
    def test_valid_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace'
            path.write_bytes(sample())
            rows = read_trace(path, 42)
            self.assertEqual(rows[0]['data'], b'abc')
            self.assertEqual(rows[0]['requested'], 16384)

    def test_malformed_traces_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'trace'
            mutations = [(0, 0), (8, 2), (16, RECORD_CAPACITY + 1),
                         (24, BYTE_CAPACITY + 1), (32, 0), (32, RECORD_CAPACITY + 1),
                         (40, 4), (48, 1), (56, 0),
                         (HEADER.size, 3), (HEADER.size + 16, 43),
                         (HEADER.size + 24, 2**31), (HEADER.size + 48, 2**31),
                         (HEADER.size + 32, 2), (HEADER.size + 56, 1),
                         (HEADER.size + 64, 2), (HEADER.size + 72, 0)]
            for offset, value in mutations:
                with self.subTest(offset=offset):
                    data = sample()
                    data[offset:offset + 8] = value.to_bytes(8, 'little')
                    path.write_bytes(data)
                    with self.assertRaises(ValueError):
                        read_trace(path, 42)
            path.write_bytes(sample()[:-1])
            with self.assertRaises(ValueError):
                read_trace(path, 42)

    def test_invalid_expected_identity(self):
        for pid in (True, 0, -1, 2**31, '42'):
            with self.assertRaisesRegex(ValueError, 'process identity'):
                read_trace('unused', pid)


if __name__ == '__main__':
    unittest.main()
