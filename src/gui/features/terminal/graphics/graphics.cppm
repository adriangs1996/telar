module;
#include "tbc/annotations.hpp"

// The images in a terminal: what each pane holds as the runtime sends them, the textures a
// frame draws them with and where, and the panes whose images pause after a limit until they ask
// the runtime again.
export module telar.gui.features.terminal.graphics;

export import :store;
export import :residency;
export import :placement;
export import :artwork;
// Exported as every interface partition must be; it exports nothing.
export import :pauses;

import std;

import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::graphics {

  struct Access;

}

export namespace telar::gui::features::terminal::graphics {

  // The panes paused after a limit. Opaque: only the use cases below reach it. Each pane holds
  // its own GraphicsStore, which a frame reads, counting against a GraphicsBudget the panes'
  // owner keeps beside them.
  class State {
    friend struct Access;

    GraphicsPauses pauses_;
  };

  [[nodiscard]] TBC_HOT_PATH inline bool paused(const State& state, std::uint64_t pane_id) noexcept;

  // Changes whenever a pause begins, waits or ends.
  [[nodiscard]] TBC_HOT_PATH inline std::uint64_t revision(const State& state) noexcept;

  // When the next paused pane asks the runtime again; none while none waits.
  [[nodiscard]] TBC_HOT_PATH inline ds::Option<std::uint64_t> deadline(const State& state) noexcept;

  // Pane `pane_id` reached a limit at `now_ns`: its images pause. `request` asks the runtime for
  // a pane's images again, `notice` tells the user once a pause begins.
  template <typename Request, typename Notice>
    requires std::invocable<const Request&, std::uint64_t> && std::invocable<const Notice&, std::uint64_t>
  TBC_GENERIC void pause(State& state, std::uint64_t pane_id, std::uint64_t now_ns, const Request& request, const Notice& notice);

  // The paused panes whose wait ended by `now_ns` ask the runtime again, through `request`.
  template <typename Request>
    requires std::invocable<const Request&, std::uint64_t>
  TBC_GENERIC void resume(State& state, std::uint64_t now_ns, const Request& request);

  // Pane `pane_id` took the focus at `now_ns`: a paused pane asks again at once, through
  // `request`.
  template <typename Request>
    requires std::invocable<const Request&, std::uint64_t>
  TBC_GENERIC void focus(State& state, std::uint64_t pane_id, std::uint64_t now_ns, const Request& request);

  // A snapshot of pane `pane_id`'s images applied at `now_ns`: a complete one ends its pause.
  void receive(State& state, std::uint64_t pane_id, SnapshotPhase phase, std::uint64_t now_ns) noexcept;

  // The panes `mirrored` no longer finds stop pausing.
  template <typename Mirrored>
    requires std::predicate<const Mirrored&, std::uint64_t>
  TBC_GENERIC void forgetClosed(State& state, const Mirrored& mirrored);

  // The connection ended: no pane waits.
  void suspend(State& state) noexcept;

}

namespace telar::gui::features::terminal::graphics {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr GraphicsPauses& pauses(State& state) noexcept {
      return state.pauses_;
    }

    [[nodiscard]] static constexpr const GraphicsPauses& pauses(const State& state) noexcept {
      return state.pauses_;
    }
  };

  inline bool paused(const State& state, std::uint64_t pane_id) noexcept {
    return Access::pauses(state).contains(pane_id);
  }

  inline std::uint64_t revision(const State& state) noexcept {
    return Access::pauses(state).revision();
  }

  inline ds::Option<std::uint64_t> deadline(const State& state) noexcept {
    return Access::pauses(state).nextDeadline();
  }

  template <typename Request, typename Notice>
    requires std::invocable<const Request&, std::uint64_t> && std::invocable<const Notice&, std::uint64_t>
  TBC_GENERIC void pause(State& state, std::uint64_t pane_id, std::uint64_t now_ns, const Request& request, const Notice& notice) {
    Access::pauses(state).pause(pane_id, now_ns, request, notice);
  }

  template <typename Request>
    requires std::invocable<const Request&, std::uint64_t>
  TBC_GENERIC void resume(State& state, std::uint64_t now_ns, const Request& request) {
    Access::pauses(state).resumeDue(now_ns, request);
  }

  template <typename Request>
    requires std::invocable<const Request&, std::uint64_t>
  TBC_GENERIC void focus(State& state, std::uint64_t pane_id, std::uint64_t now_ns, const Request& request) {
    Access::pauses(state).focus({.pane_id = pane_id, .now_ns = now_ns}, request);
  }

  template <typename Mirrored>
    requires std::predicate<const Mirrored&, std::uint64_t>
  TBC_GENERIC void forgetClosed(State& state, const Mirrored& mirrored) {
    Access::pauses(state).forgetClosed(mirrored);
  }

}
