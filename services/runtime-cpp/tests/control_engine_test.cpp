#include "terminal/terminal.hpp"
#include "graphics/media_terminal.hpp"
#include "one_shot_allocator.hpp"
#include <cstdio>
#include <cstring>
#include <source_location>
#include <stdexcept>
#include <string>
#include <type_traits>

using namespace telar;
using namespace telar::runtime;
using namespace std::literals;

void testPtyResponseQueue();

namespace {
// The pinned VT Page.zig bounds retained suffix codepoints to this value.
constexpr unsigned retained_grapheme_points = 64;

void require(bool condition, std::source_location location = std::source_location::current()) {
  if (!condition) {
    throw std::runtime_error{std::string{"Control engine assertion failed at "} + location.file_name() + ":" + std::to_string(location.line())};
  }
}

std::span<const Byte> bytes(std::string_view value) {
  return {reinterpret_cast<const Byte *>(value.data()), value.size()};
}

template <typename TerminalType>
std::string drain(TerminalType &terminal, std::size_t fragment = SIZE_MAX) {
  std::string result;
  while (!terminal.responses().empty()) {
    const auto pending = terminal.responses();
    const auto count = std::min(fragment, pending.size());
    result.append(reinterpret_cast<const char *>(pending.data()), count);
    terminal.consumeResponses(count);
  }
  return result;
}

template <Allocator Memory>
void streamOrder(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 0, 0}, TerminalPurpose::separate_media};
  terminal.feed(bytes("abc\x1b[6n\x1b[5;9H\x1b[6n"));
  require(drain(terminal) == "\x1b[1;4R\x1b[5;9R");
  terminal.feed(bytes("\x1b[18t\x1b[19t\x1b[16t"));
  require(drain(terminal) == "\x1b[8;24;80t\x1b[9;24;80t\x1b[6;0;0t");

  terminal.controlPolicy().title_report = true;
  terminal.feed(bytes("\x1b]2;Títulø界\x1b\\\x1b[21t"));
  require(drain(terminal) == "\x1b]lTítulø界\x1b\\");
  terminal.controlPolicy().title_report = false;
  terminal.feed(bytes("\x1b[21t"));
  require(drain(terminal).empty());

  terminal.controlPolicy().checksum_report = true;
  terminal.feed(bytes("\x1b" "cHello\x1b[7;1;1;1;1;5*y"));
  require(drain(terminal) == "\x1bP7!~FE0C\x1b\\");
  terminal.controlPolicy().checksum_report = false;
  terminal.feed(bytes("\x1b[7;1;1;1;1;5*y"));
  require(drain(terminal).empty());
}

template <Allocator Memory>
void cursorRequestVariants(Memory &memory) {
  struct Query {
    std::string_view body;
    std::string_view reply;
  };
  constexpr Query queries[]{
      {"6n", "\x1b[2;3R"},
      {"06n", "\x1b[2;3R"},
      {"6;n", "\x1b[2;3R"},
      {"?6n", "\x1b[?2;3;1R"},
      {"?06n", "\x1b[?2;3;1R"},
      {"?6;n", "\x1b[?2;3;1R"},
      {"6;0n", ""},
      {"6;;n", ""},
      {";6n", ""},
      {"6:0n", ""},
      {"?6;0n", ""},
      {"?6;;n", ""},
      {"?;6n", ""},
      {"?6:0n", ""},
      {">6n", ""},
  };
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  Terminal observer{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::observation};
  for (const auto setup : {"", "\x1b[3;20r\x1b[?69h\x1b[5;60s\x1b[?6h", "\x1b[?1049h"}) {
    for (const auto query : queries) {
      const auto input = std::string{"\x1b" "c"} + setup + "\x1b[2;3H\x1b[" + std::string{query.body};
      for (std::size_t split = 0; split <= input.size(); ++split) {
        terminal.feed(bytes(std::string_view{input}.substr(0, split)));
        terminal.feed(bytes(std::string_view{input}.substr(split)));
        require(drain(terminal, 1) == query.reply);
      }

      for (const auto byte : input) {
        terminal.feed(bytes(std::string_view{&byte, 1}));
      }
      require(drain(terminal, 1) == query.reply);
      observer.feed(bytes(input));
      require(drain(observer).empty());
    }
  }
}

template <Allocator Memory>
void ordinaryControlBoundaries(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  struct Prefix {
    std::string_view input;
    unsigned columns;
  };
  constexpr Prefix prefixes[]{
      {"", 0},
      {"\x1b]2;title\x1b\\", 0},
      {"\x1b]2;title\a", 0},
      {"\x1b]2;aborted\x18", 0},
      {"\x1bPignored\x1b\\", 0},
      {"\x1bPaborted\x18", 0},
      {"\x1b_ignored\x1b\\", 0},
      {"\x1b_aborted\x18", 0},
      {"\x1b[1;32m", 0},
      {"\xc2\x9b", 0},
      {"\x9b", 1},
      {"\x90", 1},
  };
  constexpr std::string_view incomplete[]{"\xc2", "\xe2", "\xe2\x82", "\xf0", "\xf0\x9f", "\xf0\x9f\x92"};
  for (const auto prefix : prefixes) {
    for (const auto pending : incomplete) {
      for (const char control : {'\n', '\r', '\0'}) {
        auto input = std::string{"\x1b" "c"};
        input.append(prefix.input);
        input.append(pending);
        input.push_back(control);
        input.append("\x1b[6n");
        const auto expected = control == '\r' ? std::string{"\x1b[1;1R"} : std::string{control == '\n' ? "\x1b[2;" : "\x1b[1;"} + std::to_string(prefix.columns + 2) + "R";
        for (std::size_t split = 0; split <= input.size(); ++split) {
          terminal.feed(bytes(std::string_view{input}.substr(0, split)));
          terminal.feed(bytes(std::string_view{input}.substr(split)));
          require(drain(terminal) == expected);
        }

        for (const auto byte : input) {
          terminal.feed(bytes(std::string_view{&byte, 1}));
        }
        require(drain(terminal) == expected);
      }
    }
  }
}

