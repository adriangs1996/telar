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

  std::string reply(Terminal& terminal, std::string_view header, std::string_view payload) {
    terminal.feed(bytes("\x1b_Ga=q,i=9," + std::string{header} + ";" + std::string{payload} + "\x1b\\"));
    const auto response = terminal.responses();
    std::string result{reinterpret_cast<const char*>(response.data()), response.size()};

    terminal.consumeResponses(response.size());
    return result;
  }

  std::string query(Terminal& terminal, std::string_view header, std::string_view path) {
    std::string payload((path.size() + 2) / 3 * 4, '\0');

    check(base64::encode(bytes(path), payload).hasValue());
    return reply(terminal, header, payload);
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

  constexpr std::string_view invalid_data = "\x1b_Gi=9;EINVAL: invalid data\x1b\\";

  // `O` and `S` select a range of a file the program names. A range past the end of the
  // file, or longer than an image can be, is refused before telar reads or allocates it.
  void fileRangeBounds() {
    auto pattern = (std::filesystem::temp_directory_path() / "telar-range-XXXXXX").string();

    check(::mkdtemp(pattern.data()) != nullptr);
    const std::filesystem::path directory{pattern};
    const auto path = directory / "image";

    {
      std::ofstream file{path, std::ios::binary};

      file.write("\1\2\3\4\0\0\0\0", 8);
      check(file.good());
    }

    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
    const auto inside = query(terminal, "t=f,O=4,S=4,s=1,v=1", path.string());
    const auto past_end = query(terminal, "t=f,O=4,S=8,s=1,v=1", path.string());
    const auto offset_past_end = query(terminal, "t=f,O=9,s=1,v=1", path.string());
    const auto huge = query(terminal, "t=f,S=4294967295,s=1,v=1", path.string());

    std::filesystem::remove_all(directory);
    check(inside == "\x1b_Gi=9;OK\x1b\\");
    check(past_end == invalid_data);
    check(offset_past_end == invalid_data);
    check(huge == invalid_data);
  }

  // A query answers what the backend would do with the same upload, so a program learns
  // an image is unusable before it sends it.
  void validationReplies() {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
    constexpr std::string_view pixel = "AAAAAA==";
    const std::pair<std::string_view, std::string_view> cases[]{
        {"f=99,s=1,v=1", "EINVAL: unsupported format"},
        {"s=10001,v=1", "EINVAL: dimensions too large"},
        {"s=0,v=1", "EINVAL: dimensions required"},
        {"s=1,v=0", "EINVAL: dimensions required"},
        {"s=10000,v=10000", "EINVAL: dimensions too large"},
        {"s=1,v=1", "OK"},
        {"s=2,v=1", "EINVAL: invalid data"},
    };

    for (const auto& [header, result] : cases) {
      check(reply(terminal, header, pixel) == "\x1b_Gi=9;" + std::string{result} + "\x1b\\", header);
    }

    // A corrupt PNG, and a zlib stream that does not inflate, are refused; a valid stream
    // of the declared size is accepted.
    check(reply(terminal, "f=100", "iVBORw0KGgpnYXJiYWdlIQ==") == invalid_data);
    check(reply(terminal, "s=1,v=1,o=z", "bm90IHpsaWI=") == "\x1b_Gi=9;EINVAL: decompression failed\x1b\\");
    check(reply(terminal, "s=1,v=1,o=z", "eJxjYGBgAAAABAAB") == "\x1b_Gi=9;OK\x1b\\");
  }

  const telar::testing::Case case_temporary_file_outside_tmp_refused{"graphics_query.temporary_file_outside_tmp_refused", temporaryFileOutsideTmpRefused};
  const telar::testing::Case case_file_range_bounds{"graphics_query.file_range_bounds", fileRangeBounds};
  const telar::testing::Case case_validation_replies{"graphics_query.validation_replies", validationReplies};

}
