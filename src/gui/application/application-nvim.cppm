// The editor panes as ui drives them: a Neovim the runtime runs and the window draws natively.
// What a person types, pastes and points at goes to it, and what it shows comes back as grids
// and the surfaces Neovim leaves to its UI.
export module telar.gui.application:nvim;

import std;

import :session;
import telar.gui.features.nvim;
import telar.wire.nvim;
import telar.wire.pane_io;

export namespace telar::gui::application::nvim {

  using features::nvim::Cmdline;
  using features::nvim::Editor;
  using features::nvim::EditorCursor;
  using features::nvim::Grid;
  using features::nvim::MenuItem;
  using features::nvim::Message;
  using features::nvim::Messages;
  using features::nvim::PopupMenu;
  using features::nvim::Prompt;
  using features::nvim::Slice;
  using features::nvim::Tab;
  using features::nvim::TabLine;

  using telar::NvimMessageKind;
  using telar::NvimMouse;
  using telar::NvimMouseAction;
  using telar::NvimMouseButton;
  using telar::NvimPlacement;
  using telar::NvimPromptKind;

  // Whether the runtime of this session runs editor panes.
  [[nodiscard]] bool available(const Session& session) noexcept;

  // The editor pane `pane_id` is, as it was last shown; null for a pane that is a terminal.
  [[nodiscard]] const Editor* editor(const Session& session, std::uint64_t pane_id) noexcept;

  // Keys in Neovim's notation, as a person typed them into the pane.
  void type(Session& session, std::uint64_t pane_id, std::string_view keys);

  // Text pasted into the pane, which Neovim inserts as one change.
  void paste(Session& session, std::uint64_t pane_id, std::string_view text);

  // A mouse event on a cell of one of the pane's grids.
  void point(Session& session, const NvimMouse& event);

  // Whether the pane has the keyboard's focus in this window.
  void focus(Session& session, std::uint64_t pane_id, bool focused);

  // Gives the pane the cells that fit its view.
  void resize(Session& session, std::uint64_t pane_id, TerminalSize size);

  // What the person answered to the prompt the pane shows: the choice at `index` or the text,
  // or nothing when they dismissed it.
  void answer(Session& session, std::uint64_t pane_id, bool accepted, std::uint32_t index = 0, std::string_view text = {});

  // Shows a file in the pane, with the cursor at `line` and `column` when they are not zero.
  void show(Session& session, std::uint64_t pane_id, std::string_view path, std::uint32_t line = 0, std::uint32_t column = 0);

}

// What the session routes here. Not exported: ui never calls these.
namespace telar::gui::application::nvim {

  Change receive(Session& session, const PaneKindNotice& message);
  Change receive(Session& session, const NvimGrid& message);
  Change receive(Session& session, const NvimFrame& message);
  Change receive(Session& session, const NvimCmdline& message);
  Change receive(Session& session, const NvimPopupMenu& message);
  Change receive(Session& session, const NvimMessageList& message);
  Change receive(Session& session, const NvimTabLine& message);
  Change receive(Session& session, const NvimPrompt& message);

}
