#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstddef>
#include <cstdint>
#include <span>
#include <stdexcept>

import telar.testing;
import telar.gui.application.tests.session_fixture;
import telar.gui.application;
import telar.wire.monitor;
import telar.wire.pane_io;
import telar.wire.runtime;
import telar.base.ds;
import telar.wire.vocabulary;
import telar.base.memory.allocators;

namespace {

  using telar::testing::check;
  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::application::tests::session_fixture;

  // A transport whose queue is full for the requests a test names, as the window's is while the
  // runtime reads slowly.
  class BusyTransport final : public Transport {
  public:
    void send(std::span<const Byte> message) override {
      const auto tag = static_cast<ClientTag>(message.front());
      const bool monitor = tag == MessageSchema<QueryMonitor>::tag || tag == MessageSchema<RequestProcessSignal>::tag ||
                           tag == MessageSchema<RequestProcessPriority>::tag;
      if ((monitor && full_for_monitor) || (tag == MessageSchema<RequestSnapshot>::tag && full_for_snapshots)) {
        throw std::length_error{"Runtime output queue capacity reached"};
      }

      Transport::send(message);
    }

    bool full_for_monitor = false;
    bool full_for_snapshots = false;
  };

  void aRefusedQueryIsAskedAgain() {
    SystemAllocator memory;
    BusyTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    transport.full_for_monitor = true;
    check(!application::monitor::refresh(client), "a query the transport refused must report that it did not leave");
    check(transport.count(ClientTag::query_monitor) == 0, "a refused query must not reach the runtime");

    transport.full_for_monitor = false;
    check(application::monitor::refresh(client), "once the queue drains the monitor must ask again");
    const auto query = transport.last<QueryMonitor>();

    check(deliver(client, MonitorSnapshot{.request_id = query.request_id, .cpu_permille = 420, .process_count = 7}) == application::Change::monitor, "the answer to the query that left must update the monitor");
    check(application::monitor::state(client).cpu_permille == 420 && application::monitor::state(client).process_count == 7, "the monitor must show what the runtime answered");
    check(application::monitor::refresh(client) && transport.count(ClientTag::query_monitor) == 2, "an answered monitor must ask again");
  }

  void onlyTheAnswerToTheQueryInFlightIsKept() {
    SystemAllocator memory;
    BusyTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    check(application::monitor::refresh(client), "a ready session must ask");
    const auto query = transport.last<QueryMonitor>();

    check(!application::monitor::refresh(client) && transport.count(ClientTag::query_monitor) == 1, "the monitor must not ask twice before the runtime answers");
    check(deliver(client, MonitorSnapshot{.request_id = query.request_id + 100, .cpu_permille = 999}) == application::Change::none, "an answer to another question must be ignored");
    check(application::monitor::state(client).cpu_permille == 0, "an ignored answer must not be shown");
    check(deliver(client, MonitorSnapshot{.request_id = query.request_id, .cpu_permille = 10}) == application::Change::monitor, "the awaited answer must be kept");
  }

  void aRefusedSignalLeavesTheNextOneFree() {
    SystemAllocator memory;
    BusyTransport transport;
    TestSession client{memory, transport};
    const ProcessInstance process{.pid = 4242, .started_seconds = 17};

    openFirstPane(client, transport);
    transport.full_for_monitor = true;
    check(!application::monitor::signal(client, process, ProcessSignal::terminate), "a signal the transport refused must report that it did not leave");
    check(!application::monitor::prioritize(client, process, 5), "a priority the transport refused must report that it did not leave");

    transport.full_for_monitor = false;
    check(application::monitor::signal(client, process, ProcessSignal::terminate), "a refused signal must not block the next one");
    const auto sent = transport.last<RequestProcessSignal>();

    check(sent.process.pid == 4242 && sent.signal == ProcessSignal::terminate, "the signal must name the process the person chose");
    check(!application::monitor::prioritize(client, process, 5), "one action at a time: the signal is still in flight");
    check(deliver(client, RequestCompleted{.request_id = sent.request_id}) != application::Change::none, "the runtime's confirmation must reach the monitor");
    check(application::monitor::prioritize(client, process, 5), "a confirmed signal must free the next action");
    check(transport.last<RequestProcessPriority>().nice == 5, "the priority must carry the chosen value");
  }

  void aRefusedSnapshotRequestIsSentWithTheNextFrame() {
    SystemAllocator memory;
    BusyTransport transport;
    TestSession client{memory, transport};

    openFirstPane(client, transport);
    deliverSingleCell(client, FrameBody{.pane_id = 1, .frame_id = 1, .scroll = {.total_rows = 1}});
    const auto before = transport.count(ClientTag::request_snapshot);

    transport.full_for_snapshots = true;
    bool refused = false;

    try {
      // A delta whose base the window never received.
      deliverSingleCell(client, FrameBody{.pane_id = 1, .frame_id = 9, .base_frame_id = 8, .scroll = {.total_rows = 1}});
    } catch (const std::length_error&) {
      refused = true;
    }

    check(refused, "a frame without its base must ask for a snapshot");
    check(transport.count(ClientTag::request_snapshot) == before, "a refused snapshot request must not reach the runtime");

    transport.full_for_snapshots = false;
    deliverSingleCell(client, FrameBody{.pane_id = 1, .frame_id = 10, .base_frame_id = 9, .scroll = {.total_rows = 1}});
    check(transport.count(ClientTag::request_snapshot) == before + 1, "the next frame without its base must ask again");
    deliverSingleCell(client, FrameBody{.pane_id = 1, .frame_id = 11, .base_frame_id = 10, .scroll = {.total_rows = 1}});
    check(transport.count(ClientTag::request_snapshot) == before + 1, "one snapshot request is enough until the runtime answers it");
  }

  const telar::testing::Case case_refused_query{"monitor_session.a_refused_query_is_asked_again", aRefusedQueryIsAskedAgain};
  const telar::testing::Case case_query_in_flight{"monitor_session.only_the_answer_to_the_query_in_flight_is_kept", onlyTheAnswerToTheQueryInFlightIsKept};
  const telar::testing::Case case_refused_signal{"monitor_session.a_refused_signal_leaves_the_next_one_free", aRefusedSignalLeavesTheNextOneFree};
  const telar::testing::Case case_refused_snapshot{"monitor_session.a_refused_snapshot_request_is_sent_with_the_next_frame", aRefusedSnapshotRequestIsSentWithTheNextFrame};

}
