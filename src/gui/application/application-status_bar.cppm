// The status bar as ui drives it: the host's metrics the session keeps, and the types the mode
// bar and the metrics read.
export module telar.gui.application:status_bar;

import std;

import :session;
import telar.gui.features.status_bar;
import telar.wire.vocabulary;

export namespace telar::gui::application::status_bar {

  using features::status_bar::BarMetrics;
  using features::status_bar::CpuHistory;
  using features::status_bar::HostMetrics;
  using features::status_bar::ModeBarGeometry;
  using features::status_bar::ModeBarHint;
  using features::status_bar::ModeBarLabels;
  using features::status_bar::ModeBarMeasurements;
  using features::status_bar::ModeHint;
  using features::status_bar::ModeHints;
  using features::status_bar::ModeKeyLabel;
  using features::status_bar::PrefixHintRouter;
  using features::status_bar::StatusMode;

  // The host's metrics the runtime last sampled, valid until the next sample.
  [[nodiscard]] HostMetrics metrics(const Session& session) noexcept;

}

// What the session's routing hands the status bar; ui never calls these.
namespace telar::gui::application::status_bar {

  Change receive(Session& session, const SystemMetrics& sample);

}
