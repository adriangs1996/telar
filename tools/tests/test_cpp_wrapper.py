"""Check how tools/cpp shares the machine among the builds of several checkouts."""
from importlib.machinery import SourceFileLoader
import importlib.util
import os
from pathlib import Path
import tempfile
import unittest

MODULE = Path(__file__).resolve().parents[1] / 'cpp'
loader = SourceFileLoader('cpp_wrapper', str(MODULE))
spec = importlib.util.spec_from_loader('cpp_wrapper', loader)
wrapper = importlib.util.module_from_spec(spec)
loader.exec_module(wrapper)


class BuildSlots(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.slots = Path(self.directory.name) / 'slots'
        self.held = []

    def tearDown(self):
        for descriptor in self.held:
            os.close(descriptor)
        self.directory.cleanup()

    def build(self):
        """Starts a build: its slot, held until finish() closes the descriptor, as a build's exit does."""
        slot, descriptor = wrapper.build_slot(self.slots)
        self.held.append(descriptor)
        return slot

    def finish(self, index):
        os.close(self.held.pop(index))

    def test_builds_at_once_take_successive_slots(self):
        self.assertEqual([self.build() for _ in range(3)], [0, 1, 2])

    def test_a_finished_build_frees_its_slot(self):
        self.assertEqual([self.build(), self.build()], [0, 1])
        self.finish(0)
        self.assertEqual(self.build(), 0)

    def test_a_directory_that_cannot_be_used_leaves_the_build_alone(self):
        blocked = Path(self.directory.name) / 'file'
        blocked.write_text('')
        self.assertEqual(wrapper.build_slot(blocked / 'slots'), (0, None))


class SharedArguments(unittest.TestCase):
    def test_the_first_build_keeps_its_arguments(self):
        self.assertEqual(wrapper.shared(['--target', 'telar'], 0, 8), ['--target', 'telar'])

    def test_a_later_build_divides_the_cores_by_its_place(self):
        self.assertEqual(wrapper.shared(['--target', 'telar'], 1, 8), ['--target', 'telar', '--parallel', '4'])
        self.assertEqual(wrapper.shared(['--target', 'telar'], 2, 8), ['--target', 'telar', '--parallel', '2'])
        self.assertEqual(wrapper.shared(['--target', 'telar'], 20, 8), ['--target', 'telar', '--parallel', '1'])

    def test_the_count_goes_before_the_arguments_meant_for_ninja(self):
        self.assertEqual(wrapper.shared(['--target', 'telar', '--', '-k', '0'], 1, 8), ['--target', 'telar', '--parallel', '4', '--', '-k', '0'])

    def test_a_count_the_caller_names_is_kept(self):
        self.assertEqual(wrapper.shared(['--parallel', '3'], 1, 8), ['--parallel', '3'])
        self.assertEqual(wrapper.shared(['--', '-j2'], 1, 8), ['--', '-j2'])


if __name__ == '__main__':
    unittest.main()
