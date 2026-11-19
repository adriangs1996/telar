// The links in a terminal: recognizing one in the cells, hovering and pressing it, and opening
// a file link in an editor beside its pane.
export module telar.gui.features.terminal.links;

export import :text;
export import :editor;
export import :pointer;
export import :presentation;
// Exported as every interface partition must be; it exports nothing.
export import :opening;

import std;

import telar.wire.editor;
import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::terminal::links {

  struct Access;

}

export namespace telar::gui::features::terminal::links {

  // The editor request the runtime has yet to answer. Opaque: only the use cases below reach it.
  // The pointer's state over a link lives in each terminal, which reads it on every move.
  class State {
    friend struct Access;

    EditorOpening opening_;
  };

  // Opens `request`'s editor in its source pane, the runtime answering under its id: the message
  // to send, which views `request`. Throws while another request is pending.
  [[nodiscard]] tbc::view<OpenEditor, tbc::lt::a> open(State& state, tbc::view<const EditorRequest&, tbc::lt::a> request);

  // The runtime answered `request_id`, or it failed: the request it answered, none when it is
  // not the one pending.
  [[nodiscard]] ds::Option<EditorRequest> complete(State& state, std::uint64_t request_id);

  [[nodiscard]] bool pending(const State& state, std::uint64_t request_id) noexcept;

  // The connection ended: no request will be answered.
  void suspend(State& state) noexcept;

}

namespace telar::gui::features::terminal::links {

  // The use cases' way into State.
  struct Access {
    [[nodiscard]] static constexpr EditorOpening& opening(State& state) noexcept {
      return state.opening_;
    }

    [[nodiscard]] static constexpr const EditorOpening& opening(const State& state) noexcept {
      return state.opening_;
    }
  };

}
