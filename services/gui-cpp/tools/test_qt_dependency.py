import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

from package_macos import qt_installation


BASE = Path(__file__).resolve().parents[1]
RECIPE = BASE / "cmake/qt"


def run(*arguments, **kwargs):
    return subprocess.run(arguments, text=True, capture_output=True, **kwargs)


class QtDependencyTest(unittest.TestCase):
    @unittest.skipUnless(os.environ.get("TELAR_GUI_QT_CACHE"), "requires a configured GUI build")
    def test_configured_gui_uses_only_its_managed_qt(self):
        cache = Path(os.environ["TELAR_GUI_QT_CACHE"]).read_text()
        prefix = qt_installation(cache)
        packages = re.findall(r"^Qt6\w*_DIR:PATH=(.+)$", cache, re.M)
        self.assertGreater(len(packages), 1)
        for package in packages:
            if not package.endswith("-NOTFOUND"):
                self.assertTrue(Path(package).resolve().is_relative_to(prefix), package)
        self.assertTrue((prefix / "bin/qtpaths").is_file())
        self.assertTrue((prefix / "libexec/qmlimportscanner").is_file())
        self.assertTrue((prefix / "share/licenses/qt/manifest.cmake").is_file())
        if sys.platform == "darwin":
            self.assertTrue((prefix / "bin/macdeployqt").is_file())
            deployment = re.search(r"^MACDEPLOYQT_EXECUTABLE:FILEPATH=(.+)$", cache, re.M)
            self.assertIsNotNone(deployment)
            self.assertEqual(Path(deployment.group(1)).resolve(), (prefix / "bin/macdeployqt").resolve())

    def test_external_projects_pin_sources_and_build_order_without_downloading(self):
        with tempfile.TemporaryDirectory() as directory:
            build = Path(directory).resolve() / "build"
            result = run("cmake", "-S", str(RECIPE), "-B", str(build), "-G", "Ninja")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            manifest = (RECIPE / "manifest.cmake").read_text()
            version = re.search(r"set\(TELAR_QT_VERSION ([0-9.]+)\)", manifest).group(1)
            modules = re.findall(r"set\(TELAR_QT_SHA256_(\w+) ([a-f0-9]{64})\)", manifest)
            self.assertEqual(len(modules), 5)
            for module, digest in modules:
                if module == "qtwayland" and sys.platform == "darwin":
                    continue
                metadata = (build / f"{module}-prefix/src/{module}-stamp/{module}-urlinfo.txt").read_text()
                self.assertIn(f"SHA256={digest}", metadata)
                self.assertIn(f"/{module}-everywhere-src-{version}.tar.xz", metadata)
                self.assertIn("https://download.qt.io/", metadata)
            command = (build / "qtbase-prefix/tmp/qtbase-cfgcmd.txt").read_text()
            self.assertIn("-DCMAKE_BUILD_TYPE:STRING=Release", command)
            self.assertIn("-DBUILD_SHARED_LIBS:BOOL=ON", command)
            self.assertIn("-DQT_BUILD_TESTS:BOOL=OFF", command)
            self.assertIn(f"-DCMAKE_PREFIX_PATH:PATH={build}/install", command)
            dependencies = run("ninja", "-C", str(build), "-t", "query", "qtdeclarative")
            self.assertEqual(dependencies.returncode, 0, dependencies.stderr)
            self.assertIn("qtshadertools", dependencies.stdout)
            self.assertFalse((build / "qtbase-prefix/src/qtbase/CMakeLists.txt").exists())

    def test_bootstrap_replaces_system_qt_locations_and_keys_compiler_inputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "fixture"
            source.mkdir()
            runner = root / "cmake-runner"
            runner.write_text(f"#!{sys.executable}\n" + '''import json, os, pathlib, subprocess, sys
args = sys.argv[1:]
if args[:2] == ['-E', 'env']:
    environment = os.environ.copy()
    index = 2
    while '=' in args[index]:
        key, value = args[index].split('=', 1)
        environment[key] = value
        index += 1
    sys.exit(subprocess.call(args[index:], env=environment))
if '-B' in args:
    prefix = pathlib.Path(args[args.index('-B') + 1]) / 'install'
    (prefix / 'lib/cmake/Qt6').mkdir(parents=True, exist_ok=True)
    (prefix.parent / 'arguments.json').write_text(json.dumps(args))
''')
            runner.chmod(0o755)
            (source / "CMakeLists.txt").write_text(f'''cmake_minimum_required(VERSION 3.24)
project(qt_bootstrap_fixture LANGUAGES C CXX)
set(CMAKE_COMMAND "{runner}")
set(CMAKE_C_COMPILER_LAUNCHER "launcher;--option")
include("{BASE / 'cmake/qt.cmake'}")
if(DEFINED Qt6Gui_DIR)
  message(FATAL_ERROR "A stale Qt module escaped cache cleanup")
endif()
if(MIXED_PACKAGE)
  set(Qt6Test_DIR "/unrelated/system/Qt6Test" CACHE PATH "" FORCE)
endif()
telar_verify_qt_packages()
file(WRITE "${{CMAKE_BINARY_DIR}}/selected.txt" "${{TELAR_GUI_QT_PREFIX}}\\n${{Qt6_DIR}}\\n${{QT_ADDITIONAL_PACKAGES_PREFIX_PATH}}")
''')
            build = root / "build"
            command = ("cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
                       f"-DTELAR_GUI_QT_BUILD_DIR={root / 'cache'}", "-DQt6Gui_DIR=/unrelated/system/Qt6Gui")
            result = run(*command)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            selected = (build / "selected.txt").read_text().splitlines()
            self.assertEqual(selected[1], selected[0] + "/lib/cmake/Qt6")
            self.assertEqual(selected[2], selected[0])
            self.assertTrue(Path(selected[0]).is_relative_to(root / "cache"))
            arguments = json.loads((Path(selected[0]).parent / "arguments.json").read_text())
            self.assertIn("-DCMAKE_C_COMPILER_LAUNCHER:STRING=launcher;--option", arguments)
            result = run(*command)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual((build / "selected.txt").read_text().splitlines(), selected)
            result = run(*command, "-DCMAKE_CXX_FLAGS=-DQT_CACHE_INPUT_CHANGED")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotEqual((build / "selected.txt").read_text().splitlines()[0], selected[0])
            result = run(*command, f"-DTELAR_GUI_QT_BUILD_DIR={source / 'nested-cache'}")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must be outside the GUI source tree", result.stdout + result.stderr)
            result = run(*command, "-DMIXED_PACKAGE=ON")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("resolved outside the managed Qt installation", result.stdout + result.stderr)

    def test_security_patch_verification_and_idempotence(self):
        self.exercise_patch(valid_hash=True)

    def test_security_patch_rejects_a_hash_mismatch(self):
        self.exercise_patch(valid_hash=False)

    def exercise_patch(self, valid_hash):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / "source"
            source.mkdir()
            (source / "data.txt").write_text("before\n")
            patch = root / "fix.diff"
            patch.write_text("--- a/data.txt\n+++ b/data.txt\n@@ -1 +1 @@\n-before\n+after\n")
            digest = hashlib.sha256(patch.read_bytes()).hexdigest() if valid_hash else "0" * 64
            shutil.copyfile(RECIPE / "patch.cmake", root / "patch.cmake")
            (root / "manifest.cmake").write_text(f'set(TELAR_QT_PATCH_URL "{patch.as_uri()}")\nset(TELAR_QT_PATCH_SHA256 {digest})\n')
            command = ("cmake", f"-DSOURCE_DIR={source}", f"-DDOWNLOAD_DIR={root / 'downloads'}",
                       f"-DPATCH_EXECUTABLE={shutil.which('patch')}", "-P", str(root / "patch.cmake"))
            result = run(*command)
            self.assertEqual(result.returncode == 0, valid_hash, result.stdout + result.stderr)
            self.assertEqual((source / "data.txt").read_text(), "after\n" if valid_hash else "before\n")
            if valid_hash:
                result = run(*command)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual((source / "data.txt").read_text(), "after\n")

    def test_packaging_rejects_system_or_mixed_qt(self):
        with self.assertRaises(ValueError):
            qt_installation("Qt6Core_DIR:PATH=/system/lib/cmake/Qt6Core\n")
        with self.assertRaises(ValueError):
            qt_installation("TELAR_GUI_QT_PREFIX:INTERNAL=/managed\nQt6Core_DIR:PATH=/system/lib/cmake/Qt6Core\n")
        self.assertEqual(qt_installation("TELAR_GUI_QT_PREFIX:INTERNAL=/managed\nQt6Core_DIR:PATH=/managed/lib/cmake/Qt6Core\n"), Path("/managed").resolve())


if __name__ == "__main__":
    unittest.main()
