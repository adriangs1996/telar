#include "terminal/terminal.hpp"
#include "graphics/media_terminal.hpp"
#include <cstdio>
#include <stdexcept>
#include <string>

using namespace telar;
using namespace telar::runtime;
using namespace std::literals;

void testPtyResponseQueue();

namespace {
void require(bool condition) {
  if (!condition) {
    throw std::runtime_error{"Control engine assertion failed"};
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
  colorEncodings(memory);
  cursorEncodings(memory);
  saturation(memory);
  longPaletteReply(memory);
  uniqueReplies(memory);
  clipboardWrites(memory);
  abortedControl(memory);
  rowStateViews(memory);
  reports(memory);
  testPtyResponseQueue();
  require(budget.liveBytes() == 0);
  std::puts("Native control engine and response ownership tests passed");
}