template <Allocator Memory>
void cursorStateViews(Memory &memory) {
  GhosttyAllocatorBridge<Memory> allocator{memory};
  TerminalHandle terminal;
  RenderStateHandle render;
  checkGhostty(ghostty_terminal_new(allocator.get(), terminal.output(), 80, 24));
  checkGhostty(ghostty_render_state_new(allocator.get(), render.output()));
  control::VtState state;
  state.bind(terminal.get(), render.get(), false);
  state.configureSize({80, 24, 9, 18});

  const auto compare = [&] {
    const auto position = state.cursor();
    const auto margins = state.margins();
    const bool origin_mode = state.mode(6);
    GhosttyTerminalCursorState snapshot{};
    checkGhostty(ghostty_terminal_cursor_state(terminal.get(), &snapshot));
    require(position.column == snapshot.x && position.row == snapshot.y);
    require(margins.top == snapshot.top && margins.bottom == snapshot.bottom && margins.left == snapshot.left && margins.right == snapshot.right);
    require(origin_mode == (snapshot.origin != 0));
    const std::array<std::uint16_t, 6> fields{snapshot.x, snapshot.y, snapshot.top, snapshot.bottom, snapshot.left, snapshot.right};
    const auto by_value = ghostty_terminal_cursor_snapshot(terminal.get());
    static_assert(sizeof(GhosttyTerminalCursorSnapshot) == 16);
    static_assert(offsetof(GhosttyTerminalCursorSnapshot, valid) == 14);
    static_assert(offsetof(GhosttyTerminalCursorSnapshot, reserved) == 15);
    require(by_value.valid && by_value.reserved == 0);
    require(by_value.state.origin == snapshot.origin && by_value.state.reserved == 0);
    const std::array<std::uint16_t, 6> returned_fields{by_value.state.x, by_value.state.y, by_value.state.top, by_value.state.bottom, by_value.state.left, by_value.state.right};
    require(returned_fields == fields);
    constexpr std::array keys{GHOSTTY_TERMINAL_DATA_CURSOR_X, GHOSTTY_TERMINAL_DATA_CURSOR_Y, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_TOP, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_BOTTOM, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_LEFT, GHOSTTY_TERMINAL_DATA_SCROLLING_REGION_RIGHT};
    for (std::size_t index = 0; index < keys.size(); ++index) {
      std::uint16_t scalar = UINT16_MAX;
      checkGhostty(ghostty_terminal_get(terminal.get(), keys[index], &scalar));
      require(fields[index] == scalar);
    }

    GhosttyTerminalModeConfig origin{.mode = ghostty_mode_new(6, false), .value = false};
    checkGhostty(ghostty_terminal_get(terminal.get(), GHOSTTY_TERMINAL_DATA_MODE, &origin));
    require(snapshot.origin == origin.value && snapshot.reserved == 0);
    const auto cached = state.cursor();
    require(cached.column == snapshot.x && cached.row == snapshot.y);
    state.mode(70);
    require(state.mode(6) == origin.value);
    state.mode(38, true);
    require(state.mode(6) == origin.value);
  };

  compare();
  for (const auto command : {"abc", "\x1b[5;9H", "\x1b[3;20r", "\x1b[?69h\x1b[5;70s", "\x1b[?6h", "\x1b[2;3H", "\x1b" "7", "\x1b[99;99H", "\x1b" "8", "\x1b[?1049h", "\x1b[4;5H", "\x1b[?1049l", "\x1b[!p", "\x1b" "c", "\x1b[24;80HAB"}) {
    for (const auto byte : std::string_view{command}) {
      const Byte value = static_cast<Byte>(byte);
      state.write({&value, 1});
      compare();
    }
  }

  state.setMode(6, true);
  compare();
  state.setMode(6, false);
  compare();
  checkGhostty(ghostty_terminal_resize(terminal.get(), 43, 12, 9, 18));
  state.configureSize({43, 12, 9, 18});
  compare();

  GhosttyTerminalCursorState untouched{};
  require(ghostty_terminal_cursor_state(nullptr, &untouched) == GHOSTTY_INVALID_VALUE);
  require(untouched.x == 0 && untouched.bottom == 0 && untouched.origin == 0);
  require(ghostty_terminal_cursor_state(terminal.get(), nullptr) == GHOSTTY_INVALID_VALUE);

  const auto invalid = ghostty_terminal_cursor_snapshot(nullptr);
  require(!invalid.valid && invalid.reserved == 0);
  require(invalid.state.origin == 0 && invalid.state.reserved == 0);
  const std::array<std::uint16_t, 6> invalid_fields{invalid.state.x, invalid.state.y, invalid.state.top, invalid.state.bottom, invalid.state.left, invalid.state.right};
  require(invalid_fields == std::array<std::uint16_t, 6>{});
}

template <Allocator Memory>
void saturation(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  std::string requests;
  std::string expected;
  constexpr std::size_t count = 4096;
  for (std::size_t index = 0; index < count; ++index) {
    requests.append("\x1b[5n");
    expected.append("\x1b[0n");
  }
  terminal.feed(bytes(requests));
  require(terminal.hasPendingControl());
  require(drain(terminal, 1) == expected);
  require(!terminal.hasPendingControl());

  requests = "\x1bP+q";
  expected.clear();
  for (std::size_t index = 0; index < count; ++index) {
    requests.append("544E;");
    expected.append("\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\");
  }
  requests.append("\x1b\\");
  terminal.feed(bytes(requests));
  require(terminal.hasPendingControl());
  require(drain(terminal, 3) == expected);
  require(!terminal.hasPendingControl());
}

template <Allocator Memory>
void borrowedRequestResume(Memory &memory) {
  const auto check = [&](std::string request, std::string_view expected_reply) {
    auto responses = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory});
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, responses};
    std::string expected(PtyResponseQueue::message_capacity, 'N');
    expected.append(expected_reply);
    for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
      require(responses->tryPush(bytes("N")));
    }

    request.reserve(8192);
    terminal.feed(bytes(request));
    require(terminal.hasPendingControl());
    std::fill(request.begin(), request.end(), 'X');
    std::string{}.swap(request);

    require(drain(terminal, 1) == expected);
    require(!terminal.hasPendingControl() && responses->snapshot().dropped == 0);
  };

  check("\x1b[2;3H\x1b[6nA\x1b[6n", "\x1b[2;3R\x1b[2;4R");
  check("\x1b[2;3H\x1b[?6nA\x1b[?6n", "\x1b[?2;3;1R\x1b[?2;4;1R");
  check("text\x1b[31mA\x1b[6nB\x1b[0mC\x1b[6n", "\x1b[1;6R\x1b[1;8R");
  check("\x1bP+q544E;544E\x1b\\", "\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\");
  check("\x1bP$qm\x1b\\", "\x1bP1$r0m\x1b\\");
  check("\x1b_Ga=q,f=24,s=1,v=1,i=7;/wAA\x1b\\", "\x1b_Gi=7;OK\x1b\\");

  std::string palette = "\x1b]4";
  std::string replies;
  for (unsigned index = 0; index < 64; ++index) {
    const auto number = std::to_string(index);
    palette += ";" + number + ";#123456;" + number + ";?";
    replies += "\x1b]4;" + number + ";rgb:1212/3434/5656\x1b\\";
  }
  palette += "\x1b\\";
  palette += "text\x1b[31mA\x1b[6nB\x1b[0mC\x1b[6n";
  replies += "\x1b[1;6R\x1b[1;8R";
  check(std::move(palette), replies);
}

template <Allocator Memory>
void sealedReplyOwnership(Memory &memory) {
  using Response = control::Reply<Memory>;
  static_assert(!std::is_copy_constructible_v<Response> && !std::is_move_constructible_v<Response>);
  static_assert(!std::is_copy_assignable_v<Response> && !std::is_move_assignable_v<Response>);
  const std::string payload(PtyResponseQueue::message_byte_capacity * 2, 'R');
  Response reply{memory};
  PtyResponseQueue queue;
  reply.append(payload);
  reply.seal();
  reply.append({});
  bool rejected = false;
  try {
    reply.append("late");
  } catch (const std::logic_error &) {
    rejected = true;
  }
  require(rejected && reply.size() == payload.size() && reply.publish(queue));

  reply.clear();
  reply.clear();
  reply.append("replacement");
  require(reply.publish(queue));
  reply.clear();
  const auto owned = queue.peek();
  require(owned && std::string_view{reinterpret_cast<const char *>(owned->data()), owned->size()} == payload);
  queue.consume(owned->size());
  const auto replacement = queue.peek();
  require(replacement && std::string_view{reinterpret_cast<const char *>(replacement->data()), replacement->size()} == "replacement");
  queue.consume(replacement->size());

  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    require(queue.tryPush(bytes("N")));
  }
  reply.append(payload);
  require(!reply.publish(queue));
  rejected = false;
  try {
    reply.append("late");
  } catch (const std::logic_error &) {
    rejected = true;
  }
  require(rejected && reply.size() == payload.size());
  const auto first = queue.peek();
  require(first && first->size() == 1);
  queue.consume(1);
  require(reply.publish(queue));
  reply.discard();
  for (std::size_t index = 1; index < PtyResponseQueue::message_capacity; ++index) {
    const auto prefix = queue.peek();
    require(prefix && std::string_view{reinterpret_cast<const char *>(prefix->data()), prefix->size()} == "N");
    queue.consume(1);
  }
  const auto resumed = queue.peek();
  require(resumed && std::string_view{reinterpret_cast<const char *>(resumed->data()), resumed->size()} == payload);
  queue.consume(resumed->size());
  require(queue.empty());

  const std::string full_payload(Response::maximum_bytes, 'L');
  reply.append(full_payload);
  reply.seal();
  rejected = false;
  try {
    reply.append("x");
  } catch (const std::length_error &) {
    require(false);
  } catch (const std::logic_error &) {
    rejected = true;
  }
  require(rejected && reply.size() == full_payload.size());

  reply.clear();
  reply.append(full_payload);
  bool limited = false;
  try {
    reply.append("x");
  } catch (const std::length_error &) {
    limited = true;
  }
  require(limited && reply.size() == full_payload.size());

}

