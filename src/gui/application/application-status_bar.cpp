module telar.gui.application;

import std;

import telar.gui.features.status_bar;
import telar.wire.vocabulary;

namespace telar::gui::application::status_bar {

  HostMetrics metrics(const Session& session) noexcept {
    return features::status_bar::metrics(session.status_bar);
  }

  Change receive(Session& session, const SystemMetrics& sample) {
    return features::status_bar::receive(session.status_bar, sample) ? Change::metrics : Change::none;
  }

}
