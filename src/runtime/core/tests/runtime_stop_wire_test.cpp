#include <climits>
#include <cstdlib>
#include <sys/wait.h>

import std;
import telar.testing;
import telar.runtime.core.tests.protocol_peer;
import telar.runtime.core.tests.runtime_host;
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

  // A client asks the runtime to stop: every client is told before its connection closes, and the
  // runtime ends by itself with success, leaving a socket nobody answers.
  void testStopTellsEveryClientAndEnds() {
    RuntimeHost host;
    ProtocolPeer window{host.socket()};
    ProtocolPeer control{host.socket()};

    window.send(RequestRuntimeState{.client_identity = 81, .interactive = true});
    check(window.exchange<PaneOpened>(CreateWorkspace{.request_id = 1, .size = size, .name = "Running", .launch = Launch{.cwd = "/tmp", .arguments = cat}}).pane_id != 0, "the window must have a pane running when the runtime stops");

    control.send(RuntimeStop{});
    window.deadline(std::chrono::seconds{10});
    window.receive<RuntimeStopping>();
    control.deadline(std::chrono::seconds{10});
    control.receive<RuntimeStopping>();

    const auto status = host.wait();

    check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "a runtime asked to stop must end with success");

    bool refused = false;

    try {
      const ProtocolPeer late{host.socket()};
    } catch (const std::exception&) {
      refused = true;
    }

    check(refused, "a stopped runtime must not accept a client");
  }

  const telar::testing::Case case_stop_tells_every_client_and_ends{"runtime_stop_wire.stop_tells_every_client_and_ends", testStopTellsEveryClientAndEnds};

}