void emptyReplyCleanup() {
  control_test::OneShotAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    const std::string payload(PtyResponseQueue::message_byte_capacity * 2, 'E');
    control::Reply reply{memory};
    PtyResponseQueue queue;
    upstream.failNext();
    bool failed = false;
    try {
      reply.append(payload);
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    require(failed && reply.size() == 0 && memory.liveBytes() == 0);
    reply.clear();
    reply.clear();

    reply.append(payload);
    const auto reserved = memory.liveBytes();
    const auto upstream_reserved = upstream.liveBytes();
    require(reserved != 0 && upstream_reserved != 0);
    reply.clear();
    reply.clear();
    require(reply.size() == 0 && memory.liveBytes() == reserved && upstream.liveBytes() == upstream_reserved);

    reply.append("inline");
    require(reply.publish(queue));
    reply.clear();
    reply.clear();
    reply.discard();
    require(memory.liveBytes() == 0 && upstream.liveBytes() == 0);
    reply.append("overwritten");
    reply.clear();
    const auto copied = queue.peek();
    require(copied && std::string_view{reinterpret_cast<const char *>(copied->data()), copied->size()} == "inline");
    queue.consume(copied->size());
  }
  require(upstream.failures() == 1 && upstream.liveBytes() == 0 && memory.liveBytes() == 0);
}

void sealAllocationRecovery() {
  control_test::OneShotAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    const std::string payload(PtyResponseQueue::message_byte_capacity * 2, 'F');
    control::Reply reply{memory};
    PtyResponseQueue queue;
    reply.append(payload);
    upstream.failNext();
    bool failed = false;
    try {
      reply.seal();
    } catch (const std::bad_alloc &) {
      failed = true;
    }
    require(failed && reply.size() == payload.size());
    reply.append("tail");
    require(reply.publish(queue));
    reply.clear();
    const auto message = queue.peek();
    require(message && std::string_view{reinterpret_cast<const char *>(message->data()), message->size()} == payload + "tail");
    queue.consume(message->size());
  }
  require(upstream.failures() == 1 && upstream.liveBytes() == 0 && memory.liveBytes() == 0);
}

template <Allocator Memory>
void statusWorkerPriority(Memory &memory) {
  auto responses = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory});
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, responses};
  require(responses->retainWorkerPriority());
  terminal.feed(bytes("\x1b[5nZ"));
  require(terminal.hasPendingControl() && responses->empty());
  require(responses->tryPush(bytes("worker-ack")));
  responses->releaseWorkerPriority();
  terminal.resumeControl();
  terminal.feed(bytes("\x1b[6n"));
  require(drain(terminal) == "worker-ack\x1b[0n\x1b[1;2R");
  require(!terminal.hasPendingControl() && responses->snapshot().dropped == 0);
}

template <Allocator Memory>
void statusBytePressure(Memory &memory) {
  auto responses = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, Memory>{memory});
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, responses};
  auto owner = std::make_shared<std::vector<Byte>>(PtyResponseQueue::total_byte_capacity, 'x');
  const std::weak_ptr lifetime{owner};
  require(responses->tryPushOwned(*owner, owner));
  owner.reset();
  terminal.feed(bytes("\x1b[5n"));
  require(terminal.hasPendingControl() && responses->snapshot().messages == 1);
  terminal.consumeResponses(PtyResponseQueue::total_byte_capacity - 1);
  require(!lifetime.expired() && responses->snapshot().bytes == 5);
  require(drain(terminal) == "x\x1b[0n");
  require(lifetime.expired() && !terminal.hasPendingControl() && responses->snapshot().dropped == 0);
}

template <Allocator Memory>
void cursorEncodings(Memory &memory) {
  control::Reply reply{memory};
  PtyResponseQueue queue;
  constexpr auto maximum = std::numeric_limits<std::uint16_t>::max();
  for (unsigned value = 0; value <= maximum; ++value) {
    for (const bool extended : {false, true}) {
      const control::Position position{static_cast<std::uint16_t>(maximum - value), static_cast<std::uint16_t>(value)};
      control::cursorReport(reply, position, extended);
      std::array<char, 64> expected;
      const auto size = std::snprintf(expected.data(), expected.size(), extended ? "\x1b[?%u;%u;1R" : "\x1b[%u;%uR", value + 1, maximum - value + 1);
      require(size > 0 && static_cast<std::size_t>(size) < expected.size());
      require(reply.publish(queue));
      const auto response = queue.readable();
      require(std::string_view{reinterpret_cast<const char *>(response.data()), response.size()} == std::string_view{expected.data(), static_cast<std::size_t>(size)});
      queue.consumeBytes(response.size());
      reply.clear();
    }
  }
}

template <Allocator Memory>
void colorEncodings(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  for (const auto format : {control::ColorFormat::eight_bit, control::ColorFormat::sixteen_bit, control::ColorFormat::none}) {
    terminal.controlPolicy().color_format = format;
    const unsigned factor = format == control::ColorFormat::sixteen_bit ? 257 : 1;
    const int width = format == control::ColorFormat::sixteen_bit ? 4 : 2;
    for (unsigned sample = 0; sample <= UINT8_MAX; ++sample) {
      const unsigned green = UINT8_MAX - sample;
      const unsigned blue = sample ^ 0x55;
      for (const unsigned operation : {4u, 10u, 11u, 12u}) {
        std::array<char, 64> input;
        const int setter = operation == 4
            ? std::snprintf(input.data(), input.size(), "\x1b]4;%u;#%02x%02x%02x\x1b\\", sample, sample, green, blue)
            : std::snprintf(input.data(), input.size(), "\x1b]%u;#%02x%02x%02x\x1b\\", operation, sample, green, blue);
        require(setter > 0 && static_cast<std::size_t>(setter) < input.size());
        terminal.feed(bytes({input.data(), static_cast<std::size_t>(setter)}));
        require(drain(terminal).empty());

        for (const auto *ending : {"\a", "\x1b\\"}) {
          const int query = operation == 4
              ? std::snprintf(input.data(), input.size(), "\x1b]4;%u;?%s", sample, ending)
              : std::snprintf(input.data(), input.size(), "\x1b]%u;?%s", operation, ending);
          require(query > 0 && static_cast<std::size_t>(query) < input.size());
          terminal.feed(bytes({input.data(), static_cast<std::size_t>(query)}));
          if (format == control::ColorFormat::none) {
            require(drain(terminal).empty());
            continue;
          }

          std::array<char, 64> expected;
          const int count = operation == 4
              ? std::snprintf(expected.data(), expected.size(), "\x1b]4;%u;rgb:%0*x/%0*x/%0*x%s", sample, width, sample * factor, width, green * factor, width, blue * factor, ending)
              : std::snprintf(expected.data(), expected.size(), "\x1b]%u;rgb:%0*x/%0*x/%0*x%s", operation, width, sample * factor, width, green * factor, width, blue * factor, ending);
          require(count > 0 && static_cast<std::size_t>(count) < expected.size());
          require(drain(terminal) == std::string_view{expected.data(), static_cast<std::size_t>(count)});
        }
      }
    }
  }
}

