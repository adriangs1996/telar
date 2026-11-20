#include <climits>
#include <cstdlib>

import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
import telar.wire.clients;
import telar.wire.content;
import telar.wire.layout;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;

  constexpr TerminalSize size{80, 24, 8, 16};
  constexpr ds::Array<std::string_view, 1> cat{"/bin/cat"};
  constexpr ds::Array<std::string_view, 3> leave{"/bin/sh", "-c", "exit 0"};

  // Asks until `settled` accepts what the runtime answers, as a client that cannot see the runtime
  // work must: a pane's exit and a client's disconnection reach the model after their request.
  template <typename Settled>
  void await(std::string_view what, Settled&& settled) {
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{10};

    while (!settled()) {
      check(std::chrono::steady_clock::now() < deadline, what);
      std::this_thread::sleep_for(std::chrono::milliseconds{10});
    }
  }

  // The tab's panes as the runtime describes them to `peer`, or nothing when it knows no such tab.
  ds::Option<std::size_t> panesOf(ProtocolPeer& peer, TabLocation location, std::uint64_t request) {
    try {
      return peer.exchange<TabSnapshot>(RequestTabSnapshot{.request_id = request, .location = location}).panes.size();
    } catch (const ProtocolFailure&) {
      return ds::none;
    }
  }

  std::size_t clientCount(ProtocolPeer& peer, std::uint64_t request) {
    return peer.exchange<ClientList>(QueryClients{.request_id = request}).entries.size();
  }

  // Two clients hold a tab whose last pane exits. The tab outlives the first of them to disconnect
  // and goes with the second, while a client that only looks never keeps it and the rest of the
  // runtime stays in use.
  void testHeldTabOutlivesAllButItsLastHolder() {
    RuntimeHost host;
    ProtocolPeer observer{host.socket()};
    std::uint64_t request = 1;

    const auto other = observer.exchange<PaneOpened>(CreateWorkspace{.request_id = request++, .size = size, .name = "Stays", .launch = Launch{.cwd = "/tmp", .arguments = cat}});
    std::optional<ProtocolPeer> first{std::in_place, host.socket()};
    std::optional<ProtocolPeer> second{std::in_place, host.socket()};

    // The holders are windows, which the runtime lists: the observer sees each of them leave.
    first->send(RequestRuntimeState{.client_identity = 71, .interactive = true});
    second->send(RequestRuntimeState{.client_identity = 72, .interactive = true});
    const auto opened = first->exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Held", .launch = Launch{.cwd = "/tmp", .arguments = leave}});
    const auto location = opened.location;

    for (auto* holder : {&*first, &*second}) {
      check(holder->exchange<RequestCompleted>(HoldTab{.request_id = 2, .location = location, .held = true}).request_id == 2, "a client must be able to hold the tab");
    }

    await("the tab did not lose the pane that exited", [&] {
      return panesOf(observer, location, request++) == std::size_t{0};
    });

    check(clientCount(observer, request++) == 2, "the runtime must list both windows");
    first.reset();
    await("the runtime did not notice the first holder leave", [&] {
      return clientCount(observer, request++) == 1;
    });
    check(panesOf(observer, location, request++) == std::size_t{0}, "the tab must outlive a holder while another still holds it");

    second.reset();
    await("the empty tab did not go with its last holder", [&] {
      return !panesOf(observer, location, request++);
    });

    check(clientCount(observer, request++) == 0, "both windows left");
    check(panesOf(observer, other.location, request++) == std::size_t{1}, "a tab with a live pane must not go with another tab's holders");
    check(observer.exchange<PaneText>(ReadPane{.request_id = request++, .pane_id = other.pane_id, .rows = 1}).request_id == request - 1, "the remaining pane must still answer");
  }

  const telar::testing::Case case_held_tab_outlives_all_but_its_last_holder{"tab_holds_wire.held_tab_outlives_all_but_its_last_holder", testHeldTabOutlivesAllButItsLastHolder};

}
