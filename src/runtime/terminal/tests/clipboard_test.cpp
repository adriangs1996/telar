import std;
import telar.base.memory.allocators;
import telar.base.text;
import telar.runtime.terminal.control;
import telar.runtime.terminal.control.clipboard;
import telar.runtime.terminal.text_reader;
import telar.wire.clipboard;
import telar.wire.vocabulary;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr control::ClipboardRoute route{1, 13};

  std::span<const Byte> bytes(std::string_view value) {
    return {reinterpret_cast<const Byte*>(value.data()), value.size()};
  }

  std::string encode(std::string_view text) {
    std::string encoded((text.size() + 2) / 3 * 4, '\0');

    check(base64::encode(bytes(text), encoded) == encoded.size());
    return encoded;
  }

  std::string drain(Terminal& terminal) {
    std::string result;

    while (!terminal.responses().empty()) {
      const auto pending = terminal.responses();

      result.append(reinterpret_cast<const char*>(pending.data()), pending.size());
      terminal.consumeResponses(pending.size());
    }

    return result;
  }

  // A terminal with one client to route desktop clipboard requests to.
  struct RoutedTerminal {
    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter{system};
    Terminal terminal{adapter, TerminalSize{80, 24, 9, 18}};

    RoutedTerminal() {
      const std::array<control::ClipboardRoute, 1> routes{route};

      terminal.clipboardControl().routes(routes, route);
    }
  };

  // A pane may hand the desktop up to the clipboard's content limit through OSC 52, and
  // nothing past it: a larger write never becomes a desktop request.
  void osc52OversizedWriteIgnored() {
    for (const auto size : {control::Clipboard::maximum_bytes + 1, control::Clipboard::maximum_bytes + 4, 2 * control::Clipboard::maximum_bytes}) {
      RoutedTerminal routed;

      routed.terminal.feed(bytes("\x1b]52;c;" + encode(std::string(size, 'x')) + "\x1b\\"));
      check(!routed.terminal.clipboardControl().request(7, 11));
      check(drain(routed.terminal).empty());
    }

    RoutedTerminal routed;
    const std::string text(control::Clipboard::maximum_bytes, 'x');

    routed.terminal.feed(bytes("\x1b]52;c;" + encode(text) + "\x1b\\"));
    const auto request = routed.terminal.clipboardControl().request(7, 11);

    check(request && request->write && request->contents.size() == 1);
    check(std::ranges::equal(request->contents[0].data, bytes(text)));
    check(drain(routed.terminal).empty());
  }

  std::string kittyWrite(std::string_view id) {
    return "\x1b]5522;type=write:id=" + std::string{id} + "\x1b\\";
  }

  std::string kittyData(std::string_view mime, std::string_view data) {
    return "\x1b]5522;type=wdata:mime=" + encode(mime) + ";" + encode(data) + "\x1b\\";
  }

  std::string kittyAlias(std::string_view target, std::string_view names) {
    return "\x1b]5522;type=walias:mime=" + encode(target) + ";" + encode(names) + "\x1b\\";
  }

  constexpr std::string_view kitty_commit = "\x1b]5522;type=wdata\x1b\\";

  // An OSC 5522 write is bounded by the clipboard's content limit, counting every copy an
  // alias makes the desktop store: past it the pane gets EFBIG and the desktop nothing.
  void kittyWriteBudget() {
    constexpr auto limit = control::Clipboard::maximum_bytes;
    constexpr std::string_view too_large = "\x1b]5522;type=write:status=EFBIG:id=w\x1b\\";
    const std::string chunk(300000, 'x');

    {
      RoutedTerminal routed;
      std::string input = kittyWrite("w");

      for (int index = 0; index < 4; ++index) {
        input.append(kittyData("text/plain", chunk));
      }

      // The pane learns as soon as its data passes the limit, before it commits.
      routed.terminal.feed(bytes(input));
      check(drain(routed.terminal) == too_large);
      routed.terminal.feed(bytes(kitty_commit));
      check(drain(routed.terminal).empty());
      check(!routed.terminal.clipboardControl().request(7, 11));
    }

    const std::string half(limit / 2 + 1, 'y');

    {
      RoutedTerminal routed;

      routed.terminal.feed(bytes(kittyWrite("w") + kittyData("text/plain", half) + kittyAlias("text/plain", "text/html") + std::string{kitty_commit}));
      check(drain(routed.terminal) == too_large);
      check(!routed.terminal.clipboardControl().request(7, 11));
    }

    RoutedTerminal routed;
    const std::string text(limit / 4, 'z');

    routed.terminal.feed(bytes(kittyWrite("w") + kittyData("text/plain", text) + kittyAlias("text/plain", "text/html") + std::string{kitty_commit}));
    check(drain(routed.terminal).empty());
    const auto request = routed.terminal.clipboardControl().request(7, 11);

    check(request && request->write);
    const auto alias = std::ranges::find(request->contents, std::string_view{"text/html"}, &ClipboardRepresentation::mime);

    check(alias != request->contents.end() && std::ranges::equal(alias->data, bytes(text)));
  }

  bool idCharacter(char byte) noexcept {
    return (byte >= 'a' && byte <= 'z') || (byte >= 'A' && byte <= 'Z') || (byte >= '0' && byte <= '9') || byte == '-' || byte == '_' || byte == '+' || byte == '.';
  }

  // The id a pane names is echoed in its reply, so only safe characters, and a bounded
  // number of them, go back: raw C1, DEL or quotes would let a pane end its own reply early
  // or inject input into the program reading it.
  void kittyIdSanitized() {
    SystemAllocator system;
    MemoryAdapter<SystemAllocator> adapter{system};
    Terminal terminal{adapter, TerminalSize{80, 24, 9, 18}};
    std::string id{"ab\x9c\x7f\"c\xc3\xa9[6n"};

    for (std::size_t index = 0; index < 2 * control::ClipboardMetadata::maximum_id; ++index) {
      id.push_back(index % 2 == 0 ? 'k' : '\x9b');
    }

    terminal.feed(bytes("\x1b]5522;type=read:id=" + id + "\x1b\\"));
    const auto reply = drain(terminal);
    constexpr std::string_view prefix = "\x1b]5522;type=read:status=EPERM:id=";

    check(reply.starts_with(prefix) && reply.ends_with("\x1b\\"));
    const auto echoed = std::string_view{reply}.substr(prefix.size(), reply.size() - prefix.size() - 2);

    check(echoed.starts_with("abc6nk") && echoed.size() <= control::ClipboardMetadata::maximum_id);
    check(std::ranges::all_of(echoed, idCharacter));
  }

  // Each paste grants a password a pane may read the clipboard with once. Pastes past the
  // table's capacity keep the newest grant usable and stay inside the table.
  void grantTableBounded() {
    RoutedTerminal routed;
    auto& clipboard = routed.terminal.clipboardControl();
    std::string password;

    for (std::size_t index = 0; index <= control::ClipboardGrants::capacity + 1; ++index) {
      check(clipboard.paste(route, false, {}));
      routed.terminal.resumeControl();
      const auto reply = drain(routed.terminal);
      const auto start = reply.find(":pw=");

      check(start != std::string::npos);
      password = reply.substr(start + 4, reply.find_first_of(":;\x1b", start + 4) - start - 4);
    }

    routed.terminal.feed(bytes("\x1b]5522;type=read:id=r:name=" + encode("App") + ":pw=" + password + ";" + encode("text/plain") + "\x1b\\"));
    const auto request = clipboard.request(7, 11);

    check(request && !request->write && !request->prompt);
    check(clipboard.route() == route);
  }

  const telar::testing::Case case_osc52_oversized_write_ignored{"clipboard.osc52_oversized_write_ignored", osc52OversizedWriteIgnored};
  const telar::testing::Case case_kitty_write_budget{"clipboard.kitty_write_budget", kittyWriteBudget};
  const telar::testing::Case case_kitty_id_sanitized{"clipboard.kitty_id_sanitized", kittyIdSanitized};
  const telar::testing::Case case_grant_table_bounded{"clipboard.grant_table_bounded", grantTableBounded};

}