template <Allocator Memory>
void kittyUnsignedColors(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  constexpr std::string_view prepare = "\x1b]21;0=#123456;1=#123456;255=#123456\x1b\\";
  constexpr std::string_view reply = "\x1b]21;1=rgb:12/34/56\x1b\\";
  constexpr std::array invalid_keys{"+0", "+1", "+001", "+255", "-0", "-1", "++1", "1_0", "+", "256", "65535", "999999999999999999999", "\xff"};
  for (const std::string_view key : invalid_keys) {
    const auto query = "\x1b]21;"s + std::string{key} + "=?;1=?\x1b\\";
    for (std::size_t split = 0; split <= query.size(); ++split) {
      terminal.feed(bytes(prepare));
      require(drain(terminal).empty());
      terminal.feed(bytes(std::string_view{query}.substr(0, split)));
      auto actual = drain(terminal);
      terminal.feed(bytes(std::string_view{query}.substr(split)));
      actual.append(drain(terminal));
      require(actual == reply);
    }
  }

  constexpr unsigned maximum_kitty_entries = 526;
  for (unsigned count = maximum_kitty_entries - 1; count <= maximum_kitty_entries + 3; ++count) {
    std::string valid = "\x1b]21;";
    std::string invalid = valid;
    for (unsigned index = 0; index < count; ++index) {
      invalid.append("+0;");
      if (index + 1 < count) {
        valid.append("0;");
      }
    }
    valid.append("1=?\x1b\\");
    invalid.append("1=?\x1b\\");
    terminal.feed(bytes(prepare));
    terminal.feed(bytes(valid));
    require(drain(terminal) == (count <= maximum_kitty_entries ? reply : std::string_view{}));
    terminal.feed(bytes(prepare));
    terminal.feed(bytes(invalid));
    require(drain(terminal) == reply);
  }

  constexpr std::array invalid_hex{"#+00000", "#00+000", "#0000+0", "rgb:+0/0/0", "rgb:0/+0/0", "rgb:0/0/+0"};
  for (const std::string_view value : invalid_hex) {
    std::string query = "\x1b]21;";
    for (unsigned index = 0; index + 1 < maximum_kitty_entries; ++index) {
      query.append("0;");
    }
    query.append("1=").append(value).append(";1=?\x1b\\");
    terminal.feed(bytes(prepare));
    terminal.feed(bytes(query));
    require(drain(terminal) == reply);
  }
}

template <Allocator Memory>
void longPaletteReply(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  terminal.feed(bytes("\x1b]4;0;#000000\x1b\\"));
  constexpr std::size_t count = 81000;
  std::string request = "\x1b]4;";
  std::string expected;
  for (std::size_t index = 0; index < count; ++index) {
    request.append("0;?;");
    expected.append("\x1b]4;0;rgb:0000/0000/0000\x1b\\");
  }
  request.append("\x1b\\Z\x1b[6n");
  expected.append("\x1b[1;2R");
  terminal.feed(bytes(request));
  require(terminal.hasPendingControl());
  require(drain(terminal, 37) == expected);
  require(!terminal.hasPendingControl());
}

template <Allocator Memory>
void uniqueReplies(Memory &memory) {
  auto responses = std::make_shared<PtyResponseQueue>();
  Terminal interactive{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, responses};
  Terminal observer{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::observation, responses};
  MediaTerminal media{memory, TerminalSize{80, 24, 9, 18}, GraphicsLimits{}, responses};
  const auto request = bytes("\x1b[5n\x1bP+q544E\x1b\\\x1b_Ga=q,i=9,s=1,v=1;AAAAAA==\x1b\\\x1b_25a1;q;cp=E0A0\x1b\\");
  observer.feed(request);
  media.feed(request);
  require(responses->empty());
  interactive.feed(request);
  require(drain(interactive) == "\x1b[0n\x1bP1+r544E=787465726D2D323536636F6C6F72\x1b\\\x1b_Gi=9;OK\x1b\\\x1b_25a1;q;cp=e0a0;status=\x1b\\");
}

template <Allocator Memory>
void rowStateViews(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  for (const TerminalSize size : {TerminalSize{80, 24, 9, 18}, TerminalSize{120, 12, 9, 18}, TerminalSize{40, 48, 9, 18}}) {
    terminal.resize(size);
    terminal.feed(bytes("\x1b[1;1Hplain\x1b[1;3mstyle\x1b[0mÁ界\r\n"));
    for (std::uint16_t row = 0; row < size.rows; ++row) {
      auto reference = ghosttySized<GhosttyGridRef>();
      const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {0, row}}};
      checkGhostty(ghostty_terminal_grid_ref(terminal.handle(), point, &reference));
      GhosttyCellsView cells{};
      checkGhostty(ghostty_grid_ref_cells(&reference, &cells));
      require(cells.ptr != nullptr && cells.len != 0);
      for (std::size_t column = 0; column < cells.len; ++column) {
        reference.x = static_cast<std::uint16_t>(column);
        GhosttyCell single = 0;
        checkGhostty(ghostty_grid_ref_cell(&reference, &single));
        require(single == cells.ptr[column]);
      }
      reference.x = static_cast<std::uint16_t>(cells.len);
      require(ghostty_grid_ref_cells(&reference, &cells) == GHOSTTY_INVALID_VALUE);
      reference.x = 0;
      reference.y = UINT16_MAX;
      require(ghostty_grid_ref_cells(&reference, &cells) == GHOSTTY_INVALID_VALUE);
    }
  }
  auto invalid = ghosttySized<GhosttyGridRef>();
  GhosttyCellsView cells{};
  require(ghostty_grid_ref_cells(&invalid, &cells) == GHOSTTY_INVALID_VALUE);
  require(terminal.responses().empty());
}

template <Allocator Memory>
void normalizedGraphemeBatches(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 2, 9, 18}, TerminalPurpose::separate_media};
  std::string input;
  std::array<std::vector<std::uint32_t>, 80> expected;
  const std::array<std::string_view, 3> marks{"́", "̧", "\xf0\x9d\x86\x85"};
  constexpr std::array<std::uint32_t, 3> codepoints{0x301, 0x327, 0x1d185};
  for (unsigned column = 0; column < expected.size(); ++column) {
    input.push_back('A');
    for (unsigned point = 0; point < column % 6; ++point) {
      input.append(marks[point % marks.size()]);
      expected[column].push_back(codepoints[point % codepoints.size()]);
    }
  }
  terminal.feed(bytes(input));
  auto reference = ghosttySized<GhosttyGridRef>();
  const GhosttyPoint origin{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {0, 0}}};
  checkGhostty(ghostty_terminal_grid_ref(terminal.handle(), origin, &reference));
  std::array<std::uint16_t, 80> ascending;
  for (unsigned index = 0; index < ascending.size(); ++index) {
    ascending[index] = static_cast<std::uint16_t>(index);
  }
  const std::array<std::uint16_t, 7> arbitrary{63, 1, 70, 8, 0, 1, 79};
  constexpr std::uint32_t canary = 0xdeadbeef;
  for (const auto columns : {std::span<const std::uint16_t>{ascending}, std::span<const std::uint16_t>{arbitrary}}) {
    for (const auto capacity : {0u, 1u, 2u, 3u, 4u, 8u, 255u, 256u}) {
      std::array<std::uint32_t, 258> storage;
      storage.fill(canary);
      GhosttyGraphemeBatch batch{
          .points = storage.data() + 1,
          .capacity = capacity,
          .length = SIZE_MAX,
          .consumed_columns = SIZE_MAX,
      };
      const auto result = ghostty_grid_ref_grapheme_batch(&reference, columns.data(), columns.size(), &batch);
      std::vector<std::uint32_t> prefix;
      std::size_t consumed = 0;
      for (const auto column : columns) {
        if (expected[column].size() > capacity - prefix.size()) {
          break;
        }
        prefix.insert(prefix.end(), expected[column].begin(), expected[column].end());
        ++consumed;
      }
      require(result == (consumed == columns.size() ? GHOSTTY_SUCCESS : GHOSTTY_OUT_OF_SPACE));
      require(batch.length == prefix.size() && batch.consumed_columns == consumed);
      require(std::equal(prefix.begin(), prefix.end(), storage.begin() + 1));
      require(storage.front() == canary);
      for (auto index = capacity + 1; index < storage.size(); ++index) {
        require(storage[index] == canary);
      }
    }
  }
  std::array<std::uint32_t, 16> points;
  GhosttyGraphemeBatch batch{.points = points.data(), .capacity = points.size(), .length = 0, .consumed_columns = 0};
  const std::array<std::uint16_t, 1> invalid_column{80};
  require(ghostty_grid_ref_grapheme_batch(&reference, invalid_column.data(), invalid_column.size(), &batch) == GHOSTTY_INVALID_VALUE);
  require(ghostty_grid_ref_grapheme_batch(&reference, nullptr, 1, &batch) == GHOSTTY_INVALID_VALUE);
  require(ghostty_grid_ref_grapheme_batch(&reference, nullptr, 0, &batch) == GHOSTTY_SUCCESS);
  require(batch.length == 0 && batch.consumed_columns == 0);
  auto invalid = ghosttySized<GhosttyGridRef>();
  require(ghostty_grid_ref_grapheme_batch(&invalid, nullptr, 0, &batch) == GHOSTTY_INVALID_VALUE);
  batch.points = nullptr;
  require(ghostty_grid_ref_grapheme_batch(&reference, ascending.data(), ascending.size(), &batch) == GHOSTTY_INVALID_VALUE);
}

