#include "terminal/terminal.hpp"
#include "graphics/png_decoder.hpp"
#include "graphics/shared_image_storage.hpp"
#include "check.hpp"
#include <filesystem>
#include <fstream>
#include <zlib.h>

using namespace telar;
using namespace telar::runtime;

namespace {
std::span<const Byte> bytes(std::string_view value) {
  return {reinterpret_cast<const Byte *>(value.data()), value.size()};
}

std::string encoded(std::span<const Byte> raw, bool padded = true) {
  std::string result((raw.size() + 2) / 3 * 4, '\0');
  check(base64::encode(raw, result).has_value());
  if (!padded) {
    while (!result.empty() && result.back() == '=') {
      result.pop_back();
    }
  }
  return result;
}

std::string query(auto &terminal, std::string_view header, std::string_view payload) {
  const auto request = "\x1b_Ga=q,i=9," + std::string{header} + ";" + std::string{payload} + "\x1b\\";
  terminal.feed(bytes(request));
  std::string result;
  while (!terminal.responses().empty()) {
    const auto response = terminal.responses();
    result.append(reinterpret_cast<const char *>(response.data()), response.size());
    terminal.consumeResponses(response.size());
  }
  return result;
}

void localMedia(auto &memory) {
  std::array<char, 64> directory;
  std::strcpy(directory.data(), "/tmp/telar-control-graphics-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const std::filesystem::path root{directory.data()};
  const auto path = (root / "tty-graphics-protocol-image").string();
  const auto wrong = (root / "ordinary-file").string();
  for (const auto &target : {path, wrong}) {
    std::ofstream file{target, std::ios::binary};
    file.write("\0\0\0\0", 4);
    check(file.good());
  }
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  check(query(terminal, "t=f,s=1,v=1", encoded(bytes(path), false)) == "\x1b_Gi=9;OK\x1b\\");
  check(std::filesystem::exists(path));
  check(query(terminal, "t=t,s=1,v=1", encoded(bytes(wrong))) == "\x1b_Gi=9;EINVAL: temporary file not named correctly\x1b\\");
  check(std::filesystem::exists(wrong));
  std::filesystem::create_symlink(path, root / "symlink");
  check(::mkfifo((root / "pipe").c_str(), 0600) == 0);
  for (const auto &invalid : {(root / "symlink").string(), (root / "pipe").string(), root.string(), std::string{"relative"}, std::string{"/tmp/a\0b", 8}}) {
    check(query(terminal, "t=f,s=1,v=1", encoded(bytes(invalid))) == "\x1b_Gi=9;EINVAL: invalid data\x1b\\");
  }
  check(query(terminal, "t=t,s=1,v=1", encoded(bytes(path))) == "\x1b_Gi=9;OK\x1b\\");
  check(!std::filesystem::exists(path));
  auto storage = SharedImageStorage::create(4);
  check(storage.has_value());
  std::ranges::fill(storage->mapping().bytes(), 0);
  const auto shared_name = storage->takeName();
  check(query(terminal, "t=s,s=1,v=1", encoded(bytes(shared_name.data()), false)) == "\x1b_Gi=9;OK\x1b\\");
  FileDescriptor reopened{::shm_open(shared_name.data(), O_RDONLY, 0)};
  check(!reopened && errno == ENOENT);
  std::filesystem::remove_all(root);
}

void configuredLimits(auto &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, {}, GraphicsLimits{.pane_bytes = 128 * 1024}};
  std::vector<Byte> raw(256 * 256 * 4, 0);
  check(query(terminal, "s=256,v=256", encoded(raw)) == "\x1b_Gi=9;ENOMEM: out of memory\x1b\\");
  std::vector<Byte> compressed(::compressBound(raw.size()));
  auto length = static_cast<uLongf>(compressed.size());
  check(::compress(compressed.data(), &length, raw.data(), raw.size()) == Z_OK);
  compressed.resize(length);
  check(query(terminal, "s=256,v=256,o=z", encoded(compressed)) == "\x1b_Gi=9;EINVAL: dimensions too large\x1b\\");
  check(query(terminal, "s=1,v=1", "AAAAAA==") == "\x1b_Gi=9;OK\x1b\\");
}
}

int main() {
  installPngDecoder();
  SystemAllocator system;
  BudgetAllocator memory{system, 64 * 1024 * 1024};
  localMedia(memory);
  configuredLimits(memory);
  check(memory.liveBytes() == 0);
  std::puts("Native graphics query file, shared memory and budget tests passed");
}
