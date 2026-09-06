"""The exterior keyboard gate must prove text insertion, not just key delivery."""

import unittest

from verify_terminal_browser import keyboard_text_inserted


class KeyboardVerificationTests(unittest.TestCase):
    def test_accepts_one_typed_character(self):
        self.assertTrue(keyboard_text_inserted([
            {"event": "key", "key": "a"},
            {"event": "input", "input_type": "insertText", "value": "a"},
            {"event": "completed", "keyboard_value": "a"},
        ]))

    def test_rejects_keydown_without_text(self):
        self.assertFalse(keyboard_text_inserted([
            {"event": "key", "key": "a"},
            {"event": "completed", "keyboard_value": ""},
        ]))

    def test_rejects_paste_as_keyboard_evidence(self):
        self.assertFalse(keyboard_text_inserted([
            {"event": "key", "key": "a"},
            {"event": "text-input", "data": "a"},
            {"event": "input", "input_type": "insertFromPaste", "value": "a"},
            {"event": "completed", "keyboard_value": "a"},
        ]))

    def test_rejects_duplicate_or_lost_text(self):
        for value in ("aa", ""):
            with self.subTest(value=value):
                self.assertFalse(keyboard_text_inserted([
                    {"event": "input", "input_type": "insertText", "value": "a"},
                    {"event": "completed", "keyboard_value": value},
                ]))

    def test_rejects_incomplete_or_empty_evidence(self):
        self.assertFalse(keyboard_text_inserted([]))
        self.assertFalse(keyboard_text_inserted([
            {"event": "input", "input_type": "insertText", "value": "a"},
        ]))


if __name__ == "__main__":
    unittest.main()