template <Allocator Memory>
void graphemeChecksums(Memory &memory) {
  for (const std::uint16_t columns : {16, 80, 256, 257}) {
    for (const unsigned density : {1, 7, 8, 9, 16, 80, 256, 257}) {
      if (density > columns) {
        continue;
      }
      for (const unsigned length : {1, 4, 32, 512}) {
        Terminal terminal{memory, TerminalSize{columns, 2, 9, 18}, TerminalPurpose::separate_media};
        terminal.controlPolicy().checksum_report = true;
        std::string input;
        std::uint32_t expected = columns * static_cast<unsigned>('A');
        for (unsigned column = 0; column < columns; ++column) {
          input.push_back('A');
          if (column < density) {
            for (unsigned point = 0; point < length; ++point) {
              input.append(point % 2 == 0 ? "́" : "̧");
              if (point < retained_grapheme_points) {
                expected += point % 2 == 0 ? 0x301 : 0x327;
              }
            }
          }
        }
        std::array<char, 64> request;
        const auto request_size = std::snprintf(request.data(), request.size(), "\x1b[7#y\x1b[9;1;1;1;1;%u*y", columns);
        require(request_size > 0 && static_cast<std::size_t>(request_size) < request.size());
        input.append(request.data(), static_cast<std::size_t>(request_size));
        terminal.feed(bytes(input));
        std::array<char, 32> reply;
        const auto reply_size = std::snprintf(reply.data(), reply.size(), "\x1bP9!~%04X\x1b\\", expected & UINT16_MAX);
        require(reply_size > 0);
        const auto actual = drain(terminal, 3);
        if (actual != std::string_view{reply.data(), static_cast<std::size_t>(reply_size)}) {
          std::fprintf(stderr, "grapheme checksum columns=%u density=%u length=%u expected=%s actual=%s\n", columns, density, length, reply.data(), actual.c_str());
        }
        require(actual == std::string_view{reply.data(), static_cast<std::size_t>(reply_size)});
      }
    }
  }
}

template <Allocator Memory>
void asciiGraphemeChecksums(Memory &memory) {
  for (const bool styled : {false, true}) {
    Terminal terminal{memory, TerminalSize{100, 2, 9, 18}, TerminalPurpose::separate_media};
    terminal.controlPolicy().checksum_report = true;
    std::string input = styled ? "\x1b[1m\x1b[1\"q" : "";
    for (unsigned value = ' '; value <= '~'; ++value) {
      input.push_back(static_cast<char>(value));
      if ((value - ' ') % 3 == 0) {
        input.append("́");
      }
    }
    input.append(5, 'A');
    terminal.feed(bytes(input));
    constexpr unsigned plain = (' ' + '~') * 95 / 2 + 5 * 'A' + 32 * 0x301;
    for (const unsigned flags : {5, 7}) {
      const auto expected = plain + (styled && flags == 5 ? 100 * (128 + 4) : 0);
      terminal.feed(bytes(flags == 5 ? "\x1b[5#y\x1b[7;1;1;1;1;100*y" : "\x1b[7#y\x1b[7;1;1;1;1;100*y"));
      std::array<char, 32> reply;
      const auto size = std::snprintf(reply.data(), reply.size(), "\x1bP7!~%04X\x1b\\", expected & UINT16_MAX);
      require(size > 0 && drain(terminal, 3) == std::string_view{reply.data(), static_cast<std::size_t>(size)});
    }
  }
}

template <Allocator Memory>
void variedGraphemeRows(Memory &memory) {
  Terminal terminal{memory, TerminalSize{256, 4, 9, 18}, TerminalPurpose::separate_media};
  terminal.controlPolicy().checksum_report = true;
  std::uint32_t expected = 0;
  std::string input;
  for (unsigned row = 0; row < 3; ++row) {
    for (unsigned column = 0; column < 256; ++column) {
      input.push_back('A');
      expected += 'A';
      if (row == 0 && column < 248) {
        continue;
      }
      const auto count = row == 1 ? 512u : 1u;
      for (unsigned point = 0; point < count; ++point) {
        input.append(row == 2 ? "\xf0\x9d\x86\x85" : "́");
        if (point < retained_grapheme_points) {
          expected += row == 2 ? 0x1d185 : 0x301;
        }
      }
    }
    if (row != 2) {
      input.append("\r\n");
    }
  }
  input.append("\x1b[7#y\x1b[19;1;1;1;3;256*y");
  terminal.feed(bytes(input));
  std::array<char, 32> reply;
  const auto size = std::snprintf(reply.data(), reply.size(), "\x1bP19!~%04X\x1b\\", expected & UINT16_MAX);
  require(size > 0 && drain(terminal, 3) == std::string_view{reply.data(), static_cast<std::size_t>(size)});
}

template <Allocator Memory>
void abortedControl(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  terminal.feed(bytes("\x1b[?2031;2033;1004;2048h"));
  drain(terminal);
  terminal.abortControl();
  terminal.configureClientFacts({.light = true, .visible = true, .focused = true});
  terminal.resize({90, 30, 8, 16});
  terminal.feed(bytes("\x1b[5n\x1b]52;c;?\x1b\\"));
  require(terminal.responses().empty());
  require(!terminal.hasPendingControl());
}

template <Allocator Memory>
void clipboardWrites(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}};
  terminal.feed(bytes("\x1b]52;c;aGVsbG8=\x1b\\"));
  require(terminal.effects.clipboard.empty());
  require(!terminal.clipboardControl().route());
  const auto revision = terminal.effects.clipboard_revision;
  terminal.controlPolicy().clipboard_write = control::Access::deny;
  terminal.feed(bytes("\x1b]52;c;c2VjcmV0\x1b\\"));
  require(terminal.effects.clipboard_revision == revision);
  terminal.controlPolicy().clipboard_write = control::Access::ask;
  terminal.feed(bytes("\x1b]52;c;c2VjcmV0\x1b\\"));
  require(terminal.effects.clipboard_revision == revision);
  terminal.feed(bytes("\x1b]52;c;?\x1b\\"));
  require(drain(terminal).empty());
}

template <Allocator Memory>
void ignoredControlSecurity(Memory &memory) {
  for (const auto purpose : {TerminalPurpose::interactive, TerminalPurpose::separate_media, TerminalPurpose::observation}) {
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, purpose};
    terminal.controlPolicy().clipboard_write = control::Access::deny;
    for (unsigned byte = 0; byte < 32; ++byte) {
      if (byte == 7 || byte == 24 || byte == 26 || byte == 27) {
        continue;
      }
      std::string request = "\x1b]5";
      request.push_back(static_cast<char>(byte));
      request.append("2;c;aGVsbG8=\x1b\\");
      terminal.feed(bytes(request));
      require(terminal.effects.clipboard_revision == 0);
    }
  }
}

unsigned foreign_replies = 0;
unsigned foreign_clipboard = 0;

