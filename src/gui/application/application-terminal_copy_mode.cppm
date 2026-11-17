// Copy mode as ui drives it: enter it, move with keys and the pointer, search the scrollback,
// copy the selection and leave.
export module telar.gui.application:terminal_copy_mode;

import std;

import :session;
import :workspace_replica;
import telar.gui.features.terminal.copy_mode;
import telar.gui.foundation.keys;
import telar.wire.content;

export namespace telar::gui::application::terminal::copy_mode {

  using features::terminal::copy_mode::ClickTracker;
  using features::terminal::copy_mode::CopyEffect;
  using features::terminal::copy_mode::CopyModeView;
  using features::terminal::copy_mode::CopyPointer;
  using features::terminal::copy_mode::CopyPointerDecision;
  using features::terminal::copy_mode::CopyPointerInput;
  using features::terminal::copy_mode::CopyPointerKind;
  using features::terminal::copy_mode::CopyPointerOwner;
  using features::terminal::copy_mode::CopyPress;
  using features::terminal::copy_mode::CopySearchState;
  using features::terminal::copy_mode::CopyState;

  [[nodiscard]] CopyModeView view(const Session& session) noexcept;

  // Copy mode on the focused pane, at its cursor; false without an attached pane or while on.
  bool enter(Session& session) noexcept;

  // A key in copy mode: what it did, unhandled when copy mode is off.
  CopyEffect key(Session& session, const TerminalKey& key);

  void leave(Session& session);

  // A press on the focused pane begins a selection there.
  bool press(Session& session, CopyPress press) noexcept;

  // Copies the pointer's selection in pane `pane_id`; false without one.
  bool copy(Session& session, std::uint64_t pane_id);

  // The pointer over a pane while copy mode or a selection may own it: what that did with it.
  CopyPointerDecision::Outcome pointer(Session& session, const CopyPointerInput& input);

  // Searches the scrollback for `needle`, typed a letter at a time.
  void search(Session& session, std::string_view needle);

  // The search typed so far ends: its matches stay for n and N, from wherever they took the
  // cursor.
  void finishSearch(Session& session) noexcept;

  [[nodiscard]] CopySearchState searchState(const Session& session) noexcept;

  // The next match or the one before, as n and N go.
  void stepMatch(Session& session, bool forward);

  // The command whose output the search reads, while it reads only that output.
  [[nodiscard]] std::optional<std::size_t> searchBlock(const Session& session) noexcept;

  // Whether a search can be confined to a command's output, as one begun from a command can.
  [[nodiscard]] bool searchScopes(const Session& session) noexcept;

  // Between that command's output and the whole scrollback.
  void toggleSearchScope(Session& session) noexcept;

  // Whether a key asked for the scrollback search since the last call.
  [[nodiscard]] bool takeSearchRequest(Session& session) noexcept;

}

// What the session's routing and its other use cases reach of copy mode; ui never calls these.
namespace telar::gui::application::terminal::copy_mode {

  // The attached pane copy mode is on; none, and copy mode closed, once that pane is gone.
  Pane<Memory>* pane(Session& session) noexcept;

  Change receive(Session& session, const PaneMatches& message);

}
