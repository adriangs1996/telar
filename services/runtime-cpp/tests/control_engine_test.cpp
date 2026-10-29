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
  saturation(memory);
  longPaletteReply(memory);
  uniqueReplies(memory);
  clipboardWrites(memory);
  abortedControl(memory);
  reports(memory);
  testPtyResponseQueue();
  require(budget.liveBytes() == 0);
  std::puts("Native control engine and response ownership tests passed");
}
