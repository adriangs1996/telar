#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cassert>
#include <cstddef>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>

import std;
import telar.base.memory.allocators;
import telar.config.runtime;
import telar.runtime.terminal.control;
import telar.testing.one_shot_allocator;
import telar.runtime.terminal.text_reader;
import telar.vocabulary;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  namespace {
    constexpr std::size_t memory_limit = 64 * 1024 * 1024;
    constexpr std::string_view large_item = ";0=rgb:12/34/56";
    constexpr std::size_t large_items = 500;

    std::span<const Byte> bytes(std::string_view text) {
      return {reinterpret_cast<const Byte*>(text.data()), text.size()};
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

    std::string drain(PtyResponseQueue& queue, std::size_t fragment = SIZE_MAX) {
      std::string result;

      while (!queue.empty()) {
        const auto available = queue.readable();
        const auto count = std::min(fragment, available.size());

        check(count > 0);
        result.append(reinterpret_cast<const char*>(available.data()), count);
        queue.consume(count);
      }

      return result;
    }

    template <Allocator Memory>
    void channelValues(control::VtState& state, control::ColorQueries<Memory>& colors, control::Reply<Memory>& reply, control::Policy& policy) {
      for (const auto format : {control::ColorFormat::eight_bit, control::ColorFormat::sixteen_bit, control::ColorFormat::none}) {
        policy.color_format = format;
        for (unsigned sample = 0; sample <= UINT8_MAX; ++sample) {
          const unsigned green = UINT8_MAX - sample;
          const unsigned blue = sample ^ 0x55;
          std::array<char, 64> setter;
          const auto length = std::snprintf(setter.data(), setter.size(), "\x1b]4;0;#%02x%02x%02x\x1b\\", sample, green, blue);

          check(length > 0 && static_cast<std::size_t>(length) < setter.size());
          state.write(bytes({setter.data(), static_cast<std::size_t>(length)}));
          for (const auto ending : {control::Ending::bell, control::Ending::escape}) {
            const auto suffix = ending == control::Ending::bell ? "\a" : "\x1b\\";
            std::array<char, 64> answer;
            const auto count = std::snprintf(answer.data(), answer.size(), "\x1b]21;0=rgb:%02x/%02x/%02x%s", sample, green, blue, suffix);

            check(count > 0 && static_cast<std::size_t>(count) < answer.size());
            check(colors.handle({state, reply, policy}, sequence("\x1b]21;0=?", ending), true));
            PtyResponseQueue queue;

            check(reply.publish(queue));
            reply.clear();
            check(drain(queue, 1) == std::string_view{answer.data(), static_cast<std::size_t>(count)});
          }
        }
      }
    }

    template <Allocator Memory>
    void ownedReplies(control::VtState& state, control::ColorQueries<Memory>& colors, control::Reply<Memory>& reply, const control::Policy& policy) {
      state.write(bytes("\x1b]4;0;#123456\x1b\\"));
      constexpr auto inline_items = (PtyResponseQueue::message_byte_capacity - std::string_view{"\x1b]21\x1b\\"}.size()) / large_item.size();

      for (const std::size_t count : {std::size_t{1}, inline_items - 1, inline_items, inline_items + 1, inline_items * 2, large_items}) {
        const auto input = request(count);

        for (const auto ending : {control::Ending::bell, control::Ending::escape}) {
          const auto suffix = ending == control::Ending::bell ? "\a" : "\x1b\\";

          check(colors.handle({state, reply, policy}, sequence(input, ending), true));
          PtyResponseQueue queue;

          check(reply.publish(queue));
          reply.clear();
          check(drain(queue, 17) == expected(count, suffix));
        }
      }

      const auto input = request(large_items);
      const auto answer = expected(large_items, "\x1b\\");

      check(colors.handle({state, reply, policy}, sequence(input, control::Ending::escape), true));
      PtyResponseQueue queue;
      constexpr std::string_view held = "held";

      for (std::size_t slot = 0; slot < PtyResponseQueue::message_capacity; ++slot) {
        check(queue.tryPush(bytes(held)));
      }

      check(!reply.publish(queue));

      bool immutable = false;

      try {
        reply.append("invalid mutation");
      } catch (const std::logic_error&) {
        immutable = true;
      }

      check(immutable && reply.size() == answer.size());
      queue.consume(held.size());
      check(reply.publish(queue));
      reply.clear();

      std::string remaining;

      for (std::size_t slot = 1; slot < PtyResponseQueue::message_capacity; ++slot) {
        remaining.append(held);
      }

      remaining.append(answer);
      check(drain(queue, 17) == remaining);
      check(queue.snapshot().dropped == 0);
    }

    void allocationFailures(control::VtState& state) {
      state.write(bytes("\x1b]4;0;#123456\x1b\\"));
      const auto input = request(large_items);
      const auto answer = expected(large_items, "\x1b\\");
      control_test::OneShotAllocator upstream;
      BudgetAllocator budget{upstream, memory_limit};
      SynchronizedAllocator synchronized{budget};
      MemoryAdapter adapter{synchronized};
      ConcurrentMemory& memory = adapter;

      {
        control::Reply reply{memory};
        control::Policy policy;
        control::ColorQueries<std::remove_cvref_t<ConcurrentMemory>> colors;
        PtyResponseQueue queue;

        upstream.failNext();
        bool failed = false;

        try {
          colors.handle({state, reply, policy}, sequence(input, control::Ending::escape), true);
        } catch (const std::bad_alloc&) {
          failed = true;
        }

        check(failed && upstream.failures() == 1 && queue.empty());
        reply.discard();
        check(budget.liveBytes() == 0 && upstream.liveBytes() == 0);

        check(colors.handle({state, reply, policy}, sequence(input, control::Ending::escape), true));
        check(reply.size() == answer.size());
        upstream.failNext();
        failed = false;
        try {
          reply.publish(queue);
        } catch (const std::bad_alloc&) {
          failed = true;
        }

        check(failed && upstream.failures() == 2 && reply.size() == answer.size() && queue.empty());
        check(reply.publish(queue));
        reply.clear();
        check(drain(queue, 17) == answer);
      }

      check(budget.liveBytes() == 0 && upstream.liveBytes() == 0);
    }
  } // namespace

  // Each case reads and sets colors on a terminal of its own, through the state, reply and policy
  // a control engine would pass.
  template <auto body>
  void withColors() {
    SystemAllocator system;
    BudgetAllocator budget{system, memory_limit};
    SynchronizedAllocator synchronized{budget};
    MemoryAdapter adapter{synchronized};
    ConcurrentMemory& memory = adapter;
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
    control::VtState state;

    // Color getters and non-query color setters only use the borrowed terminal.
    state.bind(terminal.handle(), nullptr, true);
    control::Reply reply{memory};
    control::Policy policy;
    control::ColorQueries<std::remove_cvref_t<ConcurrentMemory>> colors;

    body(state, colors, reply, policy);
  }

  const telar::testing::Case case_channel_values{
      "control_kitty_colors.channel_values",
      withColors<[](auto& state, auto& colors, auto& reply, auto& policy) {
        channelValues(state, colors, reply, policy);
      }>,
  };
  const telar::testing::Case case_owned_replies{
      "control_kitty_colors.owned_replies",
      withColors<[](auto& state, auto& colors, auto& reply, auto& policy) {
        ownedReplies(state, colors, reply, policy);
      }>,
  };
  const telar::testing::Case case_allocation_failures{
      "control_kitty_colors.allocation_failures",
      withColors<[](auto& state, auto&, auto&, auto&) {
        allocationFailures(state);
      }>,
  };

}
