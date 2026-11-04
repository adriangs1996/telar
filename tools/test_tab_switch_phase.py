import ctypes
import math
from pathlib import Path
import random
import subprocess
import sys
import tempfile
import unittest

from tab_switch_fixture import PUBLICATION


class Plan(ctypes.Structure):
    _fields_ = [('deadline', ctypes.c_double), ('clearance', ctypes.c_double)]


class PhaseTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory(prefix='telar-tab-phase-')
        cls.addClassCleanup(cls.directory.cleanup)
        root = Path(cls.directory.name)
        source = root / 'phase.c'
        source.write_text('#include "tab_switch_phase.h"\n'
                          'bool plan(const double *phases, double now, TabPhasePlan *out) {'
                          ' return tab_phase_plan(phases, now, out); }\n'
                          'bool origin(const unsigned char *data, size_t length, double *out) {'
                          ' return tab_phase_origin(data, length, out); }\n')
        library = root / ('phase.dylib' if sys.platform == 'darwin' else 'phase.so')
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-O2',
                        '-dynamiclib' if sys.platform == 'darwin' else '-shared', '-fPIC',
                        '-I', str(Path(__file__).resolve().parent), str(source), '-lm', '-o', str(library)], check=True)
        cls.library = ctypes.CDLL(str(library))
        cls.plan = cls.library.plan
        cls.plan.argtypes = [ctypes.POINTER(ctypes.c_double), ctypes.c_double, ctypes.POINTER(Plan)]
        cls.plan.restype = ctypes.c_bool
        cls.origin = cls.library.origin
        cls.origin.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.POINTER(ctypes.c_double)]
        cls.origin.restype = ctypes.c_bool

    def planned(self, phases, now=150000):
        out = Plan()
        self.assertTrue(self.plan((ctypes.c_double * 4)(*phases), now, ctypes.byref(out)))
        return out

    def test_widest_circular_gap_matches_independent_reference(self):
        rng = random.Random(20261104)
        period = 1 / 30
        cases = [[10] * 4, [10 + i * period / 4 for i in range(4)]]
        cases += [[10 + rng.random() * period for _ in range(4)] for _ in range(2048)]
        for phases in cases:
            plan = self.planned(phases)
            ordered = sorted(value % period for value in phases)
            gaps = [ordered[(i + 1) % 4] + (period if i == 3 else 0) - value
                    for i, value in enumerate(ordered)]
            self.assertAlmostEqual(plan.clearance, max(gaps) / 2, places=9)
            self.assertGreater(plan.deadline, 150000)
            self.assertLessEqual(plan.deadline, 150000 + 2 * period)
            for phase in phases:
                distance = abs((plan.deadline - phase + period / 2) % period - period / 2)
                self.assertGreaterEqual(distance + 1e-9, plan.clearance)

    def test_recent_publications_recover_phase_despite_one_late_write(self):
        values = [PUBLICATION.pack(i, 100 + i / 30, 100 + i / 30 + .0001 + (.002 if i == 32 else 0))
                  for i in range(1, 33)]
        data = b''.join(values)
        out = ctypes.c_double()
        self.assertTrue(self.origin(data, len(data), ctypes.byref(out)))
        self.assertAlmostEqual(out.value, 100.0001, places=9)

    def test_invalid_publications_and_clocks_fail_closed(self):
        valid = b''.join(PUBLICATION.pack(i, 100 + i / 30, 100 + i / 30 + .0001) for i in range(1, 17))
        invalid = [b'', valid[:7 * PUBLICATION.size], valid[:-1],
                   valid[:-PUBLICATION.size] + PUBLICATION.pack(16, math.nan, math.nan),
                   valid[:-PUBLICATION.size] + PUBLICATION.pack(16, 102, 101),
                   valid[:-PUBLICATION.size] + PUBLICATION.pack(0, 101, 101)]
        for data in invalid:
            with self.subTest(length=len(data)):
                self.assertFalse(self.origin(data, len(data), ctypes.byref(ctypes.c_double())))
        for now in (0, -1, math.nan, math.inf):
            self.assertFalse(self.plan((ctypes.c_double * 4)(10, 10, 10, 10), now, ctypes.byref(Plan())))
        for bad in (0, -1, math.nan, math.inf, 150001):
            self.assertFalse(self.plan((ctypes.c_double * 4)(10, 10, 10, bad), 150000, ctypes.byref(Plan())))


if __name__ == '__main__':
    unittest.main()
