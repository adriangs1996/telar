// The monitor as ui drives it: what the active machine's runtime last answered, asking it again,
// and the signals and priorities a person sends to its processes.
export module telar.gui.application:monitor;

import std;

import :session;
import telar.gui.features.monitor;
import telar.wire.monitor;

export namespace telar::gui::application::monitor {

  using features::monitor::DiskRow;
  using features::monitor::InterfaceRow;
  using features::monitor::ProcessDetail;
  using features::monitor::ProcessRow;
  using features::monitor::State;
  using features::monitor::View;

  using telar::MonitorLimits;
  using telar::MonitorScope;
  using telar::MonitorSort;
  using telar::ProcessInstance;
  using telar::ProcessSignal;

  // Whether the runtime of this session answers the monitor.
  [[nodiscard]] bool available(const Session& session) noexcept;

  // Asks the runtime for what the view shows, unless its last question is unanswered; false when
  // the session cannot ask.
  bool refresh(Session& session);

  [[nodiscard]] const State& state(const Session& session) noexcept;

  // What the next refresh asks for.
  [[nodiscard]] View& view(Session& session) noexcept;

  // Sends `signal` to the process; false when the session cannot, or one is still in flight.
  bool signal(Session& session, const ProcessInstance& process, ProcessSignal signal);

  // Sets the process's nice value; false when the session cannot, or a request is still in flight.
  bool prioritize(Session& session, const ProcessInstance& process, std::int32_t nice);

}
