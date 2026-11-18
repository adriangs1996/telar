#include <sys/socket.h>
#include <unistd.h>

import std;
import telar.testing;
import telar.runtime.runtime.tests.protocol_peer;
import telar.runtime.runtime.tests.runtime_host;
import telar.runtime.runtime.tests.wire_session;
import telar.wire.clients;
import telar.wire.clipboard;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr std::array<std::string_view, 1> cat{"/bin/cat"};

  std::span<const Byte> bytes(std::string_view text) {
    return {reinterpret_cast<const Byte*>(text.data()), text.size()};
  }

  // Every request a client sent before this one was handled.
  void settle(ProtocolPeer& peer, std::uint64_t request) {
    check(peer.exchange<ClientList>(QueryClients{.request_id = request}).request_id == request);
  }

  // Whether the client's clipboard received anything over the next half second, asked through
  // round trips so a reply always ends each wait.
  bool clipboardArrives(ProtocolPeer& peer, std::uint64_t request) {
    bool arrived = false;

    for (auto id = request; id < request + 5; ++id) {
      std::this_thread::sleep_for(std::chrono::milliseconds{100});
      peer.send(QueryClients{.request_id = id});
      for (;;) {
        const auto message = peer.receiveAny<PaneClipboard, ClientList>();
        if (std::holds_alternative<PaneClipboard>(message)) {
          arrived = true;
        } else if (std::get<ClientList>(message).request_id == id) {
          break;
        }
      }
    }

    return arrived;
  }

  void testCopySelectionClipboardLimit() {
    RuntimeHost host;
    ProtocolPeer owner{host.socket()};
    ProtocolPeer outsider{host.socket()};
    const std::string line(78, 'x');
    const auto flood = "i=0; while [ $i -lt 15000 ]; do echo " + line + "; i=$((i+1)); done; echo printed-all; exec cat";
    const std::array<std::string_view, 3> large_arguments{"/bin/sh", "-c", flood};
    const std::array<std::string_view, 3> small_arguments{"/bin/sh", "-c", "echo small-text; exec cat"};
    const auto large = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = large_arguments}});
    const auto small = owner.exchange<PaneOpened>(CreatePane{.request_id = 2, .location = large.location, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = small_arguments}});

    screenShowing(owner, small.pane_id, "small-text");
    screenShowing(owner, large.pane_id, "printed-all");

    // A small selection reaches the client's clipboard.
    owner.send(CopySelection{.pane_id = small.pane_id, .start_y = 0, .end_y = 0, .linewise = true});
    owner.deadline(std::chrono::seconds{10});
    const auto copied = owner.receive<PaneClipboard>();

    check(copied.pane_id == small.pane_id && std::string_view{reinterpret_cast<const char*>(copied.bytes.data()), copied.bytes.size()}.contains("small-text"));

    // More than a megabyte is refused, and the clipboard is left as it was.
    owner.send(CopySelection{.pane_id = large.pane_id, .start_y = 0, .end_y = 1'000'000, .linewise = true});
    std::optional<FailureCode> refused;

    try {
      owner.receive<PaneClipboard>();
    } catch (const ProtocolFailure& failure) {
      refused = failure.code;
    }

    check(refused == FailureCode::resource_limit, "a selection past the clipboard limit was copied");
    check(!clipboardArrives(owner, 3), "the refused selection reached the clipboard");

    // A client attached elsewhere copies nothing from a pane it does not show.
    outsider.exchange<PaneOpened>(CreateWorkspace{.request_id = 5, .size = size, .name = "Elsewhere", .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    outsider.send(CopySelection{.pane_id = small.pane_id, .start_y = 0, .end_y = 0, .linewise = true});
    outsider.deadline(std::chrono::seconds{10});
    check(!clipboardArrives(outsider, 10), "a pane's text reached a client not attached to it");
  }

  void testAttachSecondWorkspaceRefused() {
    RuntimeHost host;
    ProtocolPeer window{host.socket()};
    ProtocolPeer control{host.socket()};

    window.send(RequestRuntimeState{.client_identity = 41, .interactive = true});
    window.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    const auto other = control.exchange<PaneOpened>(CreateWorkspace{.request_id = 2, .size = size, .name = "Other", .launch = Launch{.cwd = "/tmp", .arguments = cat}});

    // A window shows one workspace at a time: opening another's pane without leaving is refused.
    window.send(OpenPane{.request_id = 3, .target = {.kind = PaneTarget::Kind::pane, .id = other.pane_id}, .size = size});
    check(closedByRuntime(window.descriptor(), std::chrono::seconds{5}), "a window attached a pane of a second workspace");
    settle(control, 4);
  }

  void testCommandTypesBracketedAndRequiresAttachment() {
    RuntimeHost host;
    ProtocolPeer owner{host.socket()};
    ProtocolPeer outsider{host.socket()};
    const Recorder recorder{host, owner, true};

    // A client the pane is not attached to types nothing into it.
    outsider.send(PaneCommand{.pane_id = recorder.opened.pane_id, .text = bytes("intruder")});
    settle(outsider, 2);

    // The pane's program asked for bracketed paste: the command arrives pasted, then submitted.
    owner.send(PaneCommand{.pane_id = recorder.opened.pane_id, .text = bytes("make test")});
    const auto received = recorder.received("\x1b[201~");

    check(received.starts_with("\x1b[200~make test\x1b[201~"), received);
    check(recorder.received("\r").ends_with("\x1b[201~\r"), "the command was not submitted");
    check(!received.contains("intruder"), "a client not attached to the pane typed into it");
  }

  void testInputAndResizeRequireAttachment() {
    RuntimeHost host;
    ProtocolPeer outsider{host.socket()};
    std::optional<Recorder> recorder;

    // The window that opened the pane leaves, so nobody holds the workspace's geometry.
    {
      ProtocolPeer owner{host.socket()};

      recorder.emplace(host, owner);
    }

    outsider.send(PaneInput{recorder->opened.pane_id, bytes("intruder")});
    outsider.send(PaneResize{recorder->opened.pane_id, TerminalSize{120, 50, 8, 16}});
    settle(outsider, 2);

    // A window that shows the pane again types, and the program reads only that.
    ProtocolPeer window{host.socket()};

    window.exchange<PaneOpened>(OpenPane{.request_id = 3, .target = {.kind = PaneTarget::Kind::pane, .id = recorder->opened.pane_id}, .size = size});
    window.send(PaneInput{recorder->opened.pane_id, bytes("owner")});
    check(!recorder->received("owner").contains("intruder"), "a client not attached to the pane typed into it");
    check(readFile(recorder->record + ".size") == "80x24", "a client not attached to the pane resized it");
  }

  // Frames for `requests`, sent in one write so the runtime reads them together.
  template <typename... Requests>
  void sendTogether(ProtocolPeer& peer, const Requests&... requests) {
    std::ostringstream payloads;
    std::string frames;

    ([&] {
      payloads.str({});
      peer.record(payloads, requests);
      const auto payload = payloads.str();
      const auto length = static_cast<std::uint32_t>(payload.size());

      for (unsigned shift = 0; shift < 32; shift += 8) {
        frames.push_back(static_cast<char>((length >> shift) & 0xff));
      }

      frames += payload;
    }(),
        ...);
    check(::send(peer.descriptor(), frames.data(), frames.size(), 0) == static_cast<ssize_t>(frames.size()));
  }

  void testSearchSupersedesAndRequiresAttachment() {
    RuntimeHost host;
    ProtocolPeer owner{host.socket()};
    ProtocolPeer window{host.socket()};
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "echo first; echo needle-here; echo last; exec cat"};
    const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});

    screenShowing(owner, opened.pane_id, "last");

    // A window searches only the panes it shows.
    window.send(RequestRuntimeState{.client_identity = 51, .interactive = true});
    window.deadline(std::chrono::seconds{5});
    check(refusal(window, SearchPane{.request_id = 2, .pane_id = opened.pane_id, .needle = "needle"}) == FailureCode::pane_not_found);

    // A second search before the first ends replaces it, and the second finds its match.
    sendTogether(owner, SearchPane{.request_id = 3, .pane_id = opened.pane_id, .needle = "first"}, SearchPane{.request_id = 4, .pane_id = opened.pane_id, .needle = "needle"});
    owner.deadline(std::chrono::seconds{10});
    std::optional<FailureCode> superseded;

    try {
      owner.receive<PaneMatches>();
    } catch (const ProtocolFailure& failure) {
      superseded = failure.code;
    }

    check(superseded == FailureCode::resource_limit, "the first search was not superseded");
    const auto matches = owner.receive<PaneMatches>();

    check(matches.request_id == 4 && matches.matches.size() == 1 && matches.matches[0].len == 6);
  }

  void testReadRowsRequiresAttachment() {
    RuntimeHost host;
    ProtocolPeer owner{host.socket()};
    ProtocolPeer window{host.socket()};
    const std::array<std::string_view, 3> arguments{"/bin/sh", "-c", "echo row-text; exec cat"};
    const auto opened = owner.exchange<PaneOpened>(OpenPane{.request_id = 1, .size = size, .launch = Launch{.cwd = "/tmp", .arguments = arguments}});

    screenShowing(owner, opened.pane_id, "row-text");

    // The rows a window draws as it scrolls.
    const auto rows = owner.exchange<PaneRows>(ReadPaneRows{.request_id = 2, .pane_id = opened.pane_id, .from = 0, .count = 4});

    check(rows.pane_id == opened.pane_id && rows.rows == 4 && !rows.cells.empty());

    window.send(RequestRuntimeState{.client_identity = 52, .interactive = true});
    std::optional<FailureCode> refused;

    try {
      window.exchange<PaneRows>(ReadPaneRows{.request_id = 3, .pane_id = opened.pane_id, .from = 0, .count = 4});
    } catch (const ProtocolFailure& failure) {
      refused = failure.code;
    }

    check(refused == FailureCode::pane_not_found, "a client read rows of a pane it does not show");
  }

  const telar::testing::Case case_copy_selection_clipboard_limit{"pane_wire.copy_selection_clipboard_limit", testCopySelectionClipboardLimit};
  const telar::testing::Case case_attach_second_workspace_refused{"pane_wire.attach_second_workspace_refused", testAttachSecondWorkspaceRefused};
  const telar::testing::Case case_command_types_bracketed_and_requires_attachment{"pane_wire.command_types_bracketed_and_requires_attachment", testCommandTypesBracketedAndRequiresAttachment};
  const telar::testing::Case case_input_and_resize_require_attachment{"pane_wire.input_and_resize_require_attachment", testInputAndResizeRequireAttachment};
  const telar::testing::Case case_search_supersedes_and_requires_attachment{"pane_wire.search_supersedes_and_requires_attachment", testSearchSupersedesAndRequiresAttachment};
  const telar::testing::Case case_read_rows_requires_attachment{"pane_wire.read_rows_requires_attachment", testReadRowsRequiresAttachment};

}
