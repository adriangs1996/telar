#!/usr/bin/env python3
"""Contract tests for the live experiment; these never call a model."""

import copy
import difflib
import threading
import json
from pathlib import Path
import socket
import struct
import tempfile
import unittest

import review_live as live

FIRST = ('def slugify(text: str) -> str:\n'
         '    """Create a URL fragment from a label."""\n'
         '    normalized = text.lower()\n'
         '    return normalized.replace(" ", "-")\n')
SECOND = ('def slugify(text: str) -> str:\n'
          '    """Create a URL fragment from a label."""\n'
          '    normalized = text.lower().split()\n'
          '    return "-".join(normalized)\n')


def evidence(workspace, identity="first"):
    before, after = (live.BASE_SOURCE, FIRST) if identity == "first" else (FIRST, SECOND)
    patch = "".join(list(difflib.unified_diff(before.splitlines(keepends=True), after.splitlines(keepends=True)))[2:])
    return dict(id=identity, thread_id="session-1", cwd=str(workspace), items=[dict(
        id="edit-" + identity, type="fileChange", status="completed",
        changes=[dict(path=str(workspace / live.SOURCE_NAME), kind=dict(type="update", move_path=None),
                      diff=patch)])])


class Provider:
    thread_id = "session-1"

    def __init__(self, directory):
        self.directory = directory
        self.calls = []
        self.fail = False

    def turn(self, prompt):
        self.calls.append(prompt)
        if self.fail:
            raise live.ReviewError("Provider disconnected after accepting the request")
        (self.directory / "workspace" / live.SOURCE_NAME).write_text(SECOND)
        return evidence(self.directory / "workspace", "second")


class ReviewTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        (self.directory / "workspace").mkdir()
        self.source = self.directory / "workspace" / live.SOURCE_NAME
        self.source.write_text(FIRST)
        self.provider = Provider(self.directory)
        self.review = live.Review(self.directory, self.provider)
        self.revision = self.review.capture(live.BASE_SOURCE, evidence(self.directory / "workspace"))
        self.request = dict(schema=1, action="submit", request_id="review-1", revision_id=self.revision["id"], comments=[dict(
            file="slug.py", side="after", first_line=3, last_line=4,
            body="Trim and collapse whitespace, including tabs. Keep lowercase: '  Café  Mundo\\t ' -> 'café-mundo'.")])

    def test_full_context_snapshot_has_provenance_and_adjacent_revision(self):
        result = self.review.submit(self.request)
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["session_id"], "session-1")
        self.assertEqual(len(self.provider.calls), 1)
        self.assertEqual(self.review.revisions[1]["before"], FIRST)
        self.assertEqual(self.review.revisions[1]["after"], SECOND)
        self.assertIn('-    return normalized.replace(" ", "-")', result["revisions"][1]["patch"])
        self.assertEqual(self.revision["evidence"][0]["item_id"], "edit-first")
        self.assertEqual(self.review.revisions[1]["thread_id"], self.revision["thread_id"])
        stored = json.loads((self.directory / "submission.json").read_text())
        self.assertEqual(stored["request"], self.request)
        self.assertEqual(stored["delivery"], "completed")
        self.assertIn("slug.py after lines 3-4", self.provider.calls[0])
        self.assertIn(self.request["comments"][0]["body"], self.provider.calls[0])

    def test_duplicate_submission_does_not_run_another_turn(self):
        first = self.review.submit(self.request)
        self.assertEqual(first, self.review.submit(copy.deepcopy(self.request)))
        self.assertEqual(len(self.provider.calls), 1)
        changed = copy.deepcopy(self.request)
        changed["comments"][0]["body"] = "Different feedback"
        with self.assertRaisesRegex(live.ReviewError, "different review"):
            self.review.submit(changed)
        self.assertEqual(len(self.provider.calls), 1)

    def test_outside_edit_rejects_stale_review_without_dispatch(self):
        self.source.write_text(FIRST + "# Another writer changed this file.\n")
        with self.assertRaisesRegex(live.ReviewError, "Source changed"):
            self.review.submit(self.request)
        self.assertFalse(self.provider.calls)
        self.assertFalse((self.directory / "submission.json").exists())

    def test_invalid_file_side_range_revision_and_capacity_are_rejected(self):
        cases = [dict(file="../slug.py"), dict(side="elsewhere"), dict(first_line=0),
                 dict(first_line=4, last_line=3), dict(last_line=5), dict(first_line=True),
                 dict(body=" \n\t"), dict(body="界" * 683), dict(body="bad\0text")]
        for mutation in cases:
            with self.subTest(mutation=mutation):
                request = copy.deepcopy(self.request)
                request["comments"][0].update(mutation)
                with self.assertRaises(live.ReviewError):
                    self.review.submit(request)
        wrong_revision = dict(self.request, revision_id="previous-version")
        too_many = dict(self.request, comments=self.request["comments"] * 33)
        for request in [wrong_revision, too_many]:
            with self.assertRaises(live.ReviewError):
                self.review.submit(request)
        self.assertFalse(self.provider.calls)

    def test_before_side_uses_before_source_line_count(self):
        request = copy.deepcopy(self.request)
        request["comments"][0].update(side="before", first_line=3, last_line=3)
        live.validate_request(request, self.revision)
        request["comments"][0]["last_line"] = 4
        with self.assertRaises(live.ReviewError):
            live.validate_request(request, self.revision)

    def test_unknown_delivery_is_persisted_and_never_retried_implicitly(self):
        self.provider.fail = True
        result = self.review.submit(self.request)
        self.assertEqual(result["status"], "error")
        self.assertEqual(len(result["revisions"]), 1)
        self.assertEqual(len(result["comments"]), 1)
        self.assertEqual(result, self.review.submit(self.request))
        self.assertEqual(len(self.provider.calls), 1)
        stored = json.loads((self.directory / "submission.json").read_text())
        self.assertEqual(stored["delivery"], "failed_or_unknown")

    def test_snapshot_requires_successful_file_change_for_the_same_path(self):
        for mutation in ["none", "wrong_path", "failed", "missing_patch", "move", "wrong_session"]:
            turn = evidence(self.directory / "workspace")
            if mutation == "none":
                turn["items"] = []
            elif mutation == "wrong_path":
                turn["items"][0]["changes"][0]["path"] = "/unrelated/slug.py"
            elif mutation == "failed":
                turn["items"][0]["status"] = "failed"
            elif mutation == "missing_patch":
                turn["items"][0]["changes"][0]["diff"] = ""
            elif mutation == "wrong_session":
                turn["thread_id"] = "another-session"
            elif mutation == "move":
                turn["items"][0]["changes"][0]["kind"]["move_path"] = "/other.py"
            with self.subTest(mutation=mutation), self.assertRaises(live.ReviewError):
                live.make_revision(live.BASE_SOURCE, FIRST, turn, "session-1")

    def test_provider_patch_must_reproduce_snapshot_and_preserve_edit_order(self):
        first = evidence(self.directory / "workspace")
        second = evidence(self.directory / "workspace", "second")
        with self.assertRaisesRegex(live.ReviewError, "reproduce"):
            live.make_revision(live.BASE_SOURCE, SECOND, first, "session-1")
        combined = dict(first, items=first["items"] + second["items"])
        result = live.make_revision(live.BASE_SOURCE, SECOND, combined, "session-1")
        self.assertEqual(len(result["evidence"]), 2)
        combined["items"].reverse()
        with self.assertRaises(live.ReviewError):
            live.make_revision(live.BASE_SOURCE, SECOND, combined, "session-1")

    def test_failed_edit_retry_retains_diagnostic_and_only_replays_success(self):
        turn = evidence(self.directory / "workspace")
        failed = copy.deepcopy(turn["items"][0])
        failed.update(status="failed", id="failed-attempt")
        failed["changes"][0]["diff"] = "could not apply"
        turn["items"].insert(0, failed)
        result = live.make_revision(live.BASE_SOURCE, FIRST, turn, "session-1")
        self.assertEqual(result["failed_edits"][0]["id"], "failed-attempt")
        self.assertEqual(len(result["evidence"]), 1)

    def test_loading_duplicate_and_wait_while_correction_runs(self):
        started, release = threading.Event(), threading.Event()
        original = self.provider.turn
        results = []

        def blocked(prompt):
            started.set()
            self.assertTrue(release.wait(5))
            return original(prompt)

        self.provider.turn = blocked
        thread = threading.Thread(target=lambda: results.append(self.review.submit(self.request)))
        thread.start()
        waiting = None
        try:
            self.assertTrue(started.wait(2))
            snapshot = self.review.handle(dict(schema=1, action="load"))
            self.assertEqual(snapshot["status"], "working")
            self.assertEqual(self.review.submit(self.request)["status"], "working")
            waiting = threading.Thread(target=lambda: results.append(self.review.handle(dict(schema=1, action="wait"))))
            waiting.start()
            self.assertTrue(waiting.is_alive())
        finally:
            release.set()
            thread.join(5)
            if waiting:
                waiting.join(5)
        self.assertFalse(thread.is_alive())
        self.assertFalse(waiting.is_alive())
        self.assertEqual([result["status"] for result in results], ["complete", "complete"])
        self.assertEqual(len(self.provider.calls), 1)

    def test_correction_revision_and_completion_are_published_together(self):
        captured, release = threading.Event(), threading.Event()
        original = self.review.capture
        results = []

        def paused_capture(before, turn):
            revision = original(before, turn)
            captured.set()
            self.assertTrue(release.wait(5))
            return revision

        self.review.capture = paused_capture
        thread = threading.Thread(target=lambda: results.append(self.review.submit(self.request)))
        thread.start()
        try:
            self.assertTrue(captured.wait(2))
            snapshot = self.review.handle(dict(schema=1, action="load"))
            self.assertEqual(len(snapshot["revisions"]), 2)
            self.assertEqual(snapshot["status"], "complete")
            self.assertEqual(self.review.submit(self.request)["status"], "complete")
        finally:
            release.set()
            thread.join(5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(len(self.provider.calls), 1)
        self.assertEqual(results[0]["status"], "complete")

    def test_restore_keeps_completed_request_and_never_repeats_model_turn(self):
        self.review.submit(self.request)
        provider = Provider(self.directory)
        restored = live.Review(self.directory, provider)
        restored.restore()
        self.assertEqual(restored.submit(self.request)["status"], "complete")
        self.assertEqual(restored.snapshot(), self.review.snapshot())
        self.assertFalse(provider.calls)

    def test_restore_uncertain_dispatch_refuses_implicit_retry(self):
        submission = dict(request=self.request, fingerprint=live.validate_request(self.request, self.revision), delivery="dispatching")
        live.atomic_json(self.directory / "submission.json", submission)
        restored = live.Review(self.directory, Provider(self.directory))
        restored.restore()
        self.assertEqual(restored.submit(self.request)["status"], "error")
        self.assertFalse(restored.provider.calls)

    def test_source_symlink_and_oversize_fail_before_reading(self):
        self.source.unlink()
        target = self.directory / "outside.py"
        target.write_text(FIRST)
        self.source.symlink_to(target)
        with self.assertRaises(OSError):
            live.bounded_text(self.source)
        self.source.unlink()
        self.source.write_text("a" * (live.MAX_PATCH + 1))
        with self.assertRaises(live.ReviewError):
            live.bounded_text(self.source)

    def test_socket_frame_roundtrip_and_length_rejection(self):
        sender, receiver = socket.socketpair()
        self.addCleanup(sender.close)
        self.addCleanup(receiver.close)
        live.write_frame(sender, self.request)
        self.assertEqual(live.read_frame(receiver), self.request)
        sender.sendall(struct.pack("<I", live.MAX_FRAME + 1))
        with self.assertRaisesRegex(live.ReviewError, "length"):
            live.read_frame(receiver)


if __name__ == "__main__":
    unittest.main()
