import contextlib
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import check_browser_trust as check
import check_ca_rotation as rotation


class BrowserCheckTest(unittest.TestCase):
    def test_publication_fault_restores_the_exact_previous_file(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "ca").mkdir()
            active = root / "ca/ca-active-cert.pem"
            original = b"fixture public certificate\n"
            active.write_bytes(original)
            with self.assertRaisesRegex(RuntimeError, "interrupted rotation"):
                with rotation.blocked_publication(root):
                    self.assertTrue(active.is_dir())
                    self.assertEqual((root / "ca/fixture-active-cert.previous").read_bytes(), original)
                    raise RuntimeError("interrupted rotation")
            self.assertEqual(active.read_bytes(), original)
            self.assertFalse((root / "ca/fixture-active-cert.previous").exists())

    def test_candidate_public_certificate_survives_canonical_replacement(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "ca").mkdir()
            canonical = root / "ca/ca-system-cert.pem"
            candidate = root / "ca/ca-system-cert.pem.rotate-fixture"
            canonical.write_text("old public certificate")
            candidate.write_text("new public certificate")
            def fingerprint(path):
                return (("a" * 40, "b" * 64) if path.read_text().startswith("old") else ("c" * 40, "d" * 64))
            with patch.object(check, "fingerprints", side_effect=fingerprint):
                rotation.remember(root)
                candidate.replace(canonical)
                rotation.remember(root)
            self.assertEqual((root / ("authorities/" + "a" * 40 + ".pem")).read_text(), "old public certificate")
            self.assertEqual((root / ("authorities/" + "c" * 40 + ".pem")).read_text(), "new public certificate")

    def test_rotation_cannot_overwrite_a_previous_native_baseline(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            baseline = root / "baseline.json"
            baseline.write_text('["' + "a" * 40 + '"]\n')
            original = baseline.read_bytes()
            with patch.object(rotation, "keychain_fingerprints", side_effect=AssertionError("Must not inspect a new baseline")):
                with self.assertRaisesRegex(RuntimeError, "native attempt already exists"):
                    rotation.live(root, {})
            self.assertEqual(baseline.read_bytes(), original)

    def test_cleanup_reports_unattributed_roots_without_deleting_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "authorities").mkdir()
            (root / "proofs").mkdir()
            foreign = "e" * 40
            with patch.object(rotation, "remember"), \
                 patch.object(rotation, "keychain_fingerprints", return_value={foreign}), \
                 patch.object(check, "run", side_effect=AssertionError("Do not delete an unattributed certificate")):
                with self.assertRaisesRegex(RuntimeError, "unattributed keychain"):
                    rotation.cleanup(root, {}, set())
            self.assertEqual(json.loads((root / "unattributed-keychain-hashes.json").read_text()), [foreign])

    def fixture(self, root):
        (root / "ca").mkdir(mode=0o700)
        state = {"sha1": "a" * 40, "sha256": "b" * 64,
                 "keychain": str(Path.home() / "Library/Keychains/login.keychain-db"), "tls_probe": "/fixture/tls-tests"}
        source = root / "prepared.json"
        source.write_text(json.dumps(state))
        source.chmod(0o600)
        return state

    def test_explicit_fingerprint_and_native_keychain_are_required(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = self.fixture(root)
            with patch.object(check, "fingerprints", return_value=(state["sha1"], state["sha256"])):
                self.assertEqual(check.prepared(root, state["sha256"])[1], state)
                with self.assertRaisesRegex(ValueError, "fingerprint"):
                    check.prepared(root, "c" * 64)
                state["keychain"] = "/different/keychain"
                (root / "prepared.json").write_text(json.dumps(state))
                with self.assertRaisesRegex(ValueError, "different keychain"):
                    check.prepared(root, state["sha256"])

    def test_replaced_certificate_and_shared_fixture_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = self.fixture(root)
            with patch.object(check, "fingerprints", return_value=("c" * 40, "d" * 64)):
                with self.assertRaisesRegex(ValueError, "fingerprint"):
                    check.prepared(root, state["sha256"])
            (root / "prepared.json").chmod(0o644)
            with self.assertRaisesRegex(ValueError, "Unsafe"):
                check.prepared(root, state["sha256"])

    def test_failed_install_still_cleans_native_trust_without_local_record(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = self.fixture(root)
            with patch.object(check, "run"), \
                 patch.object(check, "verify", side_effect=[True, False]), \
                 patch.object(check, "certificate_present", return_value=False), \
                 patch.object(check, "runtime", return_value=contextlib.nullcontext((root / "runtime.sock", 1234))), \
                 patch.object(check, "control", side_effect=RuntimeError("installation interrupted")), \
                 patch.object(check, "cleanup") as cleanup, \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "installation interrupted"):
                    check.live(root, state)
                cleanup.assert_called_once_with(root, state)
                self.assertTrue(root.exists(), "Preserve diagnostics after a failed live check")

    def test_cleanup_failure_preserves_fixture_and_original_failure(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            state = self.fixture(root)
            with patch.object(check, "run"), \
                 patch.object(check, "verify", side_effect=[True, False]), \
                 patch.object(check, "certificate_present", return_value=False), \
                 patch.object(check, "runtime", return_value=contextlib.nullcontext((root / "runtime.sock", 1234))), \
                 patch.object(check, "control", side_effect=RuntimeError("original installation failure")), \
                 patch.object(check, "cleanup", side_effect=RuntimeError("keychain unavailable")), \
                 contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(RuntimeError, "original installation failure"):
                    check.live(root, state)
                self.assertIn("keychain unavailable", (root / "cleanup-errors.log").read_text())
                self.assertTrue((root / "prepared.json").exists())


if __name__ == "__main__":
    unittest.main()
