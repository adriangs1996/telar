// The window as ui drives it: the types each window holds for its frames, its geometry and its
// cues, the title it shows for the session, and the cadence the runtime sends frames at.
export module telar.gui.application:window;

import std;

import :session;
import telar.gui.features.window;

export namespace telar::gui::application::window {

  using features::window::ChromeSurfaces;
  using features::window::DisplayMetrics;
  using features::window::FramePacer;
  using features::window::LoadingCue;
  using features::window::WindowTitle;

  // The title of the session's focused pane, its tab and workspace, by the configured pattern.
  [[nodiscard]] WindowTitle title(const Session& session, std::string_view hostname);

  // The display the window shows on refreshes `fps` times a second; pace sends what follows.
  void setRefreshRate(Session& session, std::uint16_t fps) noexcept;

  // Tells the runtime how often to send frames: the display's rate, or the configured maximum
  // when that is lower.
  void pace(Session& session);

}