void foreignReply(GhosttyTerminal, void *, const Byte *, std::size_t) noexcept {
  ++foreign_replies;
}

GhosttyClipboardWriteResult foreignClipboard(GhosttyTerminal, void *, const GhosttyClipboardWrite *) noexcept {
  ++foreign_clipboard;
  return GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED;
}

template <Allocator Memory>
void noForeignQueries(Memory &memory) {
  for (const auto purpose : {TerminalPurpose::separate_media, TerminalPurpose::observation}) {
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, purpose};
    terminal.controlPolicy().clipboard_write = control::Access::deny;
    checkGhostty(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_WRITE_PTY, reinterpret_cast<const void *>(&foreignReply)));
    checkGhostty(ghostty_terminal_set(terminal.handle(), GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, reinterpret_cast<const void *>(&foreignClipboard)));
    const std::array<std::string_view, 5> requests{
        "\x1b[5n\x1b[c\x1b]10;?\x1b\\\x1bP+q544E\x1b\\",
        "\x1bP+\x00q544E\x1b\\"sv,
        "\x1b]5\x00" "2;c;aGVsbG8=\x1b\\"sv,
        "\x1bP\x9d" "52;c;aGVsbG8=\x1b\\",
        "\x1bP+\x9b" "5n\x1b\x9a",
    };
    for (const auto request : requests) {
      terminal.feed(bytes(request));
      drain(terminal);
    }
  }
  require(foreign_replies == 0 && foreign_clipboard == 0);
}

template <Allocator Memory>
void deferredEffects(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  std::string request;
  for (unsigned index = 0; index < 65; ++index) {
    request.append("\x1b[5n");
  }
  request.append("Z\x1b]2;Deferred title\x1b\\\x1b]7;file://host/deferred\x1b\\");
  terminal.feed(bytes(request));
  require(terminal.hasPendingControl());
  terminal.refresh();
  require(!terminal.dirty());
  const auto revision = terminal.contentRevision();
  drain(terminal, 1);
  require(terminal.dirty());
  require(terminal.contentRevision() > revision);
  require(terminal.effects.title() == "Deferred title");
  require(terminal.effects.cwd() == "/deferred");
  terminal.refresh();
  require(terminal.screen.cursor.x == 1);
}

template <Allocator Memory>
void sizeEncodings(Memory &memory) {
  using control::SizeReport;
  constexpr std::array<std::uint16_t, 7> dimensions{0, 1, 9, 10, 99, 100, UINT16_MAX};
  PtyResponseQueue queue;
  const auto verify = [&]<SizeReport Kind>(TerminalSize size) {
    control::Reply reply{memory};
    control::sizeReport<Kind>(reply, size);
    require(reply.publish(queue));
    std::array<char, 80> expected;
    const auto rows = static_cast<unsigned>(size.rows);
    const auto cols = static_cast<unsigned>(size.cols);
    const auto height = static_cast<unsigned>(size.cell_height_px);
    const auto width = static_cast<unsigned>(size.cell_width_px);
    int count;
    if constexpr (Kind == SizeReport::event) {
      count = std::snprintf(expected.data(), expected.size(), "\x1b[48;%u;%u;%u;%ut", rows, cols, rows * height, cols * width);
    } else {
      count = std::snprintf(expected.data(), expected.size(), "\x1b[%u;%u;%ut", static_cast<unsigned>(Kind), Kind == SizeReport::pixels ? rows * height : Kind == SizeReport::cell ? height : rows, Kind == SizeReport::pixels ? cols * width : Kind == SizeReport::cell ? width : cols);
    }
    require(count > 0 && static_cast<std::size_t>(count) < expected.size());
    const auto actual = queue.peek();
    require(actual.has_value());
    require(std::string_view{reinterpret_cast<const char *>(actual->data()), actual->size()} == std::string_view{expected.data(), static_cast<std::size_t>(count)});
    queue.consumeBytes(actual->size());
  };

  for (const auto rows : dimensions) {
    for (const auto cols : dimensions) {
      for (const auto height : dimensions) {
        for (const auto width : dimensions) {
          const TerminalSize size{cols, rows, width, height};
          verify.template operator()<SizeReport::pixels>(size);
          verify.template operator()<SizeReport::cell>(size);
          verify.template operator()<SizeReport::text>(size);
          verify.template operator()<SizeReport::screen>(size);
          verify.template operator()<SizeReport::event>(size);
        }
      }
    }
  }
}

template <Allocator Memory>
void reports(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  terminal.feed(bytes("\x1b[?2031;2033;1004;2048h"));
  require(drain(terminal) == "\x1b[?999;2n\x1b[O\x1b[48;24;80;432;720t");
  terminal.configureClientFacts({.light = true, .visible = true, .focused = false});
  require(drain(terminal) == "\x1b[?997;2n\x1b[?999;1n");
  terminal.configureClientFacts({.light = true, .visible = true, .focused = true});
  require(drain(terminal) == "\x1b[I");
  terminal.resize({90, 30, 8, 16});
  require(drain(terminal) == "\x1b[48;30;90;480;720t");
  terminal.feed(bytes("\x1b[?2048s\x1b[?2048l\x1b[?2048r"));
  require(drain(terminal) == "\x1b[48;30;90;480;720t");
  terminal.feed(bytes("\x1b[?2031;2033;1004;2048l"));
  terminal.configureClientFacts({});
  require(drain(terminal).empty());
  terminal.feed(bytes("\x1b[?2033h\x1b" "c"));
  require(drain(terminal) == "\x1b[?999;2n");
  terminal.configureClientFacts({.visible = true});
  require(drain(terminal).empty());
}

template <Allocator Memory>
void reportQueueResume(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  terminal.feed(bytes("\x1b[?2031h"));
  require(drain(terminal).empty());

  std::string expected;
  for (std::size_t index = 0; index < PtyResponseQueue::message_capacity; ++index) {
    terminal.feed(bytes("\x1b[5n"));
    expected += "\x1b[0n";
  }
  terminal.configureClientFacts({.light = true});
  require(terminal.hasPendingControl());

  terminal.feed(bytes("X\x1b[6n"));
  require(terminal.hasPendingControl());
  expected += "\x1b[?997;2n\x1b[1;2R";
  require(drain(terminal, 1) == expected);
  require(!terminal.hasPendingControl() && terminal.responses().empty());
}

