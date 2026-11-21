// The editor pane: a Neovim the runtime runs and this window draws natively. What the runtime
// sends of its screen is kept here, a grid for each window and float, with the surfaces Neovim
// leaves to its UI: the command line, the completion menu, the messages, the tabs and what
// vim.ui asks.
export module telar.gui.features.nvim;

import std;

import telar.base.ds;
import telar.base.memory.allocators;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;

namespace telar::gui::features::nvim {

  struct Access;

}

export namespace telar::gui::features::nvim {

  // A piece of a surface's text, which holds the texts of all its entries one after another.
  struct Slice {
    std::uint32_t offset = 0;
    std::uint32_t size = 0;

    [[nodiscard]] constexpr std::string_view of(std::string_view text) const noexcept {
      return text.substr(std::min<std::size_t>(offset, text.size()), size);
    }
  };

  // One grid of an editor: the default grid, a window or a float. Its cells are a screen the
  // terminal's painter draws; the rest says where it goes and what of its buffer it shows.
  struct Grid {
    explicit Grid(Memory& memory, std::uint32_t identity);

    std::uint32_t id;
    Screen<Memory> screen;
    NvimPlacement placement = NvimPlacement::hidden;
    bool mouse_enabled = false;
    // A window's place on the default grid, or a float's on the editor, in cells.
    std::int32_t row = 0;
    std::int32_t column = 0;
    std::uint16_t width = 0;
    std::uint16_t height = 0;
    std::uint32_t z_index = 0;
    std::uint32_t composition_index = 0;
    std::uint64_t window = 0;
    // The buffer lines the window shows, for a scrollbar no one asks Neovim about.
    std::uint32_t top_line = 0;
    std::uint32_t bottom_line = 0;
    std::uint32_t cursor_line = 0;
    std::uint32_t line_count = 0;
    // The lines the window's top line has moved since the grid was made, summed: its change
    // between two frames is how far the text scrolled.
    std::int64_t scrolled_lines = 0;
    std::uint16_t margin_top = 0;
    std::uint16_t margin_bottom = 0;
    std::uint16_t margin_left = 0;
    std::uint16_t margin_right = 0;
    // The frame that last named it: a frame that stands alone drops the grids it does not name.
    std::uint64_t frame = 0;
  };

  struct Cmdline {
    explicit Cmdline(Memory& memory);

    bool visible = false;
    std::uint32_t level = 0;
    // `:` `/` or `?`; zero for a prompt of input().
    char first = 0;
    char special = 0;
    // The cursor, as a byte of `text`.
    std::uint32_t position = 0;
    std::uint32_t indent = 0;
    ds::String<Memory> prompt;
    ds::String<Memory> text;
    ds::String<Memory> block;
  };

  struct MenuItem {
    Slice word;
    Slice kind;
    Slice menu;
  };

  struct PopupMenu {
    explicit PopupMenu(Memory& memory);

    bool visible = false;
    // The item selected among all the menu has, -1 for none.
    std::int32_t selected = -1;
    // The cell it hangs from: on a grid, or on the command line when `grid` is -1.
    std::int32_t grid = 0;
    std::int32_t row = 0;
    std::int32_t column = 0;
    // The index of the first of `items` among all the menu has, and how many it has.
    std::uint32_t first = 0;
    std::uint32_t total = 0;
    ds::Vec<char, Memory> text;
    ds::Vec<MenuItem, Memory> items;
  };

  struct Message {
    std::uint64_t id = 0;
    NvimMessageKind kind = NvimMessageKind::plain;
    Slice text;
  };

  struct Messages {
    explicit Messages(Memory& memory);

    // "-- INSERT --", the keys of a command being typed, and the ruler; each empty when hidden.
    ds::String<Memory> mode;
    ds::String<Memory> command;
    ds::String<Memory> ruler;
    ds::Vec<char, Memory> text;
    // The messages shown now, oldest first.
    ds::Vec<Message, Memory> items;
  };

  struct Tab {
    std::uint64_t handle = 0;
    Slice name;
  };

  struct TabLine {
    explicit TabLine(Memory& memory);

    std::uint64_t current_tab = 0;
    std::uint64_t current_buffer = 0;
    ds::Vec<char, Memory> text;
    ds::Vec<Tab, Memory> tabs;
    ds::Vec<Tab, Memory> buffers;
  };

  // What vim.ui.select or vim.ui.input asks; `id` is zero while nothing is asked.
  struct Prompt {
    explicit Prompt(Memory& memory);

    std::uint64_t id = 0;
    std::uint64_t serial = 0;
    NvimPromptKind kind = NvimPromptKind::none;
    ds::String<Memory> title;
    ds::String<Memory> initial;
    ds::Vec<char, Memory> text;
    ds::Vec<Slice, Memory> choices;
  };

  struct EditorCursor {
    std::uint32_t grid = 0;
    std::uint16_t row = 0;
    std::uint16_t column = 0;
    bool visible = false;
    CursorShape shape = CursorShape::block;
    // How much of its cell a bar or an underline covers, in hundredths.
    Byte percentage = 100;
    std::uint16_t blink_wait_ms = 0;
    std::uint16_t blink_on_ms = 0;
    std::uint16_t blink_off_ms = 0;

