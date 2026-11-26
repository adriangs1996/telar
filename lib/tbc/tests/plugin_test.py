"""End-to-end tests for the tbc Clang compiler plugin (tbc-plugin.so)."""

from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest

PLUGIN = Path(sys.argv[1]).resolve()
LINTER = Path(sys.argv[2]).resolve()
INCLUDE = Path(sys.argv[3]).resolve()
SYSROOT = sys.argv[4]
COMPILER = Path(sys.argv[5]).resolve()
del sys.argv[1:]


def dedent(text):
    return textwrap.dedent(text).lstrip("\n")


class PluginTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)

    def tearDown(self):
        self.directory.cleanup()

    def base_flags(self, lang="c++"):
        flags = [f"-I{INCLUDE}", f"-I{self.root}"]
        if lang == "c++":
            flags.insert(0, "-std=c++23")
        else:
            flags.insert(0, "-std=c17")
        if SYSROOT:
            flags += ["-isysroot", SYSROOT]
        return flags

    def compile(self, source, output, *, plugin_args=(), extra=(), lang="c++"):
        compiler = COMPILER if lang == "c" else COMPILER.with_name("clang++")
        cmd = [
            str(compiler),
            *self.base_flags(lang),
            "-Wall",
            "-Wextra",
            "-Werror",
            f"-fplugin={PLUGIN}",
            *(f"-fplugin-arg-tbc-{arg}" for arg in plugin_args),
            *extra,
            "-c",
            str(source),
            "-o",
            str(output),
        ]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=60)

    def write(self, name, text):
        path = self.root / name
        path.write_text(dedent(text))
        return path

    def test_dangling_borrow_halts_compilation(self):
        source = self.write("dangling.cpp", """
            #include <string>
            #include <string_view>

            std::string_view bad() {
              std::string local = "hello";
              return local;
            }
            """)
        obj = self.root / "dangling.o"
        result = self.compile(source, obj, plugin_args=("warnings-as-errors",))
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("tbc-dangling-borrow", result.stderr)
        self.assertFalse(obj.exists())

    def test_custom_attributes_in_cpp23_modules_and_import(self):
        mod = self.write("demo.cppm", """
            export module demo;

            export class [[tbc::shared]] Cache {
            public:
              [[tbc::hot_path]] inline int next() const {
                return ++count_;
              }

            private:
              mutable int count_ = 0;
            };

            export template <typename T>
            [[tbc::generic]] T identity(T value) {
              return value;
            }

            export extern "C" [[tbc::raw]] int* foreignRaw(const int* seed);
            """)
        pcm = self.root / "demo.pcm"
        mod_obj = self.root / "demo.o"
        built = self.compile(
            mod,
            mod_obj,
            plugin_args=("checks=lifetime,interface-bodies", "warnings-as-errors"),
            extra=(f"-fmodule-output={pcm}",),
        )
        self.assertEqual(built.returncode, 0, built.stderr)
        self.assertTrue(pcm.exists())
        self.assertTrue(mod_obj.exists())

        consumer = self.write("use.cpp", """
            import demo;

            int useCache(const Cache& cache) {
              return cache.next() + identity(1);
            }

            int* useRaw(const int& value) {
              return foreignRaw(&value);
            }
            """)
        for checks in ("lifetime", "none"):
            result = self.compile(
                consumer,
                self.root / f"use_{checks}.o",
                plugin_args=(f"checks={checks}", "warnings-as-errors"),
                extra=(f"-fmodule-file=demo={pcm}",),
            )
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_interface_bodies_rejects_unmarked_body(self):
        mod = self.write("bad_iface.cppm", """
            export module bad_iface;

            export int bodyInInterface(int value) {
              return value + 1;
            }
            """)
        result = self.compile(
            mod,
            self.root / "bad_iface.o",
            plugin_args=("checks=interface-bodies", "warnings-as-errors"),
            extra=(f"-fmodule-output={self.root / 'bad_iface.pcm'}",),
        )
        self.assertNotEqual(result.returncode, 0, result.stderr)
        self.assertIn("tbc-interface-body", result.stderr)

    def test_custom_outlives_swaps_and_uninitialized_attributes(self):
        source = self.write("contracts.cpp", """
            #include <tbc/view.hpp>
            #include <span>
            #include <string_view>
            #include <vector>

            [[tbc_outlives("b", "a")]]
            tbc::val_a<std::string_view> pick(tbc::val_b<std::string_view> longer, tbc::val_a<std::string_view> shorter, bool flag) {
              return flag ? longer : shorter;
            }

            struct Buf {
              std::vector<int> data;
              [[tbc::swaps]] void exchange(Buf& other);
            };

            int swapOk() {
              Buf a{{1, 2}};
              Buf b{{3, 4}};
              const int* p = a.data.data();
              a.exchange(b);
              return *p;
            }

            [[tbc::uninitialized]] std::span<int> allocRaw();
            [[tbc::initializes]] void fillRaw(std::span<int> dst);

            int initOk() {
              auto buf = allocRaw();
              fillRaw(buf);
              if (!buf.empty()) {
                return buf[0];
              }
              return 0;
            }
            """)
        result = self.compile(source, self.root / "contracts.o", plugin_args=("checks=lifetime,bounds", "warnings-as-errors"))
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_scope_restricts_checks_to_listed_sources(self):
        bad = self.write("excluded.cpp", """
            #include <vector>

            int bad() {
              std::vector<int> values{1, 2};
              const int* elem = values.data();
              values.push_back(3);
              return *elem;
            }
            """)
        scope = self.write("scope.txt", str(self.root / "other.cpp") + "\n")
        result = self.compile(
            bad,
            self.root / "excluded.o",
            plugin_args=("checks=lifetime", f"scope=lifetime={scope}", "warnings-as-errors"),
        )
        self.assertEqual(result.returncode, 0, result.stderr)

        included_scope = self.write("scope_included.txt", str(bad.resolve()) + "\n")
        checked = self.compile(
            bad,
            self.root / "included.o",
            plugin_args=("checks=lifetime", f"scope=lifetime={included_scope}", "warnings-as-errors"),
        )
        self.assertNotEqual(checked.returncode, 0, checked.stderr)
        self.assertIn("tbc-invalidated-borrow", checked.stderr)

    def test_pure_c_gnu_attribute_supported(self):
        cfile = self.write("ffi.c", """
            __attribute__((tbc_raw)) int ffiCall(const char* path) {
              return path != 0;
            }
            """)
        result = self.compile(cfile, self.root / "ffi.o", plugin_args=("warnings-as-errors",), lang="c")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_standalone_linter_strips_plugin_flags(self):
        source = self.write("clean.cpp", """
            class [[tbc::shared]] Shared {
            public:
              int next() const { return ++n_; }
            private:
              mutable int n_ = 0;
            };
            """)
        result = subprocess.run(
            [
                str(LINTER),
                "--warnings-as-errors",
                "--checks=lifetime",
                str(source),
                "--",
                *self.base_flags(),
                f"-fplugin={PLUGIN}",
                "-fplugin-arg-tbc-checks=lifetime",
                "-fplugin-arg-tbc-warnings-as-errors",
            ],
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
