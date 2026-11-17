#include <cstdlib>
#include <limits.h>
#include <stdlib.h>
#include <unistd.h>

import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.runtime.terminal.text_reader;
import telar.vocabulary;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  std::span<const Byte> bytes(std::string_view value) {
    return {reinterpret_cast<const Byte*>(value.data()), value.size()};
  }

  std::string query(Terminal& terminal, std::string_view header, std::string_view path) {
    std::string payload((path.size() + 2) / 3 * 4, '\0');

    check(base64::encode(bytes(path), payload).has_value());
    terminal.feed(bytes("\x1b_Ga=q,i=9," + std::string{header} + ";" + payload + "\x1b\\"));
    const auto response = terminal.responses();
    std::string result{reinterpret_cast<const char*>(response.data()), response.size()};

    terminal.consumeResponses(response.size());
    return result;
  }

  void create(const std::filesystem::path& path) {
    std::ofstream file{path, std::ios::binary};

    file.write("\0\0\0\0", 4);
    check(file.good());
  }

  bool temporary(const std::filesystem::path& path) {
    const auto text = path.string();

    for (const std::string_view directory : {"/tmp/", "/private/tmp/", "/dev/shm/"}) {
      if (text.starts_with(directory)) {
        return true;
      }
    }

    return false;
  }

  // A program may name a temporary file for telar to read and delete only inside a temp
  // directory: $TMPDIR counts, and a sibling whose name merely starts with it does not.
  void temporaryFileOutsideTmpRefused() {
    auto pattern = (std::filesystem::current_path() / "telar-tmpdir-XXXXXX").string();

    check(::mkdtemp(pattern.data()) != nullptr);
    const std::filesystem::path directory{pattern};
    const std::filesystem::path sibling{pattern + "x"};

    std::filesystem::create_directory(sibling);
    check(::setenv("TMPDIR", directory.c_str(), 1) == 0);

    const auto inside = directory / "tty-graphics-protocol-x";
    const auto outside = sibling / "tty-graphics-protocol-x";

    create(inside);
    create(outside);

    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};

    check(query(terminal, "t=t,s=1,v=1", inside.string()) == "\x1b_Gi=9;OK\x1b\\");
    check(!std::filesystem::exists(inside));

    const bool testable = !temporary(std::filesystem::canonical(sibling));
    const auto refused = testable ? query(terminal, "t=t,s=1,v=1", outside.string()) : std::string{};
    const bool kept = std::filesystem::exists(outside);

    std::filesystem::remove_all(directory);
    std::filesystem::remove_all(sibling);
    if (!testable) {
      telar::testing::skip("the build directory sits inside a temp directory");
    }

    check(refused == "\x1b_Gi=9;EINVAL: temporary file not in temp dir\x1b\\");
    check(kept);
  }

  const telar::testing::Case case_temporary_file_outside_tmp_refused{"graphics_query.temporary_file_outside_tmp_refused", temporaryFileOutsideTmpRefused};

}
