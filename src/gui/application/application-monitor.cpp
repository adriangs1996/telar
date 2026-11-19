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

    session.link.send(features::monitor::ask(session.monitor, session.link.nextRequest()));
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

    const auto request_id = session.link.nextRequest();

    session.link.send(RequestProcessSignal{.request_id = request_id, .process = process, .signal = signal});
    session.monitor.acting = request_id;
    return true;
  }

  bool prioritize(Session& session, const ProcessInstance& process, std::int32_t nice) {
    if (!available(session) || session.monitor.acting != 0) {
      return false;
    }

    const auto request_id = session.link.nextRequest();

    session.link.send(RequestProcessPriority{.request_id = request_id, .process = process, .nice = nice});
    session.monitor.acting = request_id;
    return true;
  }

}
