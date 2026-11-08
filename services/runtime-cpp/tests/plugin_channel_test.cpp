#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include <cstdint>
#include <cstddef>
#include <cstring>
#include <cassert>
#include <cerrno>

import std;
import telar.base.memory;
import telar.client.protocol;
import telar.runtime.tests.check;
import telar.runtime.plugins.worker;

using namespace telar;
using namespace telar::runtime;
namespace tap = telar::runtime::plugins;

class FragmentedPipe {
public:
  explicit FragmentedPipe(std::span<const Byte> input, std::size_t fragment) noexcept
      : input_(input), fragment_(fragment) {}

  StreamResult read(std::span<Byte> destination) noexcept {
    if (input_.empty()) {
      return {StreamResult::State::ended};
    }
    const auto count = std::min({input_.size(), fragment_, destination.size()});
    std::copy_n(input_.begin(), count, destination.begin());
    input_ = input_.subspan(count);
    return {StreamResult::State::data, count};
  }

  void write(std::span<const Byte> prefix, std::span<const Byte> payload) {
    written.insert(written.end(), prefix.begin(), prefix.end());
    written.insert(written.end(), payload.begin(), payload.end());
  }

  std::vector<Byte> written;

private:
  std::span<const Byte> input_;
  std::size_t fragment_;
};

void testPluginChannel() {
  SystemAllocator system;
  BudgetAllocator memory{system, 2 * 1024 * 1024};
  for (const std::size_t size : {1, 255, 16384, 16385, 65536}) {
    std::vector<Byte> payload(size);
    for (std::size_t index = 0; index < size; ++index) {
      payload[index] = static_cast<Byte>(index);
    }
    FragmentedPipe outgoing{{}, 1};
    tap::FrameChannel writer{outgoing};
    writer.send(payload);
    writer.send(payload);
    check(outgoing.written.size() == 2 * (size + tap::Protocol::prefix_bytes));

    for (const std::size_t fragment : {1, 7, 16384, 65536}) {
      FragmentedPipe incoming{outgoing.written, fragment};
      tap::FrameChannel reader{incoming};
      for (unsigned frame = 0; frame < 2; ++frame) {
        auto received = reader.receive(memory, tap::Limits::frame_bytes);
        check(received && std::ranges::equal(received->bytes(), payload));
      }
      check(!reader.receive(memory, tap::Limits::frame_bytes));
      check(memory.liveBytes() == 0);
    }
  }

  for (std::uint32_t length : {0u, static_cast<std::uint32_t>(tap::Limits::frame_bytes + 1)}) {
    std::array<Byte, 4> prefix;
    std::span<Byte> destination{prefix};
    LittleEndian<std::uint32_t>::encode(length, destination);
    FragmentedPipe input{prefix, 1};
    tap::FrameChannel reader{input};
    bool rejected = false;
    try {
      reader.receive(memory, tap::Limits::frame_bytes);
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected && memory.liveBytes() == 0);
  }

  const std::array<Byte, 6> truncated{4, 0, 0, 0, 1, 2};
  FragmentedPipe input{truncated, 1};
  tap::FrameChannel reader{input};
  bool rejected = false;
  try {
    reader.receive(memory, tap::Limits::frame_bytes);
  } catch (const SystemError &error) {
    rejected = error.code() == EPIPE;
  }
  check(rejected && memory.liveBytes() == 0);
}
