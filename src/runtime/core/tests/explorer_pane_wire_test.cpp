import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.content;
import telar.wire.files;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr TerminalSize size{.cols = 80, .rows = 24, .cell_width_px = 8, .cell_height_px = 16};
  const ds::Array<std::string_view, 1> cat{"/bin/cat"};

  // Two windows side by side, the second on another machine, with the keys in the second.
  const ds::Array<ExplorerWindow, 2> two_windows{{
      {.root = "/srv/site", .selected = "/srv/site/index.html", .lens = ExplorerLens::changes, .sort = ExplorerSort::size, .scope = ExplorerScope::pane, .follow = false, .hidden = true},
      {.machine = "box", .root = "/var/log", .scope = ExplorerScope::machine, .follow = true, .ignored = true},
  }};

  ds::Option<FailureCode> refused(auto&& send) {
    try {
      send();
    } catch (const ProtocolFailure& failure) {
      return failure.code;
    }

    return ds::none;
  }

  PaneOpened openTerminal(ProtocolPeer& peer) {
    return peer.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
  }

  bool sameWindows(const ExplorerLayout& kept) {
    return kept.windows.size() == 2 && kept.current == 1 && kept.side_by_side && kept.windows[0].machine.empty() && kept.windows[0].root == "/srv/site" && kept.windows[0].selected == "/srv/site/index.html" &&
           kept.windows[0].lens == ExplorerLens::changes && kept.windows[0].sort == ExplorerSort::size && kept.windows[0].scope == ExplorerScope::pane && !kept.windows[0].follow && kept.windows[0].hidden && !kept.windows[0].ignored &&
           kept.windows[1].machine == "box" && kept.windows[1].root == "/var/log" && kept.windows[1].selected.empty() && kept.windows[1].scope == ExplorerScope::machine && kept.windows[1].follow && kept.windows[1].ignored;
  }

  // Asks for an explorer beside `beside` with the two windows, and checks what the client is told
  // on the way: what the pane is, where its windows are, and then its id.
  std::uint64_t openExplorer(ProtocolPeer& peer, const PaneOpened& beside) {
    peer.send(CreateExplorerPane{.request_id = 2, .location = beside.location, .size = size, .layout = {.windows = two_windows.view(), .current = 1, .side_by_side = true}});
    peer.deadline(std::chrono::seconds{10});
    const auto notice = peer.receive<PaneKindNotice>();

    check(notice.kind == PaneKind::explorer, "the client is told the pane is an explorer");
    check(sameWindows(peer.receive<ExplorerKept>().layout), "and where its windows are");
    const auto opened = peer.receive<PaneOpened>();

    check(opened.created && opened.request_id == 2 && opened.pane_id == notice.pane_id && opened.location.tab_id == beside.location.tab_id, "before the reply names it, in the tab it was asked for");
    return opened.pane_id;
  }

  void testAnExplorerStandsInATab() {
    RuntimeHost host;
    ProtocolPeer peer{host.socket()};
    const auto terminal = openTerminal(peer);
    const auto explorer = openExplorer(peer, terminal);

    check(refused([&] {
      peer.exchange<PaneOpened>(CreateExplorerPane{.request_id = 3, .location = terminal.location, .size = size, .layout = {.windows = two_windows.view()}});
    }) == FailureCode::invalid_request,
        "a tab has one explorer");
    check(refused([&] {
      peer.exchange<PaneText>(ReadPane{.request_id = 4, .pane_id = explorer, .rows = 10});
    }) == FailureCode::unsupported_pane_kind,
        "a terminal's request of an explorer says the pane is of another kind");

    constexpr ds::Array<Byte, 1> typed{Byte{'x'}};

    check(refused([&] {
      peer.send(PaneInput{.pane_id = explorer, .bytes = typed.view()});
      static_cast<void>(peer.receive<PaneOpened>());
    }) == FailureCode::unsupported_pane_kind,
        "and so do keys typed at it");
    peer.send(PaneResize{.pane_id = explorer, .size = {.cols = 40, .rows = 12, .cell_width_px = 8, .cell_height_px = 16}});

    // A window that comes later reads what the tab holds, and the explorer's windows with it.
    ProtocolPeer late{host.socket()};

    late.send(RequestTabSnapshot{.request_id = 7, .location = terminal.location});
    late.deadline(std::chrono::seconds{10});
    check(late.receive<PaneKindNotice>().pane_id == explorer);
    check(sameWindows(late.receive<ExplorerKept>().layout), "the windows are sent with the pane's kind");
    check(late.receive<TabSnapshot>().panes.size() == 2, "and the snapshot names the terminal and the explorer");
  }

  void testAnExplorerKeepsTheWindowsItIsGiven() {
    RuntimeHost host;
    ProtocolPeer peer{host.socket()};
    const auto terminal = openTerminal(peer);
    const auto explorer = openExplorer(peer, terminal);
    const ds::Array<ExplorerWindow, 1> moved{{{.root = "/srv/next", .selected = "/srv/next/notes.md", .lens = ExplorerLens::touched}}};

    peer.send(KeepExplorer{.pane_id = explorer, .layout = {.windows = moved.view()}});
    // The pane is where its current window is, on the runtime's own machine.
    peer.deadline(std::chrono::seconds{10});
    for (;;) {
      if (const auto cwd = peer.receive<PaneCwd>(); cwd.pane_id == explorer && cwd.cwd == "/srv/next") {
        break;
      }
    }

    // Windows whose current one is none of them are not taken, and neither are those of a pane
    // that is no explorer: what was kept stays.
    check(refused([&] {
      peer.send(KeepExplorer{.pane_id = explorer, .layout = {.windows = two_windows.view(), .current = 2}});
      static_cast<void>(peer.receive<PaneOpened>());
    }) == FailureCode::invalid_request);
    check(refused([&] {
      peer.send(KeepExplorer{.pane_id = terminal.pane_id, .layout = {.windows = two_windows.view()}});
      static_cast<void>(peer.receive<PaneOpened>());
    }) == FailureCode::unsupported_pane_kind);

    ProtocolPeer late{host.socket()};

    late.send(RequestTabSnapshot{.request_id = 7, .location = terminal.location});
    late.deadline(std::chrono::seconds{10});
    const auto kept = late.receive<ExplorerKept>();

    check(kept.pane_id == explorer && kept.layout.windows.size() == 1 && kept.layout.current == 0 && !kept.layout.side_by_side);
    check(kept.layout.windows[0].root == "/srv/next" && kept.layout.windows[0].selected == "/srv/next/notes.md" && kept.layout.windows[0].lens == ExplorerLens::touched, "the windows the pane was last given");
  }

  void testClosingEndsTheExplorer() {
    RuntimeHost host;
    ProtocolPeer peer{host.socket()};
    const auto terminal = openTerminal(peer);
    const auto explorer = openExplorer(peer, terminal);

    peer.send(ClosePane{.request_id = 20, .pane_id = explorer});
    peer.deadline(std::chrono::seconds{10});
    for (;;) {
      if (const auto exited = peer.receive<PaneExited>(); exited.pane_id == explorer) {
        check(exited.kind == ExitKind::exited && exited.value == 0, "it ends as a program that ended well, with none to wait for");
        break;
      }
    }

    // Once it is closed the tab takes another.
    check(peer.exchange<PaneOpened>(CreateExplorerPane{.request_id = 21, .location = terminal.location, .size = size, .layout = {.windows = two_windows.view(), .current = 1, .side_by_side = true}}).created);
  }

  void testAnExplorerReturnsWithTheSession() {
    RuntimeHost host{{.session = true}};
    std::uint64_t explorer = 0;

    {
      ProtocolPeer peer{host.socket()};
      const auto terminal = openTerminal(peer);

      explorer = openExplorer(peer, terminal);
    }

    host.stop();
    host.start();

    ProtocolPeer peer{host.socket()};

    peer.send(OpenPane{.request_id = 5, .target = {.kind = PaneTarget::Kind::pane, .id = explorer}, .size = size});
    peer.deadline(std::chrono::seconds{10});
    check(peer.receive<PaneKindNotice>().kind == PaneKind::explorer, "the pane is back, and is an explorer");
    check(sameWindows(peer.receive<ExplorerKept>().layout), "with its windows where they were");
    const auto opened = peer.receive<PaneOpened>();

    check(opened.pane_id == explorer && !opened.created);
  }

  const telar::testing::Case case_stands{"explorer_pane_wire.an_explorer_stands_in_a_tab", testAnExplorerStandsInATab};
  const telar::testing::Case case_keeps{"explorer_pane_wire.an_explorer_keeps_the_windows_it_is_given", testAnExplorerKeepsTheWindowsItIsGiven};
  const telar::testing::Case case_closes{"explorer_pane_wire.closing_ends_the_explorer", testClosingEndsTheExplorer};
  const telar::testing::Case case_returns{"explorer_pane_wire.an_explorer_returns_with_the_session", testAnExplorerReturnsWithTheSession};

}
