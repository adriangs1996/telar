// The monitor as ui drives it: what the active machine's runtime last answered, asking it again,
// and the signals and priorities a person sends to its processes.
export module telar.gui.application:monitor;

import std;

import :session;
import telar.gui.features.monitor;
import telar.wire.monitor;

export namespace telar::gui::application::monitor {

  using features::monitor::CellText;
  using features::monitor::Column;
  using features::monitor::Columns;
  using features::monitor::ColumnSpan;
  using features::monitor::DiskRow;
  using features::monitor::GroupRow;
  using features::monitor::InterfaceRow;
  using features::monitor::ProcessDetail;
  using features::monitor::ProcessRow;
  using features::monitor::Relative;
  using features::monitor::ShortText;
  using features::monitor::Slot;
  using features::monitor::State;
  using features::monitor::Tone;
  using features::monitor::View;

  using features::monitor::column_count;

  using features::monitor::abbreviateHome;
  using features::monitor::bytes;
  using features::monitor::columns;
  using features::monitor::covers;
  using features::monitor::cpuTone;
  using features::monitor::fit;
  using features::monitor::meterTone;
  using features::monitor::ownerText;
  using features::monitor::percent;
  using features::monitor::relist;
  using features::monitor::rowCount;
  using features::monitor::rowOf;
  using features::monitor::slotAt;
  using features::monitor::toggle;
  using features::monitor::treePrefix;

  using telar::MonitorLayout;
  using telar::MonitorLimits;
  using telar::MonitorScope;
  using telar::MonitorSort;
  using telar::ProcessInstance;
  using telar::ProcessOwner;
  using telar::ProcessSignal;
  using telar::ProcessState;

  // Whether the runtime of this session answers the monitor.
  [[nodiscard]] bool available(const Session& session) noexcept;

  // Asks the runtime for what the view shows; false when the session cannot ask now. While its last
  // question is unanswered the state owes this one, to ask once that one is answered.
  bool refresh(Session& session);

  [[nodiscard]] const State& state(const Session& session) noexcept;

  // What the next refresh asks for.
  [[nodiscard]] View& view(Session& session) noexcept;

  // Sends `signal` to the process; false when the session cannot, or one is still in flight.
  bool signal(Session& session, const ProcessInstance& process, ProcessSignal signal);

  // Sets the process's nice value; false when the session cannot, or a request is still in flight.
  bool prioritize(Session& session, const ProcessInstance& process, std::int32_t nice);

  // The name the monitor gives the owner of a process of the pane: the title of the agent the pane
  // runs, or the label of the pane's tab. Empty when the session knows neither.
  [[nodiscard]] CellText ownerName(const Session& session, std::uint64_t pane_id, ProcessOwner owner);

}
