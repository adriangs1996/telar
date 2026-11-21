module telar.gui.features.nvim;

import std;

import telar.base.ds;
import telar.base.memory.allocators;
import telar.tbc;
import telar.gui.foundation.core;
import telar.gui.foundation.terminal;
import telar.wire.nvim;
import telar.wire.pane_io;
import telar.wire.vocabulary;

namespace telar::gui::features::nvim {

  namespace {

    void write(KeyText& text, std::string_view added) {
      const auto room = KeyText::capacity - text.size;
      const auto kept = added.substr(0, std::min(added.size(), room));

      std::ranges::copy(kept, text.bytes.viewMut().subspan(text.size).begin());
      text.size = static_cast<std::uint8_t>(text.size + kept.size());
    }

    // Appends `added` to a surface's text and says where it lies there.
    Slice append(ds::Vec<char, Memory>& text, std::string_view added) {
      const Slice slice{.offset = static_cast<std::uint32_t>(text.size()), .size = static_cast<std::uint32_t>(added.size())};

      text.extend(std::span<const char>{added});
      return slice;
    }

    Grid* gridOf(Editor& editor, std::uint32_t id) noexcept {
      for (auto& grid : editor.grids.viewMut()) {
        if (grid->id == id) {
          return &grid.getMut();
        }
      }

      return nullptr;
    }

    // The editor cannot follow what it was sent: it waits for its screen whole.
    Received lose(Editor& editor) noexcept {
      if (editor.resyncing) {
        return Received::ignored;
      }

      editor.resyncing = true;
      editor.frame = 0;
      return Received::lost;
    }

    // Whether a grid's place or what it shows of its buffer differs from what `message` says.
    bool placedAs(const Grid& grid, const NvimGrid& message) noexcept {
      return grid.placement == message.placement && grid.row == message.row && grid.column == message.column && grid.width == message.width && grid.height == message.height &&
             grid.z_index == message.z_index && grid.composition_index == message.composition_index && grid.window == message.window && grid.top_line == message.top_line &&
             grid.bottom_line == message.bottom_line && grid.cursor_line == message.cursor_line && grid.line_count == message.line_count && grid.scrolled_lines == message.scrolled_lines &&
             grid.margin_top == message.margin_top && grid.margin_bottom == message.margin_bottom && grid.margin_left == message.margin_left && grid.margin_right == message.margin_right &&
             grid.mouse_enabled == message.mouse_enabled;
    }

    void place(Grid& grid, const NvimGrid& message) noexcept {
      grid.placement = message.placement;
      grid.mouse_enabled = message.mouse_enabled;
      grid.row = message.row;
      grid.column = message.column;
      grid.width = message.width;
      grid.height = message.height;
      grid.z_index = message.z_index;
      grid.composition_index = message.composition_index;
      grid.window = message.window;
      grid.top_line = message.top_line;
      grid.bottom_line = message.bottom_line;
      grid.cursor_line = message.cursor_line;
      grid.line_count = message.line_count;
      grid.scrolled_lines = message.scrolled_lines;
      grid.margin_top = message.margin_top;
      grid.margin_bottom = message.margin_bottom;
      grid.margin_left = message.margin_left;
      grid.margin_right = message.margin_right;
    }

    // What a grid's message did to the grid it names.
    enum class Drawn : std::uint8_t {
      // Its cells do not fit the grid as it is.
      lost,
      // Cells changed, or nothing did.
      cells,
      // Its place, or what it shows of its buffer, changed too.
      placed,
    };

    // Applies a grid's message to the grid it names: the rows a scroll moves, the cells that
    // changed, and where the grid goes.
    Drawn draw(Grid& grid, const NvimGrid& message) {
      for (const auto& scroll : message.scrolls) {
        if (!grid.screen.moveRows({.top = scroll.top, .bottom = scroll.bottom, .left = scroll.left, .right = scroll.right, .rows = scroll.rows})) {
          return Drawn::lost;
        }
      }

      if (!grid.screen.draw({.columns = message.columns, .rows = message.rows}, message.full, message.spans)) {
        return Drawn::lost;
      }

      grid.frame = message.frame_id;
      if (placedAs(grid, message)) {
        return Drawn::cells;
      }

      place(grid, message);
      return Drawn::placed;
    }

    // A grid's message for an editor that follows what it is sent: the grid is made when it is
    // new, then drawn; the editor's layout changes once nothing of the grid is held.
    Received applyGrid(Editor& editor, const NvimGrid& message) {
      const bool known = editor.grid(message.grid) != nullptr;

      // A grid the editor does not have starts with all its cells.
      if (!known && !message.full) {
        return lose(editor);
      }

      if (!known) {
        auto& made_in = editor.memory;

        editor.grids.push(ds::makeBox<Grid>(made_in, made_in, message.grid));
      }

      const auto drawn = draw(*gridOf(editor, message.grid), message);
      if (drawn == Drawn::lost) {
        return lose(editor);
      }

      if (!known || drawn == Drawn::placed) {
        ++editor.layout_revision;
      }

      return Received::staged;
    }

