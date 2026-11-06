#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "../diagnostics/line.hpp"
#include "telar_platform/trace.hpp"
#include "../graphics/kitty_framing.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <array>
#include <cstring>
#include <variant>
#include "../graphics/media_budget.hpp"
#include "../graphics/kitty_control.hpp"
#include <cstddef>
#include <cstdint>
#include <span>
#include <algorithm>
#include "../graphics/child_file.hpp"
#include "telar_platform/graphics/child_shared_memory.hpp"
#include <utility>
#include "../terminal/control/classification.hpp"
#include "../terminal/control/parser.hpp"
#include "../terminal/pty_response_queue.hpp"
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include "../graphics/temporary_path.hpp"
#include <charconv>
#include "../terminal/ghostty_allocator.hpp"
#include "../terminal/ghostty_handle.hpp"
#include <optional>
#include "telar_base/diagnostics/config.hpp"
#include "telar_config/graphics/limits.hpp"
#include <limits>
#include "telar_platform/file_descriptor.hpp"
#include "telar_platform/random_bytes.hpp"
#include "telar_platform/mapped_region.hpp"
#include <cstdio>
#include <cstdlib>
#include <fcntl.h>
#include <string_view>
#include <sys/mman.h>
#include <atomic>
#include "telar_client/serializers/telar_frame.hpp"
#include "cell_layout.hpp"
#include "../terminal/control/engine.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "../terminal/graphics_cursor.hpp"
#include <cassert>
#include "one_shot_allocator.hpp"
#include <source_location>
#include <string>



import telar.runtime.terminal.text_reader;

using namespace telar;
using namespace telar::runtime;

namespace {
constexpr std::size_t memory_limit = 64 * 1024 * 1024;
constexpr std::string_view large_item = ";0=rgb:12/34/56";
constexpr std::size_t large_items = 500;

void require(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    throw std::runtime_error{"Kitty color assertion at line " + std::to_string(location.line())};
  }
}

std::span<const Byte> bytes(std::string_view text) {
  return {reinterpret_cast<const Byte *>(text.data()), text.size()};
}

control::Sequence sequence(std::string_view input, control::Ending ending) {
  return {control::Kind::osc, bytes(input), ending};
}

std::string request(std::size_t count) {
  std::string result = "\x1b]21";
  for (std::size_t index = 0; index < count; ++index) {
    result.append(";0=?");
  }

  return result;
}

std::string expected(std::size_t count, std::string_view ending) {
  std::string result = "\x1b]21";
  for (std::size_t index = 0; index < count; ++index) {
    result.append(large_item);
  }
  result.append(ending);

  return result;
}

std::string drain(PtyResponseQueue &queue, std::size_t fragment = SIZE_MAX) {
  std::string result;
  while (!queue.empty()) {
    const auto available = queue.readable();
    const auto count = std::min(fragment, available.size());
    require(count > 0);
    result.append(reinterpret_cast<const char *>(available.data()), count);
    queue.consume(count);
  }

  return result;
}

template <Allocator Memory>
void channelValues(control::VtState &state, control::ColorQueries<Memory> &colors, control::Reply<Memory> &reply, control::Policy &policy) {
  for (const auto format : {control::ColorFormat::eight_bit, control::ColorFormat::sixteen_bit, control::ColorFormat::none}) {
    policy.color_format = format;
    for (unsigned sample = 0; sample <= UINT8_MAX; ++sample) {
      const unsigned green = UINT8_MAX - sample;
      const unsigned blue = sample ^ 0x55;
      std::array<char, 64> setter;
      const auto length = std::snprintf(setter.data(), setter.size(), "\x1b]4;0;#%02x%02x%02x\x1b\\", sample, green, blue);
      require(length > 0 && static_cast<std::size_t>(length) < setter.size());
      state.write(bytes({setter.data(), static_cast<std::size_t>(length)}));
      for (const auto ending : {control::Ending::bell, control::Ending::escape}) {
        const auto suffix = ending == control::Ending::bell ? "\a" : "\x1b\\";
        std::array<char, 64> answer;
        const auto count = std::snprintf(answer.data(), answer.size(), "\x1b]21;0=rgb:%02x/%02x/%02x%s", sample, green, blue, suffix);
        require(count > 0 && static_cast<std::size_t>(count) < answer.size());
        require(colors.handle(sequence("\x1b]21;0=?", ending), true));
        PtyResponseQueue queue;
        require(reply.publish(queue));
        reply.clear();
        require(drain(queue, 1) == std::string_view{answer.data(), static_cast<std::size_t>(count)});
      }
    }
  }
}

