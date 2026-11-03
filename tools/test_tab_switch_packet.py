import ctypes
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

import tab_switch_packet as packet


class Decoded(ctypes.Structure):
    _fields_ = [('tab', ctypes.c_uint), ('generation', ctypes.c_uint)]


def pixels(tab, generation, width=19):
    colors = [(60, 20, 230, 255)] + [(8 + 16 * value,) * 3 + (255,)
                                    for value in packet.nibbles(tab, generation)]
    return b''.join(bytes(color) * width for color in colors)


class PacketTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='telar-tab-packet-')
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        source = root / 'decode.c'
        source.write_text('#include "tab_switch_packet.h"\n'
                          'bool decode(const uint8_t *p, size_t n, size_t stride, TabPacket *out) {'
                          ' return tab_packet_decode(p,n,stride,out); }\n')
        library = root / ('decode.dylib' if sys.platform == 'darwin' else 'decode.so')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC',
                        '-I', str(Path(__file__).resolve().parent), str(source), '-o', str(library)], check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.decode = cls.library.decode
        cls.decode.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_size_t, ctypes.POINTER(Decoded)]
        cls.decode.restype = ctypes.c_bool

    def decoded(self, data, width=19, length=None):
        output = Decoded(99, 99)
        valid = self.decode(data, len(data) if length is None else length, width * 4, ctypes.byref(output))
        return valid, output.tab, output.generation

    def test_known_crc_vector(self):
        # CRC-8/SMBUS of bytes 00 00 01.
        self.assertEqual(packet.checksum(0, 1), 7)
        self.assertEqual(packet.nibbles(0, 1), [0, 0, 0, 0, 1, 0, 7])

    def test_original_values_survive_native_readback_at_different_cell_widths(self):
        random_source = random.Random(814)
        cases = [(tab, generation) for tab in range(16) for generation in (1, 15, 16, 255, 256, 65535)]
        cases += [(random_source.randrange(16), random_source.randrange(1, 65536)) for _ in range(1024)]
        for tab, generation in cases:
            for width in (1, 7, 19, 38):
                with self.subTest(tab=tab, generation=generation, width=width):
                    self.assertEqual(self.decoded(pixels(tab, generation, width), width), (True, tab, generation))

    def test_each_corrupted_cell_and_channel_is_rejected(self):
        original = pixels(3, 16384)
        for cell in range(8):
            for channel in range(4):
                value = bytearray(original)
                value[cell * 19 * 4 + channel] ^= 16
                self.assertFalse(self.decoded(bytes(value))[0])

    def test_whole_nibble_mutation_cannot_impersonate_another_target(self):
        original = pixels(3, 16384)
        for cell in range(1, 8):
            value = bytearray(original)
            for channel in range(3):
                value[cell * 19 * 4 + channel] ^= 16
            self.assertFalse(self.decoded(bytes(value))[0])

    def test_truncation_and_invalid_stride_are_rejected(self):
        data = pixels(1, 42)
        required = 7 * 19 * 4 + 4
        for length in range(required):
            self.assertFalse(self.decoded(data, length=length)[0])
        self.assertTrue(self.decoded(data, length=required)[0])
        for width in (0, 100000):
            self.assertFalse(self.decoded(data, width=width)[0])

    def test_invalid_identity_or_generation_cannot_be_emitted(self):
        for tab, generation in ((-1, 1), (16, 1), (0, 0), (0, 65536)):
            with self.assertRaises(ValueError):
                packet.marker(tab, generation)


if __name__ == '__main__':
    unittest.main()
