module telar.gui.features.terminal.graphics;

import std;

import telar.wire.vocabulary;

namespace telar::gui::features::terminal::graphics {

  void receive(State& state, std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept {
    Access::pauses(state).snapshotApplied(pane_id, phase, now_ns);
  }

  void suspend(State& state) noexcept {
    Access::pauses(state).reset();
  }

}