    bool operator==(const EditorCursor&) const = default;
  };

  // One editor pane as the window draws it. Each `*_revision` changes when what it names does,
  // so a view redraws only what changed.
  struct Editor {
    explicit Editor(Memory& memory, std::uint64_t pane);

    [[nodiscard]] const Grid* grid(std::uint32_t id) const noexcept;

    std::uint64_t pane_id;
    // The grids, in the order Neovim made them.
    ds::Vec<ds::Box<Grid, Memory>, Memory> grids;
    // The last frame applied; zero before the first and after the connection was lost.
    std::uint64_t frame = 0;
    // The runtime was asked for the screen whole: what does not start over is passed by.
    bool resyncing = false;
    EditorCursor cursor;
    ds::String<Memory> mode;
    Cmdline cmdline;
    PopupMenu menu;
    Messages messages;
    TabLine tabs;
    Prompt prompt;
    // Every frame applied.
    std::uint64_t revision = 0;
    // The grids there are, where each is placed and what of its buffer it shows.
    std::uint64_t layout_revision = 0;
    std::uint64_t cmdline_revision = 0;
    std::uint64_t menu_revision = 0;
    std::uint64_t messages_revision = 0;
    std::uint64_t tabs_revision = 0;
    std::uint64_t prompt_revision = 0;
  };

  // A key as Neovim names keys: one of its named keys or a character, and what is held with it.
  struct Key {
    // "Esc", "CR", "F5" and the like; empty for a character.
    std::string_view name;
    std::uint32_t codepoint = 0;
    bool control = false;
    bool alt = false;
    bool shift = false;
    bool super = false;
  };

  // A key in the notation nvim_input() reads: `a`, `<lt>`, `<C-w>`, `<S-Tab>`, `<D-s>`.
  struct KeyText {
    static constexpr std::size_t capacity = 32;

    [[nodiscard]] constexpr std::string_view view() const noexcept {
      return std::string_view{bytes.data(), size};
    }

    ds::Array<char, capacity> bytes{};
    std::uint8_t size = 0;
  };

  // How Neovim is told the key. A character typed with nothing but shift goes as itself, so
  // every combination a keyboard makes reaches Neovim and none is mistaken for another.
  [[nodiscard]] KeyText notation(const Key& key) noexcept;

  // What a message of the runtime did to an editor.
  enum class Received : std::uint8_t {
    // It names no editor of this window, or it is older than what is shown.
    ignored,
    // Kept, to be shown with the frame it belongs to.
    staged,
    // A frame ended, or a prompt changed: the view shows what the editor holds now.
    presented,
    // It does not follow what the editor holds: the runtime is to send its screen whole. Said
    // once; what arrives until the screen does is ignored.
    lost,
  };

  // The editors of a session's panes. Opaque: only the use cases below reach it.
  class State {
    friend struct Access;

  public:
    explicit State(Memory& memory);

  private:
    Memory& memory_;
    ds::Vec<ds::Box<Editor, Memory>, Memory> editors_;
  };

  // The runtime said a pane is an editor, before the message that names it.
  void announce(State& state, const PaneKindNotice& notice);

  // The pane is gone.
  void forget(State& state, std::uint64_t pane_id) noexcept;

  // The connection was lost: each editor's next frame stands alone.
  void detach(State& state) noexcept;

  // The editor a pane is; null for a pane that is a terminal.
  [[nodiscard]] const Editor* find(const State& state, std::uint64_t pane_id) noexcept;

  Received receive(State& state, const NvimGrid& grid);
  Received receive(State& state, const NvimFrame& frame);
  Received receive(State& state, const NvimCmdline& cmdline);
  Received receive(State& state, const NvimPopupMenu& menu);
  Received receive(State& state, const NvimMessageList& messages);
  Received receive(State& state, const NvimTabLine& tabs);
  Received receive(State& state, const NvimPrompt& prompt);

  // The reply to the prompt the editor shows, which is then closed here: the runtime confirms
  // it with a prompt of its own. None when the editor shows no prompt.
  [[nodiscard]] ds::Option<NvimPromptReply> answer(State& state, std::uint64_t pane_id, bool accepted, std::uint32_t index, std::string_view text);

}

namespace telar::gui::features::nvim {

  struct Access {
    [[nodiscard]] static constexpr Memory& memory(State& state) noexcept {
      return state.memory_;
    }

    [[nodiscard]] static constexpr ds::Vec<ds::Box<Editor, Memory>, Memory>& editors(State& state) noexcept {
      return state.editors_;
    }

    [[nodiscard]] static constexpr const ds::Vec<ds::Box<Editor, Memory>, Memory>& editors(const State& state) noexcept {
      return state.editors_;
    }

    [[nodiscard]] static Editor* find(State& state, std::uint64_t pane_id) noexcept;
  };

}
