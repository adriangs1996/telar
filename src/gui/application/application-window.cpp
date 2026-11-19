module telar.gui.application;

import std;

import :access;
import telar.gui.features.window;
import telar.gui.foundation.core;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::application::window {

  WindowTitle title(const Session& session, std::string_view hostname) {
    const auto* tab = activeTab(session.tabs, session.active_tab);
    const auto* pane = focusedPane(session.panes, session.tabs, session.active_tab);
    WindowTitle::Tokens tokens{.workspace = {}, .tab = {}, .pane_title = pane != nullptr ? std::string_view{pane->title} : std::string_view{}, .hostname = hostname};

    if (tab != nullptr) {
      if (!tab->label.empty()) {
        tokens.tab = tab->label;
      } else {
        tokens.tab = tabApplicationName(*tab, pane);
      }

      const auto& workspaces = session.workspaces();
      const auto workspace = std::ranges::find_if(workspaces, [&](const auto& entry) {
        return sameWorkspace(entry.location, tab->location.workspace);
      });
      if (workspace != workspaces.end()) {
        tokens.workspace = workspace->name;
      }
    }

    const auto pattern = session.configuration.window_title.view();

    return WindowTitle::render(pattern.empty() ? WindowTitle::default_title : pattern, tokens);
  }

  void setRefreshRate(Session& session, std::uint16_t fps) noexcept {
    Access::displayFps(session) = std::clamp(fps, Configuration::minimum_fps, Configuration::maximum_fps);
  }

  void pace(Session& session) {
    const auto& configuration = session.configuration;
    const auto maximum_fps = configuration.max_fps == 0 ? ds::none : ds::Option{configuration.max_fps};
    const auto interval_ns = FramePacer::resolveInterval(FramePacer::nanoseconds_per_second / Access::displayFps(session), maximum_fps);

    session.link.send(ConfigureFrameInterval{static_cast<std::uint32_t>(interval_ns)});
  }

}
