module telar.gui.application;

import std;

import :access;
import telar.gui.features.status_bar;
import telar.wire.vocabulary;

namespace telar::gui::application::status_bar {

  HostMetrics metrics(const Session& session) noexcept {
    return features::status_bar::metrics(Access::statusBar(session));
  }

  Change receive(Session& session, const SystemMetrics& sample) {
    return features::status_bar::receive(Access::statusBar(session), sample) ? Change::metrics : Change::none;
  }

}
