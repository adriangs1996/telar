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
             grid.mouse_enabled == message.mouse_enabled && grid.border == message.border && grid.title.view() == message.title && grid.footer.view() == message.footer;
    }

    void place(Grid& grid, const NvimGrid& message) {
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
      grid.border = message.border;
      grid.title.assign(message.title);
      grid.footer.assign(message.footer);
    }

    // Keeps the rows a scroll of the whole grid is about to take off it. A scroll of part of the
    // grid keeps none: the rows around it stay where they are, and a view does not slide them.
    void keepDeparted(Grid& grid, const NvimScroll& scroll) {
      auto& departed = grid.departed;
      const auto rows = grid.screen.rows();
      const auto columns = grid.screen.columns();
      const auto leaving = static_cast<std::size_t>(std::abs(static_cast<std::int64_t>(scroll.rows)));

      if (scroll.top != 0 || scroll.bottom != rows || scroll.left != 0 || scroll.right != columns || leaving == 0 || leaving >= rows) {
        departed.count = 0;
        return;
      }

      const bool above = scroll.rows > 0;

      if (departed.columns != columns || departed.capacity != rows) {
        departed.cells.clear();
        departed.cells.resize(static_cast<std::size_t>(rows) * columns);
        departed.stamps.clear();
        departed.stamps.resize(rows);
        departed.columns = columns;
        departed.capacity = rows;
        departed.count = 0;
        departed.head = 0;
      }

      if (departed.above != above) {
        departed.count = 0;
      }

      departed.above = above;
      // The row that ends nearest the grid is kept last, so it is the first found.
      for (std::size_t index = 0; index < leaving; ++index) {
        const auto source = grid.screen.row(above ? index : rows - 1 - index);

        departed.head = static_cast<std::uint16_t>((departed.head + departed.capacity - 1) % departed.capacity);
        std::ranges::copy(source, departed.cells.viewMut().subspan(static_cast<std::size_t>(departed.head) * columns, columns).begin());
        departed.stamps.atMut(departed.head) = ++departed.last_stamp;
        departed.count = static_cast<std::uint16_t>(std::min<std::size_t>(departed.count + 1U, departed.capacity));
      }

      departed.moved += scroll.rows;
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
      if (message.full) {
        grid.departed.count = 0;
      }

      for (const auto& scroll : message.scrolls) {
        keepDeparted(grid, scroll);
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

  DepartedRows::DepartedRows(Memory& memory)
      : cells(memory),
        stamps(memory) {}

  std::span<const CellValue> DepartedRows::row(std::size_t index) const noexcept {
    if (index >= count) {
      return {};
    }

    return std::span<const CellValue>{cells}.subspan(((head + index) % capacity) * columns, columns);
  }

  std::uint64_t DepartedRows::stamp(std::size_t index) const noexcept {
    return index < count ? stamps[(head + index) % capacity] : 0;
  }

  Picker::Picker(Memory& memory)
      : root(memory),
        query(memory),
        text(memory),
        positions(memory),
        matches(memory) {}

  Grid::Grid(Memory& memory, std::uint32_t identity)
      : id(identity),
        screen(memory),
        departed(memory),
        title(memory),
        footer(memory) {}

  Cmdline::Cmdline(Memory& memory)
      : prompt(memory),
        text(memory),
        block(memory),
        runs(memory) {}

  PopupMenu::PopupMenu(Memory& memory)
      : text(memory),
        items(memory),
        info(memory) {}

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
        origin(memory),
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
        prompt(made_in),
        picker(made_in),
        link(made_in) {}

  namespace {

    // A cell whose text is a symbol of the private use areas, where the Nerd Fonts keep their
    // icons: U+E000 to U+F8FF, and the planes from U+F0000.
    bool symbol(std::string_view text) noexcept {
      constexpr unsigned char basic = 0xEE;
      constexpr unsigned char basic_end = 0xEF;
      constexpr unsigned char basic_last = 0xA3;
      constexpr unsigned char plane = 0xF3;
      constexpr unsigned char plane_first = 0xB0;
      constexpr unsigned char last_plane = 0xF4;

      if (text.size() < 3) {
        return false;
      }

      const auto lead = static_cast<unsigned char>(text[0]);
      const auto next = static_cast<unsigned char>(text[1]);

      return lead == basic || (lead == basic_end && next <= basic_last) || (lead == plane && next >= plane_first && text.size() >= 4) || (lead == last_plane && text.size() >= 4);
    }

    // What a cell is drawn on: its background, or its foreground when reversed.
    CellColor groundOf(const CellStyle& style) noexcept {
      return (style.flags & std::to_underlying(CellAttribute::inverse)) != 0 ? style.foreground : style.background;
    }

    bool blank(const CellValue& cell) noexcept {
      const auto text = cell.utf8();

      return text.empty() || text == " ";
    }

    // Where the second side starts: past the longest stretch of blank cells on the line's own
    // background, of two cells at least, which Neovim fills between the sides; the line's end
    // when there is none.
    std::size_t sidesParted(std::span<const CellValue> row, const CellColor& base) noexcept {
      std::size_t longest = 1;
      std::size_t end = row.size();
      std::size_t stretch = 0;

      for (std::size_t index = 0; index < row.size(); ++index) {
        stretch = blank(row[index]) && groundOf(row[index].style) == base ? stretch + 1 : 0;
        if (stretch > longest) {
          longest = stretch;
          end = index + 1;
        }
      }

      return end;
    }

    // Puts a cell in the last piece: with the word before it when nothing parts them and they
    // share a style, as a word of its own otherwise, and an icon always on its own.
    void addWord(StatusLine& line, const CellValue& cell, std::uint8_t gap) {
      auto& piece = line.pieces.backMut();
      const auto text = cell.utf8();
      const bool icon = symbol(text);
      const auto offset = static_cast<std::uint32_t>(line.text.size());

      line.text.extend(std::span<const char>{text});
      if (piece.count != 0 && gap == 0 && !icon && !line.tokens.back().icon && line.tokens.back().style == cell.style) {
        line.tokens.backMut().text.size += static_cast<std::uint32_t>(text.size());
        return;
      }

      line.tokens.push({.text = {.offset = offset, .size = static_cast<std::uint32_t>(text.size())}, .style = cell.style, .icon = icon, .gap = gap});
      ++piece.count;
    }

    // The background most of the cells have.
    CellColor commonGround(std::span<const CellValue> row) noexcept {
      constexpr std::size_t kept = 16;
      ds::Array<CellColor, kept> grounds{};
      ds::Array<std::uint32_t, kept> counts{};
      std::size_t known = 0;

      for (const auto& cell : row) {
        const auto ground = groundOf(cell.style);
        std::size_t index = 0;

        while (index < known && !(grounds[index] == ground)) {
          ++index;
        }

        if (index == known && known < kept) {
          grounds.atMut(known++) = ground;
        }

        if (index < known) {
          ++counts.atMut(index);
        }
      }

      const auto most = std::ranges::max_element(counts.view().first(std::max<std::size_t>(known, 1)));

      return grounds[static_cast<std::size_t>(most - counts.view().begin())];
    }

  }

  StatusLine::StatusLine(Memory& memory)
      : text(memory),
        tokens(memory),
        pieces(memory) {}

  void readStatusLine(std::span<const CellValue> row, StatusLine& line) {
    line.text.clear();
    line.tokens.clear();
    line.pieces.clear();

    const auto base = commonGround(row);
    const auto gap_end = sidesParted(row, base);
    std::uint8_t gap = 0;

    for (std::size_t index = 0; index < row.size(); ++index) {
      const auto& cell = row[index];
      const auto ground = groundOf(cell.style);
      const bool pill = !(ground == base);
      const bool right = index >= gap_end;

      if (cell.width == CellWidth::continuation) {
        continue;
      }

      const bool same_piece = !line.pieces.empty() && line.pieces.back().right == right && line.pieces.back().background.hasValue() == pill && (!pill || *line.pieces.back().background == ground);

      // A blank cell parts the words of the piece it is in, and opens none.
      if (blank(cell)) {
        gap = same_piece && gap < std::numeric_limits<std::uint8_t>::max() ? static_cast<std::uint8_t>(gap + 1) : gap;
        continue;
      }

      if (!same_piece) {
        line.pieces.push({.first = static_cast<std::uint32_t>(line.tokens.size()), .background = pill ? ds::Option<CellColor>{ground} : ds::Option<CellColor>{}, .right = right});
        gap = 0;
      }

      addWord(line, cell, gap);
      gap = 0;
    }
  }

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
    editor->status_row = message.status_line ? ds::Option<std::uint16_t>{message.status_row} : ds::Option<std::uint16_t>{};
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
    line.runs.clear();
    line.runs.extend(message.runs);
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
    menu.info.assign(message.info);
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

      tabs.tabs.push({.handle = tab.handle, .name = name, .modified = tab.modified, .diagnostics = tab.diagnostics});
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
    prompt.origin.assign(message.origin);
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

  namespace {

    void clearMatches(Picker& picker) noexcept {
      picker.text.clear();
      picker.positions.clear();
      picker.matches.clear();
      picker.truncated = false;
    }

    // The editor whose picker waits for the answer to `request`.
    Editor* awaiting(State& state, std::uint64_t request) noexcept {
      if (request == 0) {
        return nullptr;
      }

      for (auto& editor : Access::editors(state).viewMut()) {
        if (editor->picker.open && editor->picker.awaited == request) {
          return &editor.getMut();
        }
      }

      return nullptr;
    }

    Slice keep(Picker& picker, std::string_view piece) {
      const Slice slice{.offset = static_cast<std::uint32_t>(picker.text.size()), .size = static_cast<std::uint32_t>(piece.size())};

      picker.text.extend(std::span<const char>{piece});
      return slice;
    }

  }

  bool pick(State& state, std::uint64_t pane_id, NvimPickSource source, std::string_view root) {
    auto* editor = Access::find(state, pane_id);
    if (editor == nullptr) {
      return false;
    }

    auto& picker = editor->picker;

    picker.open = true;
    picker.fresh = true;
    picker.source = source;
    picker.root.assign(root);
    picker.query.clear();
    picker.awaited = 0;
    clearMatches(picker);
    ++editor->picker_revision;
    return true;
  }

  bool ask(State& state, std::uint64_t pane_id, std::string_view query, std::uint64_t request) {
    auto* editor = Access::find(state, pane_id);
    if (editor == nullptr || !editor->picker.open) {
      return false;
    }

    auto& picker = editor->picker;

    picker.query.assign(query);
    picker.awaited = request;
    // Nothing asked: what was listed for another query is not this one's.
    if (request == 0) {
      clearMatches(picker);
    }

    ++editor->picker_revision;
    return true;
  }

  void refreshed(State& state, std::uint64_t pane_id) noexcept {
    if (auto* editor = Access::find(state, pane_id)) {
      editor->picker.fresh = false;
    }
  }

  bool link(State& state, std::uint64_t pane_id, std::string_view uri) {
    auto* editor = Access::find(state, pane_id);
    if (editor == nullptr) {
      return false;
    }

    editor->link.assign(uri);
    return true;
  }

  bool dismiss(State& state, std::uint64_t pane_id) noexcept {
    auto* editor = Access::find(state, pane_id);
    if (editor == nullptr || !editor->picker.open) {
      return false;
    }

    editor->picker.open = false;
    editor->picker.awaited = 0;
    clearMatches(editor->picker);
    ++editor->picker_revision;
    return true;
  }

  std::uint64_t receive(State& state, const PathResults& message) {
    auto* editor = awaiting(state, message.request_id);
    if (editor == nullptr) {
      return 0;
    }

    auto& picker = editor->picker;

    clearMatches(picker);
    picker.truncated = message.truncated;
    for (const auto& match : message.matches) {
      const auto first = static_cast<std::uint32_t>(picker.positions.size());

      picker.positions.extend(match.positions);
      picker.matches.push({.path = keep(picker, match.path), .first_position = first, .position_count = static_cast<std::uint16_t>(match.positions.size()), .change = match.change});
    }

    // A search still reading the directory answers again as it finds more.
    if (message.complete) {
      picker.awaited = 0;
    }

    ++editor->picker_revision;
    return editor->pane_id;
  }

  std::uint64_t receive(State& state, const TextResults& message) {
    auto* editor = awaiting(state, message.request_id);
    if (editor == nullptr) {
      return 0;
    }

    auto& picker = editor->picker;

    clearMatches(picker);
    picker.truncated = message.truncated;
    picker.awaited = 0;
    for (const auto& match : message.matches) {
      picker.matches.push({.path = keep(picker, match.path), .line = match.line, .column = match.column, .text = keep(picker, match.text)});
    }

    ++editor->picker_revision;
    return editor->pane_id;
  }

}
