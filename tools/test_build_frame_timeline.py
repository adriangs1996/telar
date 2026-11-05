from pathlib import Path
import unittest

from build_tab_switch_timeline import add_typing_timeline


class FrameTimelineTest(unittest.TestCase):
    def test_typing_observer_retains_native_clocks_and_endpoint(self):
        source = Path(__file__).with_name('gui_tui_latency.m').read_text()
        result = add_typing_timeline(source)
        for anchor in ('@"submission_samples": submissions', 'sample_presented[count] = frame->presented;',
                       'r->frame->gpu_started = completed.GPUStartTime;',
                       'r->frame->gpu_started = feedback.GPUStartTime;',
                       '++r->frame->commits'):
            self.assertIn(anchor, result)
        self.assertEqual(result.count('static void send_key(void)'), source.count('static void send_key(void)'))
        self.assertIn('frame->verified', result)
        self.assertIn('presented.presentedTime', result)

    def test_changed_native_commit_anchor_fails_closed(self):
        source = Path(__file__).with_name('gui_tui_latency.m').read_text()
        source = source.replace('    pending=NO;count++;', '')
        with self.assertRaisesRegex(ValueError, 'instrumentation anchor'):
            add_typing_timeline(source)


if __name__ == '__main__':
    unittest.main()