template <Allocator Memory>
void reportLifecycle(Memory &memory) {
  Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  constexpr std::string_view modes = "\x1b[?2031;2033;1004;2048;5522";
  const auto command = [&](char final) {
    terminal.feed(bytes(std::string{modes} + final));
  };
  const auto modesAre = [&](bool enabled) {
    for (const unsigned mode : {2031, 2033, 1004, 2048, 5522}) {
      terminal.feed(bytes("\x1b[?" + std::to_string(mode) + "$p"));
      require(drain(terminal) == "\x1b[?" + std::to_string(mode) + (enabled ? ";1$y" : ";2$y"));
    }
    require(terminal.pasteEvents() == enabled);
  };
  terminal.configureClientFacts({.light = true, .visible = true, .focused = true});
  command('h');
  require(drain(terminal) == "\x1b[?999;1n\x1b[I\x1b[48;24;80;432;720t");
  command('s');
  command('l');
  terminal.configureClientFacts({});
  terminal.resize({90, 30, 8, 16});
  require(drain(terminal).empty());
  command('r');
  constexpr std::string_view restored = "\x1b[?999;2n\x1b[O\x1b[48;30;90;480;720t";
  require(drain(terminal) == restored);
  modesAre(true);
  command('r');
  require(drain(terminal) == restored);
  command('l');
  command('s');
  command('h');
  require(drain(terminal) == restored);
  command('r');
  require(drain(terminal).empty());
  modesAre(false);

  command('h');
  command('s');
  require(drain(terminal) == restored);
  terminal.feed(bytes("\x1b[!p"));
  require(drain(terminal).empty());
  modesAre(true);
  command('l');
  command('r');
  require(drain(terminal) == restored);
  modesAre(true);
  terminal.feed(bytes("\x1b[?1049h"));
  modesAre(true);
  terminal.feed(bytes("\x1b[?1049l"));
  modesAre(true);
  terminal.configureClientFacts({.light = true, .visible = true, .focused = true});
  require(drain(terminal) == "\x1b[?997;2n\x1b[?999;1n\x1b[I");
  terminal.feed(bytes("\x1b" "c"));
  require(drain(terminal).empty());
  modesAre(false);
  command('r');
  require(drain(terminal).empty());
  modesAre(false);
  terminal.feed(bytes("\x1b[?996n\x1b[?998n"));
  require(drain(terminal) == "\x1b[?997;2n\x1b[?999;1n");
  command('h');
  require(drain(terminal) == "\x1b[?999;1n\x1b[I\x1b[48;30;90;480;720t");

  Terminal screens{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media};
  screens.controlPolicy().checksum_report = true;
  screens.feed(bytes("A\x1b[1#y\x1b[>1u\x1b[?u\x1b[?1049h\x1b[?u\x1b[>2u\x1b[?u\x1b[?1049l\x1b[?u\x1b[1;1;1;1;1;1*y"));
  require(drain(screens) == "\x1b[?1u\x1b[?0u\x1b[?2u\x1b[?1u\x1bP1!~0041\x1b\\");
  screens.feed(bytes("\x1b[!p\x1b[2;1;1;1;1;1*y"));
  require(drain(screens) == "\x1bP2!~FFBF\x1b\\");
  screens.feed(bytes("\x1b" "c\x1b[?u\x1b[3;1;1;1;1;1*y"));
  require(drain(screens) == "\x1b[?0u\x1bP3!~0000\x1b\\");
}


}

template <Allocator Memory>
void asciiBridgeContract(Memory &memory) {
  GhosttyAllocatorBridge<Memory> allocator{memory};
  TerminalHandle candidate;
  TerminalHandle reference;
  checkGhostty(ghostty_terminal_new(allocator.get(), candidate.output(), 80, 24));
  checkGhostty(ghostty_terminal_new(allocator.get(), reference.output(), 80, 24));
  const std::size_t continuation_limit = 64;
  checkGhostty(ghostty_terminal_set(candidate.get(), GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit));
  checkGhostty(ghostty_terminal_set(reference.get(), GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &continuation_limit));
  const auto write = [](GhosttyTerminal terminal, std::string_view input) {
    ghostty_terminal_vt_write(terminal, reinterpret_cast<const std::uint8_t *>(input.data()), input.size());
  };
  const auto compare = [&] {
    GhosttyTerminalCursorState actual{}, expected{};
    checkGhostty(ghostty_terminal_cursor_state(candidate.get(), &actual));
    checkGhostty(ghostty_terminal_cursor_state(reference.get(), &expected));
    require(actual.x == expected.x && actual.y == expected.y && actual.top == expected.top && actual.bottom == expected.bottom && actual.left == expected.left && actual.right == expected.right && actual.origin == expected.origin);
    bool actual_ground = false, expected_ground = false;
    checkGhostty(ghostty_terminal_get(candidate.get(), GHOSTTY_TERMINAL_DATA_VT_GROUND, &actual_ground));
    checkGhostty(ghostty_terminal_get(reference.get(), GHOSTTY_TERMINAL_DATA_VT_GROUND, &expected_ground));
    require(actual_ground == expected_ground);
    std::array<std::uint8_t, 64> actual_continuation{}, expected_continuation{};
    std::size_t actual_written = 0, expected_written = 0;
    const auto actual_result = ghostty_terminal_continuation_buf(candidate.get(), actual_continuation.data(), actual_continuation.size(), &actual_written);
    const auto expected_result = ghostty_terminal_continuation_buf(reference.get(), expected_continuation.data(), expected_continuation.size(), &expected_written);
    require(actual_result == GHOSTTY_SUCCESS && actual_result == expected_result && actual_written == expected_written && actual_continuation == expected_continuation);
    for (std::uint16_t row = 0; row < 24; ++row) {
      auto actual_ref = ghosttySized<GhosttyGridRef>();
      auto expected_ref = ghosttySized<GhosttyGridRef>();
      const GhosttyPoint point{.tag = GHOSTTY_POINT_TAG_ACTIVE, .value = {.coordinate = {0, row}}};
      checkGhostty(ghostty_terminal_grid_ref(candidate.get(), point, &actual_ref));
      checkGhostty(ghostty_terminal_grid_ref(reference.get(), point, &expected_ref));
      GhosttyCellsView actual_cells{}, expected_cells{};
      checkGhostty(ghostty_grid_ref_cells(&actual_ref, &actual_cells));
      checkGhostty(ghostty_grid_ref_cells(&expected_ref, &expected_cells));
      require(actual_cells.len == expected_cells.len && std::equal(actual_cells.ptr, actual_cells.ptr + actual_cells.len, expected_cells.ptr));
    }
  };

  std::array<std::uint32_t, 35> codepoints;
  for (const auto prefix : {std::string_view{}, std::string_view{"\xe2\x82"}}) {
    for (unsigned value = 0; value < 256; ++value) {
      for (const std::size_t position : {0u, 16u, 34u}) {
        write(candidate.get(), "\x1b" "c");
        write(reference.get(), "\x1b" "c");
        write(candidate.get(), prefix);
        write(reference.get(), prefix);
        compare();
        codepoints.fill('A');
        codepoints[position] = value;
        const bool accepted = value < 0x80 && value != 0x05 && value != 0x1b;
        const auto expected_consumed = accepted ? codepoints.size() : position;
        std::size_t consumed = SIZE_MAX;
        const auto result = ghostty_terminal_vt_write_ascii(candidate.get(), codepoints.data(), codepoints.size(), &consumed);
        require(result == (accepted ? GHOSTTY_SUCCESS : GHOSTTY_INVALID_VALUE) && consumed == expected_consumed);
        std::string raw(codepoints.size(), 'A');
        raw[position] = static_cast<char>(value);
        write(reference.get(), std::string_view{raw}.substr(0, expected_consumed));
        compare();
      }
    }
  }

  for (const auto invalid : {UINT32_C(0x100), UINT32_C(0x10ffff), UINT32_C(0x110000), UINT32_MAX}) {
    write(candidate.get(), "\x1b" "c");
    write(reference.get(), "\x1b" "c");
    codepoints.fill('A');
    codepoints[16] = invalid;
    std::size_t consumed = 0;
    require(ghostty_terminal_vt_write_ascii(candidate.get(), codepoints.data(), codepoints.size(), &consumed) == GHOSTTY_INVALID_VALUE && consumed == 16);
    write(reference.get(), std::string(16, 'A'));
    compare();
  }

  constexpr std::uint32_t repeated_controls[]{'A', '\r', '\n', 0, '\t', '\r', '\n', 0x0e, 'q', 0x0f, '\b', 0x0b, 0x0c, 0x18, 0x1a, 0x7f, 'B'};
  for (const auto prefix : {std::string_view{}, std::string_view{"\xf0\x9f"}}) {
    write(candidate.get(), "\x1b" "c");
    write(reference.get(), "\x1b" "c");
    write(candidate.get(), prefix);
    write(reference.get(), prefix);
    std::size_t consumed = 0;
    checkGhostty(ghostty_terminal_vt_write_ascii(candidate.get(), repeated_controls, std::size(repeated_controls), &consumed));
    require(consumed == std::size(repeated_controls));
    std::string raw;
    for (const auto codepoint : repeated_controls) {
      raw.push_back(static_cast<char>(codepoint));
    }
    write(reference.get(), raw);
    compare();
  }

  const std::string_view print_contexts[]{
      "", "\x1b(0", "\x1b[4h", "\x1b[?7l", "\x1b[?1049h",
      "\x1b[3;20r\x1b[?6h", "\x1b]8;;https://example.invalid\x1b\\",
      "\x1b[38;2;12;34;56m", "\x1b[?2027h\x1b[?69h\x1b[3;40s"};
  std::array<std::uint32_t, GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT> printable;
  constexpr std::array<std::uint32_t, 4> pattern{'A', 'q', 0x7f, '~'};
  for (std::size_t index = 0; index < printable.size(); ++index) {
    printable[index] = pattern[index % pattern.size()];
  }
  for (const auto context : print_contexts) {
    for (const auto pending : {std::string_view{}, std::string_view{"\xf0\x9f"}}) {
      for (const std::size_t count : {1u, 15u, 16u, 17u, 79u, 80u, 81u, 4095u, 4096u}) {
        for (const std::size_t fragment : {1u, 16u, 79u, 4096u}) {
          for (const auto terminal : {candidate.get(), reference.get()}) {
            write(terminal, "\x1b" "c");
            write(terminal, "\xe7\x95\x8c" "e\xcc\x81\x1b[H");
            write(terminal, context);
            write(terminal, pending);
          }
          std::string raw(count, 'A');
          for (std::size_t index = 0; index < count; ++index) {
            raw[index] = static_cast<char>(printable[index]);
          }
          for (std::size_t offset = 0; offset < count;) {
            const auto size = std::min(fragment, count - offset);
            std::size_t applied = SIZE_MAX;
            checkGhostty(ghostty_terminal_vt_write_ascii(candidate.get(), printable.data() + offset, size, &applied));
            require(applied == size);
            write(reference.get(), std::string_view{raw}.substr(offset, size));
            offset += size;
          }
          compare();
        }
      }
    }
  }

  std::array<std::uint32_t, GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT + 1> large;
  large.fill('L');
  for (const auto count : {GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT - 1, GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT}) {
    write(candidate.get(), "\x1b" "c\xe2\x82");
    write(reference.get(), "\x1b" "c\xe2\x82");
    std::size_t consumed = 0;
    checkGhostty(ghostty_terminal_vt_write_ascii(candidate.get(), large.data(), count, &consumed));
    require(consumed == static_cast<std::size_t>(count));
    write(reference.get(), std::string(count, 'L'));
    compare();
  }
  std::size_t consumed = SIZE_MAX;
  require(ghostty_terminal_vt_write_ascii(candidate.get(), large.data(), large.size(), &consumed) == GHOSTTY_INVALID_VALUE && consumed == 0);
  compare();
  require(ghostty_terminal_vt_write_ascii(nullptr, codepoints.data(), 1, &consumed) == GHOSTTY_INVALID_VALUE && consumed == 0);
  require(ghostty_terminal_vt_write_ascii(candidate.get(), nullptr, 1, &consumed) == GHOSTTY_INVALID_VALUE && consumed == 0);
  require(ghostty_terminal_vt_write_ascii(candidate.get(), nullptr, GHOSTTY_TELAR_ASCII_CODEPOINT_LIMIT + 1, &consumed) == GHOSTTY_INVALID_VALUE && consumed == 0);
  require(ghostty_terminal_vt_write_ascii(candidate.get(), nullptr, 0, &consumed) == GHOSTTY_SUCCESS && consumed == 0);
  require(ghostty_terminal_vt_write_ascii(candidate.get(), codepoints.data(), 1, nullptr) == GHOSTTY_INVALID_VALUE);
  write(candidate.get(), "\x1b[31");
  write(reference.get(), "\x1b[31");
  require(ghostty_terminal_vt_write_ascii(candidate.get(), codepoints.data(), 1, &consumed) == GHOSTTY_INVALID_VALUE && consumed == 0);
  compare();
  write(candidate.get(), "m");
  write(reference.get(), "m");
  compare();
}