template <Allocator Memory>
void ownedReplies(control::VtState &state, control::ColorQueries<Memory> &colors, control::Reply<Memory> &reply) {
  state.write(bytes("\x1b]4;0;#123456\x1b\\"));
  constexpr auto inline_items = (PtyResponseQueue::message_byte_capacity - std::string_view{"\x1b]21\x1b\\"}.size()) / large_item.size();
  for (const std::size_t count : {std::size_t{1}, inline_items - 1, inline_items, inline_items + 1, inline_items * 2, large_items}) {
    const auto input = request(count);
    for (const auto ending : {control::Ending::bell, control::Ending::escape}) {
      const auto suffix = ending == control::Ending::bell ? "\a" : "\x1b\\";
      require(colors.handle(sequence(input, ending), true));
      PtyResponseQueue queue;
      require(reply.publish(queue));
      reply.clear();
      require(drain(queue, 17) == expected(count, suffix));
    }
  }

  const auto input = request(large_items);
  const auto answer = expected(large_items, "\x1b\\");
  require(colors.handle(sequence(input, control::Ending::escape), true));
  PtyResponseQueue queue;
  constexpr std::string_view held = "held";
  for (std::size_t slot = 0; slot < PtyResponseQueue::message_capacity; ++slot) {
    require(queue.tryPush(bytes(held)));
  }
  require(!reply.publish(queue));

  bool immutable = false;
  try {
    reply.append("invalid mutation");
  } catch (const std::logic_error &) {
    immutable = true;
  }
  require(immutable && reply.size() == answer.size());
  queue.consume(held.size());
  require(reply.publish(queue));
  reply.clear();

  std::string remaining;
  for (std::size_t slot = 1; slot < PtyResponseQueue::message_capacity; ++slot) {
    remaining.append(held);
  }
  remaining.append(answer);
  require(drain(queue, 17) == remaining);
  require(queue.snapshot().dropped == 0);
}

void allocationFailures(control::VtState &state) {
  state.write(bytes("\x1b]4;0;#123456\x1b\\"));
  const auto input = request(large_items);
  const auto answer = expected(large_items, "\x1b\\");
  control_test::OneShotAllocator upstream;
  BudgetAllocator memory{upstream, memory_limit};
  {
    control::Reply reply{memory};
    control::Policy policy;
    control::ColorQueries colors{state, reply, policy};
    PtyResponseQueue queue;
    upstream.failNext();
    bool failed = false;
    try {
      colors.handle(sequence(input, control::Ending::escape), true);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    require(failed && upstream.failures() == 1 && queue.empty());
    reply.discard();
    require(memory.liveBytes() == 0 && upstream.liveBytes() == 0);

    require(colors.handle(sequence(input, control::Ending::escape), true));
    require(reply.size() == answer.size());
    upstream.failNext();
    failed = false;
    try {
      reply.publish(queue);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    require(failed && upstream.failures() == 2 && reply.size() == answer.size() && queue.empty());
    require(reply.publish(queue));
    reply.clear();
    require(drain(queue, 17) == answer);
  }
  require(memory.liveBytes() == 0 && upstream.liveBytes() == 0);
}
} // namespace

int main() {
  SystemAllocator system;
  BudgetAllocator memory{system, memory_limit};
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  control::VtState state;
  // Color getters and non-query color setters only use the borrowed terminal.
  state.bind(terminal.handle(), nullptr, true);
  control::Reply reply{memory};
  control::Policy policy;
  control::ColorQueries colors{state, reply, policy};
  channelValues(state, colors, reply, policy);
  ownedReplies(state, colors, reply);
  allocationFailures(state);
  std::puts("Kitty RGB values, owned replies, queue retry and allocation failures passed");
}
