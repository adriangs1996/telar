#include "graphics/file_input.hpp"
#include "tests/check.hpp"
#include <cstdio>
#include <string>
#include <vector>

using namespace telar;
using namespace telar::runtime;

namespace {
constexpr std::size_t storage_limit = 1024 * 1024;
constexpr std::string_view terminator = "\x1b\\";

struct Sink {
  std::vector<std::pair<char, std::string>> events;

  void ingest(std::span<const std::uint8_t> bytes) {
    events.emplace_back('I', std::string{reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  }

  void ingestEncodedChunk(std::span<const std::uint8_t> bytes) {
    events.emplace_back('E', std::string{reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  }

  void reply(std::span<const std::uint8_t> bytes) {
    events.emplace_back('R', std::string{reinterpret_cast<const char *>(bytes.data()), bytes.size()});
  }
};

void record(const Sink &sink) {
  const auto count = static_cast<std::uint64_t>(sink.events.size());
  check(std::fwrite(&count, sizeof(count), 1, stdout) == 1);
  for (const auto &[kind, bytes] : sink.events) {
    const auto length = static_cast<std::uint64_t>(bytes.size());
    check(std::fwrite(&kind, sizeof(kind), 1, stdout) == 1);
    check(std::fwrite(&length, sizeof(length), 1, stdout) == 1);
    check(std::fwrite(bytes.data(), 1, bytes.size(), stdout) == bytes.size());
  }
}

void frame(std::string_view control, std::string_view payload, bool forwarded) {
  const auto bytes = "\x1b_G" + std::string{control} + ";" + std::string{payload};
  Sink sink;
  GraphicsFileInput::frame({reinterpret_cast<const std::uint8_t *>(bytes.data()), bytes.size()}, terminator, storage_limit, sink);
  if (forwarded) {
    check(sink.events.size() == 1 && sink.events[0].first == 'E');
    check(sink.events[0].second.ends_with(";/wAA/w==\x1b\\"));
  } else {
    check(sink.events.size() == 2);
    check(sink.events[0].first == 'I' && sink.events[0].second == bytes);
    check(sink.events[1].first == 'I' && sink.events[1].second == terminator);
  }
  record(sink);
}
}

int main(int argc, char **argv) {
  check(argc == 2);
  const std::string_view path{argv[1]};
  std::string encoded((path.size() + 2) / 3 * 4, '\0');
  check(base64::encode({reinterpret_cast<const std::uint8_t *>(path.data()), path.size()}, encoded) == encoded.size());
  constexpr std::string_view file_control = "a=T,t=f,f=32,s=1,v=1,i=7";
  frame(file_control, encoded, true);
  for (const auto control : {"a=T,t=d", "a=T,t=s", "a=p,t=f", "a=T,t=f,m=1", "a=T,t=f,O=bad", "a=T,t=f,t=d", "a=T,t=f,"}) {
    frame(control, encoded, false);
  }

  constexpr unsigned byte_values = 256;
  for (unsigned byte = 0; byte < byte_values; ++byte) {
    const std::string payload(257, static_cast<char>(byte));
    frame("a=T,t=d,f=32,s=1,v=1,i=7", payload, false);
    if (!KittyFraming::content(static_cast<std::uint8_t>(byte))) {
      frame(file_control, std::string(1, static_cast<char>(byte)) + encoded, false);
      frame(file_control, encoded + static_cast<char>(byte), false);
    }
  }
  return 0;
}
