#include "graphics/media_terminal.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "tests/check.hpp"
#include <chrono>
#include <cstdio>
#include <string>
#include <vector>

using namespace telar;
using namespace telar::runtime;

namespace {
constexpr TerminalSize size{82, 21, 18, 40};
constexpr std::size_t warmup = 100;
constexpr std::size_t benchmark_rows = 64;
constexpr std::size_t output_capacity = 4096;

void record(std::span<const Byte> bytes) {
  const auto length = static_cast<std::uint64_t>(bytes.size());
  check(std::fwrite(&length, sizeof(length), 1, stdout) == 1);
  check(std::fwrite(bytes.data(), 1, bytes.size(), stdout) == bytes.size());
}

template <typename Message>
void message(const Message &value) {
  std::array<Byte, output_capacity> buffer;
  record(Codec::encode(value, buffer));
}

std::string snapshot(MediaTerminal<SystemAllocator> &terminal) {
  terminal.refresh();
  const GraphicsHeader header{1, terminal.graphics.revision() + 1};
  message(GraphicsSnapshot{header, SnapshotPhase::begin});
  for (const auto &image : terminal.graphics.images()) {
    message(GraphicsImage{header, image.description});
    message(GraphicsImageChunk{header, image.description.key, 0, image.pixels});
  }

  for (const auto &placement : terminal.graphics.placements()) {
    message(GraphicsPlacementMessage{header, placement});
  }

  message(GraphicsSnapshot{header, SnapshotPhase::end});
  std::string responses;
  while (!terminal.responses().empty()) {
    const auto next = terminal.responses();
    responses.append(textView(next));
    terminal.consumeResponses(next.size());
  }

  record(byteView(responses));
  const auto limits = terminal.takeUploadLimits();
  const std::array<Byte, 3> flags{limits.bytes, limits.chunks, terminal.responseFailed()};
  record(flags);
  return responses;
}

std::string corpus(std::string_view name) {
  std::string result;
  for (std::size_t row = 0; row < benchmark_rows; ++row) {
    if (name == "ascii") {
      result += "ordinary terminal output with enough text to wrap a row\r\n";
    } else if (name == "ansi") {
      for (unsigned color = 0; color < 8; ++color) {
        result += "\x1b[38;5;" + std::to_string(color) + "mabc\x1b[0m";
      }
      result += "\r\n";
    } else if (name == "osc") {
      result += "\x1b]8;;https://example.test/path\x1b\\link\x1b]8;;\x1b\\\r\n";
    } else {
      check(name == "graphics");
      result += "\x1b_Ga=T,f=32,s=1,v=1,i=7,C=1,q=2;/wAA/w==\x1b\\\r\n";
    }
  }
  return result;
}

void verify(bool transient) {
  const std::vector<std::string> parts{
      corpus("ascii"), corpus("ansi"), corpus("osc"),
      "\x1b_Ga=t,f=32,s=1,v=1,i=7,m=1,q=2;/wAA\x1b\\",
      "\x1b[2;5H\x1b_Gm=0;/w==\x1b\\\x1b_Ga=p,i=7,C=1;\x1b\\",
      "\x1b[?1049h\x1b_Ga=T,f=32,s=1,v=1,i=9,C=1;AAAA/w==\x1b\\",
      "\x1b[?1049l\x1b]0;title\a\x1b[6n\x1b_Ga=q,i=10;\x1b\\",
      "\x1bPqpayload\x1b_Ga=p,i=7;\x1b\\",
      "\x1b_Ga=t,f=32,s=1,v=1,i=8;invalid\x18\x1b_Ga=p,i=7;\x1b\\",
      "\x1b_Ga=t,t=f,f=32,s=1,v=1,i=12;L3RlbGFyLW5vLXN1Y2gtZmlsZQ==\x1b\\",
      "\x1b_Ga=d,d=I,i=7;\x1b\\\x1b[?1049h\x1b_Ga=d,d=A;\x1b\\",
  };
  const std::array<std::string_view, 11> replies{
      "", "", "", "",
      "\x1b_Gi=7;OK\x1b\\",
      "\x1b_Gi=9;OK\x1b\\",
      "",
      "\x1b_Gi=7;OK\x1b\\",
      "\x1b_Gi=8;EINVAL: invalid data\x1b\\\x1b_Gi=7;OK\x1b\\",
      "\x1b_Gi=12;EINVAL: unsupported medium\x1b\\",
      "",
  };
  check(parts.size() == replies.size());
  SystemAllocator memory;
  for (const auto chunk : {1U, 2U, 3U, 7U, 31U, 4096U}) {
    MediaTerminal terminal{memory, size, GraphicsLimits{}};
    for (std::size_t index = 0; index < parts.size(); ++index) {
      const auto &part = parts[index];
      auto remaining = byteView(part);
      while (!remaining.empty()) {
        const auto count = std::min<std::size_t>(chunk, remaining.size());
        if (transient) {
          std::string temporary{textView(remaining.first(count))};
          terminal.feed(byteView(temporary));
          volatile char *poison = temporary.data();
          for (std::size_t byte = 0; byte < temporary.size(); ++byte) {
            poison[byte] = '?';
          }
        } else {
          terminal.feed(remaining.first(count));
        }

        remaining = remaining.subspan(count);
      }
      check(snapshot(terminal) == replies[index]);
    }
  }
}

void benchmark(std::string_view name, std::size_t iterations) {
  const auto input = corpus(name);
  SystemAllocator memory;
  MediaTerminal terminal{memory, size, GraphicsLimits{}};
  for (std::size_t index = 0; index < warmup; ++index) {
    terminal.feed(byteView(input));
  }

  const auto started = std::chrono::steady_clock::now();
  for (std::size_t index = 0; index < iterations; ++index) {
    terminal.feed(byteView(input));
  }

  const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
  terminal.refresh();
  std::printf("{\"case\":\"%.*s\",\"iterations\":%zu,\"bytes_per_iteration\":%zu,\"elapsed_ns\":%lld,\"images\":%zu,\"placements\":%zu}\n",
              static_cast<int>(name.size()), name.data(), iterations, input.size(), static_cast<long long>(elapsed),
              terminal.graphics.images().size(), terminal.graphics.placements().size());
}
}

int main(int argc, char **argv) {
  try {
    check(argc == 2 || argc == 3);
    const std::string_view name{argv[1]};
    if (name == "verify" || name == "verify-transient") {
      verify(name == "verify-transient");
    } else {
      check(argc == 3);
      std::size_t iterations = 0;
      const std::string_view count{argv[2]};
      const auto parsed = std::from_chars(count.data(), count.data() + count.size(), iterations);
      check(parsed.ec == std::errc{} && parsed.ptr == count.data() + count.size() && iterations > 0);
      benchmark(name, iterations);
    }
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "%s\n", error.what());
    return 1;
  }
}
