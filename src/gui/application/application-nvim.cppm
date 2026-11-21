// The editor panes as ui drives them: a Neovim the runtime runs and the window draws natively.
// What a person types, pastes and points at goes to it, and what it shows comes back as grids
// and the surfaces Neovim leaves to its UI.
export module telar.gui.application:nvim;

import std;

import :session;
import telar.gui.features.nvim;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;

export namespace telar::gui::application::nvim {

  using features::nvim::Cmdline;
  using features::nvim::Editor;
  using features::nvim::EditorCursor;
  using features::nvim::Grid;
  using features::nvim::Key;
  using features::nvim::KeyText;
  using features::nvim::MenuItem;
  using features::nvim::Message;
  using features::nvim::Messages;
  using features::nvim::Picker;
  using features::nvim::PickMatch;
  using features::nvim::PopupMenu;
  using features::nvim::Prompt;
  using features::nvim::Slice;
  using features::nvim::Tab;
  using features::nvim::TabLine;

  using telar::NvimMessageKind;
  using telar::NvimMouse;
  using telar::NvimMouseAction;
  using telar::NvimMouseButton;
  using telar::NvimOpenIn;
  using telar::NvimPickSource;
  using telar::NvimPlacement;
  using telar::NvimPromptKind;

  using features::nvim::notation;

  // The modifier keys held with a mouse event, as the bits of NvimMouse::modifiers.
  inline constexpr Byte mouse_shift = telar::nvim_mouse_shift;
  inline constexpr Byte mouse_control = telar::nvim_mouse_control;
  inline constexpr Byte mouse_alt = telar::nvim_mouse_alt;
  inline constexpr Byte mouse_command = telar::nvim_mouse_command;

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

  // A place in a file: its line and column count from one, zero for wherever the cursor is.
  struct Place {
    std::string_view path;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    NvimOpenIn in = NvimOpenIn::place;
  };

  // Shows a file in the pane, where `place.in` says.
  void show(Session& session, std::uint64_t pane_id, const Place& place);

  // The editor pane of the tab `pane_id` is in, which a file a person points at opens in; zero
  // when the tab has none.
  [[nodiscard]] std::uint64_t beside(const Session& session, std::uint64_t pane_id) noexcept;

  // Shows a file in the editor of the tab `pane_id` is in, which takes the focus, or in one made
  // beside the focused pane when the tab has none. False when neither could be done.
  bool edit(Session& session, std::uint64_t pane_id, const Place& place);

  // Opens the pane's picker on a source: files by name, lines of files by their text, or the
  // editor's buffers, under the directory the editor works in. It lists what an empty query finds.
  void pick(Session& session, std::uint64_t pane_id, NvimPickSource source);

  // The query typed in the pane's picker: the runtime searches, and the list follows.
  void search(Session& session, std::uint64_t pane_id, std::string_view query);

  // Opens what the picker lists at `index` where `in` says, and closes the picker.
  void accept(Session& session, std::uint64_t pane_id, std::size_t index, NvimOpenIn in = NvimOpenIn::place);

  // The cells of the editor a picker leaves for its preview, from its top left one.
  struct PreviewArea {
    std::uint16_t row = 0;
    std::uint16_t column = 0;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
  };

  // Shows what the picker lists at `index` in a float of the editor over `area`, which takes
  // no focus; without an index, closes that float.
  void preview(Session& session, std::uint64_t pane_id, ds::Option<std::size_t> index, PreviewArea area);

  // Sends the entries marked in the picker to the editor's quickfix list, and closes the picker.
  void list(Session& session, std::uint64_t pane_id, std::span<const std::uint32_t> indices);

  // Closes the pane's picker and its preview.
  void dismiss(Session& session, std::uint64_t pane_id);

  // Moves to the editor's window on a side of its current one. When it has none there, the
  // runtime says so and the pane on that side takes the focus.
  void navigate(Session& session, std::uint64_t pane_id, PaneDirection direction);

  // Selects an item of the completion menu, counted among all it has, and takes it when `accept`.
  void choose(Session& session, std::uint64_t pane_id, std::uint32_t item, bool accept);

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
  Change receive(Session& session, const NvimNavigated& message);
  Change receive(Session& session, const NvimPick& message);
  Change receive(Session& session, const TextResults& message);
  // The paths a picker of an editor waited for; none when no picker did.
  ds::Option<Change> receive(Session& session, const PathResults& message);

}