    // Draws the cursor on the grid it is on and takes it off the others, so the painter of each
    // grid draws it or not from the grid's own screen.
    void placeCursor(Editor& editor) noexcept {
      for (auto& grid : editor.grids.viewMut()) {
        const auto& cursor = editor.cursor;
        const bool here = cursor.visible && grid->id == cursor.grid && cursor.column < grid->screen.columns() && cursor.row < grid->screen.rows();

        grid.getMut().screen.placeCursor(here ? Cursor{.visible = true, .x = cursor.column, .y = cursor.row, .shape = cursor.shape, .blink = cursor.blink_on_ms != 0} : Cursor{});
      }
    }

  }

  KeyText notation(const Key& key) {
    KeyText text;
    const bool modified = key.control || key.alt || key.super;
    // A codepoint that is no character is written as nothing: the function throws nothing.
    const auto character = Utf8Scalar::valid(key.codepoint) ? Utf8Scalar::encode(key.codepoint) : Utf8Scalar{};
    auto name = key.name;

    if (name.empty()) {
      if (key.codepoint == '<') {
        // Written by name: a bare `<` would open a key name.
        name = "lt";
      } else if (key.codepoint == ' ' && (modified || key.shift)) {
        name = "Space";
      } else if (!modified) {
        write(text, character.view());
        return text;
      } else {
        name = character.view();
      }
    }

    write(text, "<");
    for (const auto& [held, prefix] : {std::pair{key.control, std::string_view{"C-"}}, std::pair{key.alt, std::string_view{"A-"}}, std::pair{key.shift && (modified || !key.name.empty() || key.codepoint == ' '), std::string_view{"S-"}}, std::pair{key.super, std::string_view{"D-"}}}) {
      if (held) {
        write(text, prefix);
      }
    }

    write(text, name);
    write(text, ">");
    return text;
  }

  Grid::Grid(Memory& memory, std::uint32_t identity)
      : id(identity),
        screen(memory) {}

  Cmdline::Cmdline(Memory& memory)
      : prompt(memory),
        text(memory),
        block(memory) {}

  PopupMenu::PopupMenu(Memory& memory)
      : text(memory),
        items(memory) {}

  Messages::Messages(Memory& memory)
      : mode(memory),
        command(memory),
        ruler(memory),
        text(memory),
        items(memory) {}

  TabLine::TabLine(Memory& memory)
      : text(memory),
        tabs(memory),
        buffers(memory) {}

  Prompt::Prompt(Memory& memory)
      : title(memory),
        initial(memory),
        text(memory),
        choices(memory) {}

  Editor::Editor(Memory& made_in, std::uint64_t pane)
      : memory(made_in),
        pane_id(pane),
        grids(made_in),
        mode(made_in),
        cmdline(made_in),
        menu(made_in),
        messages(made_in),
        tabs(made_in),
        prompt(made_in) {}

  const Grid* Editor::grid(std::uint32_t id) const noexcept {
    for (const auto& grid : grids) {
      if (grid->id == id) {
        return &grid.get();
      }
    }

    return nullptr;
  }

  State::State(Memory& memory)
      : memory_(memory),
        editors_(memory) {}

  Editor* Access::find(State& state, std::uint64_t pane_id) noexcept {
    for (auto& editor : state.editors_.viewMut()) {
      if (editor->pane_id == pane_id) {
        return &editor.getMut();
      }
    }

    return nullptr;
  }

  void announce(State& state, const PaneKindNotice& notice) {
    if (notice.kind != PaneKind::nvim || Access::find(state, notice.pane_id) != nullptr) {
      return;
    }

    Access::editors(state).push(ds::makeBox<Editor>(Access::memory(state), Access::memory(state), notice.pane_id));
  }

  void forget(State& state, std::uint64_t pane_id) noexcept {
    static_cast<void>(Access::editors(state).retain([pane_id](const auto& editor) {
      return editor->pane_id != pane_id;
    }));
  }

  void detach(State& state) noexcept {
    for (auto& editor : Access::editors(state).viewMut()) {
      editor.getMut().frame = 0;
      editor.getMut().resyncing = false;
    }
  }

  const Editor* find(const State& state, std::uint64_t pane_id) noexcept {
    for (const auto& editor : Access::editors(state)) {
      if (editor->pane_id == pane_id) {
        return &editor.get();
      }
    }

    return nullptr;
  }

  Received receive(State& state, const NvimGrid& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    if (editor->resyncing && !message.full) {
      return Received::ignored;
    }

    return applyGrid(*editor, message);
  }