void semanticAsciiWriteFailure() {
  control_test::OneShotAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    auto queue = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, decltype(memory)>{memory});
    Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, queue};
    const std::string text(control::ascii_detail::codepoint_capacity * 2, 'x');
    const auto input = text + "\x1b]2;unavailable\x1b\\" + text + "\x1b[5n";
    upstream.failNext();
    bool failed = false;
    try {
      terminal.feed(bytes(input));
    } catch (const TerminalError &error) {
      require(error.result() == GHOSTTY_OUT_OF_MEMORY);
      failed = true;
    }
    bool processing_error = false;
    checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
    require(failed && processing_error && upstream.failures() == 1);
    const auto queued = terminal.responses();
    require(std::string_view{reinterpret_cast<const char *>(queued.data()), queued.size()} == "\x1b[0n");
    terminal.abortControl();
    require(queue->closed() && queue->empty() && !terminal.hasPendingControl());
  }
  require(memory.liveBytes() == 0 && upstream.liveBytes() == 0);
}

void semanticWriteFailure() {
  control_test::OneShotAllocator upstream;
  BudgetAllocator memory{upstream, 64 * 1024 * 1024};
  {
    auto queue = std::allocate_shared<PtyResponseQueue>(AllocatorRef<PtyResponseQueue, decltype(memory)>{memory});
    {
      Terminal terminal{memory, TerminalSize{80, 24, 9, 18}, TerminalPurpose::separate_media, queue};
      upstream.failNext();
      bool failed = false;
      try {
        terminal.feed(bytes("\x1b]2;unavailable\x1b\\\x1b[5n"));
      } catch (const TerminalError &error) {
        require(error.result() == GHOSTTY_OUT_OF_MEMORY);
        failed = true;
      }

      bool processing_error = false;
      checkGhostty(ghostty_terminal_get(terminal.handle(), GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR, &processing_error));
      require(failed && processing_error && upstream.failures() == 1);
      const auto queued = terminal.responses();
      require(std::string_view{reinterpret_cast<const char *>(queued.data()), queued.size()} == "\x1b[0n");

      terminal.abortControl();
      require(queue->closed() && queue->empty() && !terminal.hasPendingControl());
      terminal.configureClientFacts({.light = true, .visible = true, .focused = true});
      terminal.resumeControl();
      try {
        terminal.feed(bytes("\x1b[5n\x1b]52;c;?\x1b\\"));
      } catch (const TerminalError &error) {
        require(error.result() == GHOSTTY_OUT_OF_MEMORY);
      }
      require(queue->closed() && queue->empty() && !terminal.hasPendingControl());
    }
  }
  require(memory.liveBytes() == 0 && upstream.liveBytes() == 0);
}

int main(int argc, char **argv) {
  SystemAllocator system;
  BudgetAllocator budget{system, 64 * 1024 * 1024};
  SynchronizedAllocator memory{budget};
  if (argc == 2) {
    if (std::string_view{argv[1]} == "security") {
      ignoredControlSecurity(memory);
    } else {
      deferredEffects(memory);
    }
    return 0;
  }
  ignoredControlSecurity(memory);
  noForeignQueries(memory);
  deferredEffects(memory);
  streamOrder(memory);
  cursorRequestVariants(memory);
  ordinaryControlBoundaries(memory);
  colorEncodings(memory);
  kittyUnsignedColors(memory);
  cursorEncodings(memory);
  cursorStateViews(memory);
  saturation(memory);
  borrowedRequestResume(memory);
  sealedReplyOwnership(memory);
  emptyReplyCleanup();
  sealAllocationRecovery();
  statusWorkerPriority(memory);
  statusBytePressure(memory);
  longPaletteReply(memory);
  uniqueReplies(memory);
  clipboardWrites(memory);
  abortedControl(memory);
  semanticWriteFailure();
  asciiBridgeContract(memory);
  semanticAsciiWriteFailure();
  rowStateViews(memory);
  normalizedGraphemeBatches(memory);
  graphemeChecksums(memory);
  asciiGraphemeChecksums(memory);
  variedGraphemeRows(memory);
  sizeEncodings(memory);
  reports(memory);
  reportLifecycle(memory);
  reportQueueResume(memory);
  testPtyResponseQueue();
  require(budget.liveBytes() == 0);
  std::puts("Native control engine and response ownership tests passed");
}
