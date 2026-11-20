module telar.gui.application;

import std;

import telar.gui.features.monitor;
import telar.wire.monitor;

namespace telar::gui::application::monitor {

  bool available(const Session& session) noexcept {
    return session.ready() && session.monitors();
  }

  bool refresh(Session& session) {
    if (!available(session) || session.monitor.waiting != 0) {
      return false;
    }

    const auto asked = session.link.ask(features::monitor::query(session.monitor));
    if (!asked) {
      return false;
    }

    features::monitor::wait(session.monitor, *asked);
    return true;
  }

  const State& state(const Session& session) noexcept {
    return session.monitor;
  }

  View& view(Session& session) noexcept {
    return session.monitor.view;
  }

  bool signal(Session& session, const ProcessInstance& process, ProcessSignal signal) {
    if (!available(session) || session.monitor.acting != 0) {
      return false;
    }

    const auto asked = session.link.ask(RequestProcessSignal{.process = process, .signal = signal});
    if (!asked) {
      return false;
    }

    session.monitor.acting = *asked;
    return true;
  }

  bool prioritize(Session& session, const ProcessInstance& process, std::int32_t nice) {
    if (!available(session) || session.monitor.acting != 0) {
      return false;
    }

    const auto asked = session.link.ask(RequestProcessPriority{.process = process, .nice = nice});
    if (!asked) {
      return false;
    }

    session.monitor.acting = *asked;
    return true;
  }

}