  Received receive(State& state, const NvimFrame& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    if (message.base_frame_id != 0 && (editor->resyncing || message.base_frame_id != editor->frame)) {
      return lose(*editor);
    }

    editor->resyncing = false;

    const auto before = editor->grids.size();

    // A frame that stands alone names every grid there is; another names the ones that went.
    static_cast<void>(editor->grids.retain([&](const auto& grid) {
      return message.base_frame_id == 0 ? grid->frame == message.frame_id : std::ranges::find(message.removed, grid->id) == message.removed.end();
    }));

    if (editor->grids.size() != before) {
      ++editor->layout_revision;
    }

    editor->cursor = {
        .grid = message.cursor_grid,
        .row = message.cursor_row,
        .column = message.cursor_column,
        .visible = message.cursor_visible,
        .shape = message.cursor_shape,
        .percentage = message.cursor_percentage,
        .blink_wait_ms = message.blink_wait_ms,
        .blink_on_ms = message.blink_on_ms,
        .blink_off_ms = message.blink_off_ms,
    };

    placeCursor(*editor);
    if (editor->mode.view() != message.mode) {
      editor->mode.assign(message.mode);
    }

    editor->frame = message.frame_id;
    ++editor->revision;
    return Received::presented;
  }

  Received receive(State& state, const NvimCmdline& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    auto& line = editor->cmdline;

    line.visible = message.visible;
    line.level = message.level;
    line.first = static_cast<char>(message.first);
    line.special = static_cast<char>(message.special);
    line.position = message.position;
    line.indent = message.indent;
    line.prompt.assign(message.prompt);
    line.text.assign(message.text);
    line.block.assign(message.block);
    ++editor->cmdline_revision;
    return Received::staged;
  }

  Received receive(State& state, const NvimPopupMenu& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    auto& menu = editor->menu;

    menu.visible = message.visible;
    menu.selected = message.selected;
    menu.grid = message.grid;
    menu.row = message.row;
    menu.column = message.column;
    menu.total = message.total;
    if (!message.keeps_items) {
      menu.first = message.first;
      menu.text.clear();
      menu.items.clear();

      for (const auto& item : message.items) {
        // Appended one after another: each slice is taken before the next text is added.
        const auto word = append(menu.text, item.word);
        const auto kind = append(menu.text, item.kind);
        const auto note = append(menu.text, item.menu);

        menu.items.push({.word = word, .kind = kind, .menu = note});
      }
    }

    ++editor->menu_revision;
    return Received::staged;
  }

  Received receive(State& state, const NvimMessageList& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    auto& messages = editor->messages;

    messages.mode.assign(message.mode);
    messages.command.assign(message.command);
    messages.ruler.assign(message.ruler);
    messages.text.clear();
    messages.items.clear();

    for (const auto& item : message.messages) {
      const auto text = append(messages.text, item.text);

      messages.items.push({.id = item.id, .kind = item.kind, .text = text});
    }

    ++editor->messages_revision;
    return Received::staged;
  }

  Received receive(State& state, const NvimTabLine& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.frame_id <= editor->frame) {
      return Received::ignored;
    }

    auto& tabs = editor->tabs;

    tabs.current_tab = message.current_tab;
    tabs.current_buffer = message.current_buffer;
    tabs.text.clear();
    tabs.tabs.clear();
    tabs.buffers.clear();

    for (const auto& tab : message.tabs) {
      const auto name = append(tabs.text, tab.name);

      tabs.tabs.push({.handle = tab.handle, .name = name});
    }

    for (const auto& buffer : message.buffers) {
      const auto name = append(tabs.text, buffer.name);

      tabs.buffers.push({.handle = buffer.handle, .name = name});
    }

    ++editor->tabs_revision;
    return Received::staged;
  }

  Received receive(State& state, const NvimPrompt& message) {
    auto* editor = Access::find(state, message.pane_id);
    if (editor == nullptr || message.serial <= editor->prompt.serial) {
      return Received::ignored;
    }

    auto& prompt = editor->prompt;

    prompt.serial = message.serial;
    prompt.id = message.kind == NvimPromptKind::none ? 0 : message.prompt_id;
    prompt.kind = prompt.id == 0 ? NvimPromptKind::none : message.kind;
    prompt.title.assign(message.title);
    prompt.initial.assign(message.initial);
    prompt.text.clear();
    prompt.choices.clear();

    for (const auto choice : message.choices) {
      prompt.choices.push(append(prompt.text, choice));
    }

    ++editor->prompt_revision;
    return Received::presented;
  }

  tbc::val_a<ds::Option<NvimPromptReply>> answer(State& state, std::uint64_t pane_id, bool accepted, std::uint32_t index, tbc::val_a<std::string_view> text) {
    auto* editor = Access::find(state, pane_id);
    if (editor == nullptr || editor->prompt.id == 0) {
      return ds::none;
    }

    const NvimPromptReply reply{.pane_id = pane_id, .prompt_id = editor->prompt.id, .accepted = accepted, .index = index, .text = text};

    // Closed at once, so the answer is not sent twice while the runtime's confirmation travels.
    editor->prompt.id = 0;
    editor->prompt.kind = NvimPromptKind::none;
    ++editor->prompt_revision;
    return reply;
  }

}
