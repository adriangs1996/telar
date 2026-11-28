module telar.runtime.nvim.frames;

import std;
import telar.tbc;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.nvim;
import telar.wire.vocabulary;
import telar.runtime.nvim.screen;

namespace telar::runtime {

  namespace {

    constexpr unsigned byte_bits = 8;
    constexpr std::uint32_t channel_mask = 0xff;
    constexpr unsigned underline_shift = 8;

    // A color a highlight leaves unset is the client's default: the pane is drawn in telar's
    // theme, whatever colors Neovim's own default has.
    constexpr CellColor colorOf(std::uint32_t rgb) noexcept {
      if (rgb == NvimHighlight::unset) {
        return {};
      }

      return {
          .kind = CellColor::Kind::rgb,
          .channels = {
              static_cast<Byte>((rgb >> (2 * byte_bits)) & channel_mask),
              static_cast<Byte>((rgb >> byte_bits) & channel_mask),
              static_cast<Byte>(rgb & channel_mask),
          },
      };
    }

    struct Attribute {
      std::uint16_t highlight = 0;
      CellAttribute cell = CellAttribute::bold;
    };

    constexpr ds::Array<Attribute, 7> attributes{
        Attribute{.highlight = NvimHighlight::bold, .cell = CellAttribute::bold},
        Attribute{.highlight = NvimHighlight::italic, .cell = CellAttribute::italic},
        Attribute{.highlight = NvimHighlight::dim, .cell = CellAttribute::faint},
        Attribute{.highlight = NvimHighlight::blink, .cell = CellAttribute::blink},
        Attribute{.highlight = NvimHighlight::reverse, .cell = CellAttribute::inverse},
        Attribute{.highlight = NvimHighlight::strikethrough, .cell = CellAttribute::strikethrough},
        Attribute{.highlight = NvimHighlight::overline, .cell = CellAttribute::overline},
    };

    struct Underline {
      std::uint16_t highlight = 0;
      UnderlineStyle style = UnderlineStyle::none;
    };

    // The underline a highlight asks for, the most particular one first.
    constexpr ds::Array<Underline, 5> underlines{
        Underline{.highlight = NvimHighlight::undercurl, .style = UnderlineStyle::curly},
        Underline{.highlight = NvimHighlight::underdouble, .style = UnderlineStyle::double_line},
        Underline{.highlight = NvimHighlight::underdotted, .style = UnderlineStyle::dotted},
        Underline{.highlight = NvimHighlight::underdashed, .style = UnderlineStyle::dashed},
        Underline{.highlight = NvimHighlight::underline, .style = UnderlineStyle::single},
    };

    // A highlight as the style of a cell on the wire.
    // What a word the command line completes is, which Neovim does not say, by what the line
    // completes: the kinds a client has an icon for, and none for the rest.
    constexpr tbc::val_static<std::string_view> completedKind(std::string_view completes, std::string_view word) noexcept { // NOLINT(bugprone-easily-swappable-parameters): what the line completes, then the word, as Neovim names them
      if (completes == "dir" || completes == "dir_in_path") {
        return "folder";
      }

      if (completes == "file" || completes == "file_in_path" || completes == "buffer" || completes == "runtime") {
        return word.ends_with('/') ? "folder" : "file";
      }

      if (completes == "function" || completes == "user_func") {
        return "function";
      }

      if (completes == "option") {
        return "property";
      }

      if (completes == "color" || completes == "highlight") {
        return "color";
      }

      return completes == "event" ? "event" : std::string_view{};
    }

    constexpr CellStyle styleOf(const NvimHighlight& highlight) noexcept {
      CellStyle style{
          .foreground = colorOf(highlight.foreground),
          .background = colorOf(highlight.background),
          .underline_color = colorOf(highlight.special),
      };

      for (const auto& attribute : attributes) {
        if ((highlight.attributes & attribute.highlight) != 0) {
          style.flags |= static_cast<std::uint16_t>(attribute.cell);
        }
      }

      for (const auto& underline : underlines) {
        if ((highlight.attributes & underline.highlight) != 0) {
          style.flags |= static_cast<std::uint16_t>(static_cast<unsigned>(underline.style) << underline_shift);
          break;
        }
      }

      // A link says so, and is underlined when its highlight draws no line of its own.
      if (highlight.link != 0) {
        constexpr unsigned underline_mask = 7U << underline_shift;

        style.flags |= CellStyle::link;
        if ((style.flags & underline_mask) == 0) {
          style.flags |= static_cast<std::uint16_t>(static_cast<unsigned>(UnderlineStyle::single) << underline_shift);
        }
      }

      return style;
    }

    constexpr CursorShape cursorShape(NvimCursorShape shape) noexcept {
      switch (shape) {
      case NvimCursorShape::block:
        return CursorShape::block;
      case NvimCursorShape::horizontal:
        return CursorShape::underline;
      case NvimCursorShape::vertical:
        return CursorShape::bar;
      }

      return CursorShape::block;
    }

    // The start of `text` a surface's message has room for.
    constexpr std::string_view clipped(std::string_view text, std::size_t limit) {
      return text.substr(0, std::min(text.size(), limit));
    }

    // Whether a client that has frame `seen` lacks something of a grid. A grid Neovim placed
    // before giving it a size has no cells to show yet, and is sent once it has.
    constexpr bool changedSince(const NvimScreenGrid& grid, std::uint64_t seen) noexcept {
      if (grid.columns == 0 || grid.rows == 0) {
        return false;
      }

      return seen == 0 || grid.reset_at > seen || grid.cells_at > seen || grid.placed_at > seen || grid.viewport_at > seen || grid.scrolled_at > seen;
    }

    // What a cell is of a character two cells wide: its left half, the empty right one, or
    // neither.
    constexpr CellWidth widthOf(const NvimCell& cell) noexcept {
      if ((cell.flags & NvimCell::continuation) != 0) {
        return CellWidth::continuation;
      }

      return (cell.flags & NvimCell::wide) != 0 ? CellWidth::wide : CellWidth::single;
    }

    // A cell waiting to be encoded: its style and width, and where its text lies in the text of
    // the span being filled.
    struct StagedCell {
      CellStyle style;
      CellWidth width = CellWidth::single;
      std::uint8_t size = 0;
      std::uint16_t offset = 0;
    };

    // The cells of one span while they are gathered: at most a span's worth, with their text
    // one after another.
    struct Staging {
      ds::Array<StagedCell, NvimFrames::span_cells> cells{};
      ds::Array<Byte, NvimFrames::span_cells * NvimCell::text_capacity> text{};
      std::size_t count = 0;
      std::size_t text_size = 0;
      // Where the span's first cell is in the grid.
      std::uint32_t start = 0;
    };

    // The cells a staged span holds, encoded after the bytes `encoded` already has. The text
    // is read only once every cell of the span is staged, so no cell views a buffer that is
    // still being written.
    std::size_t encodeSpan(ds::Vec<Byte, ConcurrentMemory>& encoded, std::span<const StagedCell> staged, std::span<const Byte> text) {
      ds::Array<Cell, NvimFrames::span_cells> cells{};

      for (std::size_t index = 0; index < staged.size(); ++index) {
        const auto& cell = staged[index];

        cells.atMut(index) = {.width = cell.width, .style = cell.style, .text = text.subspan(cell.offset, cell.size)};
      }

      const auto run = cells.view().first(staged.size());
      const auto offset = encoded.size();
      const auto size = CellRunCodec::encodedSize(run);

      encoded.resize(offset + size);
      static_cast<void>(CellRunCodec::encode(run, encoded.viewMut().subspan(offset)));
      return size;
    }

    // Writes `message` into `payload`, which then holds exactly its bytes.
    template <typename Message>
    void write(ds::Vec<Byte, ConcurrentMemory>& payload, const Message& message) {
      payload.resize(Codec::encodedSize(message));
      static_cast<void>(Codec::encode(message, payload.viewMut()));
    }

  }

  NvimFrames::NvimFrames(ConcurrentMemory& memory)
      : cells_(memory),
        runs_(memory),
        payload_(memory) {}

  bool NvimFrames::pending(const NvimScreen& screen, std::uint64_t seen) noexcept {
    return screen.flushed() > seen;
  }

  void NvimFrames::begin(const NvimScreen& screen, NvimFrameFor target) {
    pane_ = target.pane_id;
    // A client so far behind that the grids removed since are forgotten is sent every grid.
    seen_ = target.seen < screen.removedForgottenAt() ? 0 : target.seen;
    frame_ = screen.flushed();
    grid_ = 0;
    row_ = 0;
    started_ = false;
    whole_ = false;
    replay_ = false;
  }

  std::uint64_t NvimFrames::frame() const noexcept {
    return frame_;
  }

  void NvimFrames::start(const NvimScreenGrid& grid) {
    const bool scrolled = grid.scrolled_at > seen_;

    // A scroll moves rows without changing them. A client that has the frame before the grid's
    // last scrolls moves its own rows the same way and is sent only the rows that changed; one
    // further behind missed scrolls the grid no longer keeps, and is sent every row.
    replay_ = scrolled && grid.scrolled_before <= seen_;
    whole_ = seen_ == 0 || grid.reset_at > seen_ || (scrolled && !replay_);
    started_ = true;
    row_ = 0;
  }

  void NvimFrames::collect(const NvimScreen& screen, const NvimScreenGrid& grid) {
    Staging staging;
    std::size_t taken = 0;
    const auto flush = [&] {
      if (staging.count == 0) {
        return;
      }

      const auto offset = cells_.size();
      const auto size = encodeSpan(cells_, staging.cells.view().first(staging.count), staging.text.view().first(staging.text_size));

      runs_.push({.start = staging.start, .count = static_cast<std::uint32_t>(staging.count), .offset = offset, .size = size});
      staging.count = 0;
      staging.text_size = 0;
    };

    cells_.clear();
    runs_.clear();

    for (; row_ < grid.rows; ++row_) {
      if (!whole_ && grid.row_changed_at[row_] <= seen_) {
        continue;
      }

      // A row is sent whole or waits for the next message, which leaves room for its spans.
      const auto row_spans = (std::size_t{grid.columns} / span_cells) + 2;
      if (taken + grid.columns > message_cells || runs_.size() + row_spans > message_spans) {
        break;
      }

      const auto first = row_ * std::uint32_t{grid.columns};

      // Rows that follow one another share a span; a row after a gap starts its own.
      if (staging.count != 0 && staging.start + staging.count != first) {
        flush();
      }

      std::uint16_t last_highlight = std::numeric_limits<std::uint16_t>::max();
      CellStyle style;
      std::uint32_t column = 0;

      for (const auto& cell : grid.row(row_)) {
        if (staging.count == span_cells) {
          flush();
        }

        if (staging.count == 0) {
          staging.start = first + column;
        }

        if (cell.highlight != last_highlight) {
          last_highlight = cell.highlight;
          style = styleOf(screen.highlightOf(cell.highlight));
        }

        ds::Array<char, NvimCell::text_capacity> text{};
        const auto size = screen.copyText(cell, text.viewMut());

        std::ranges::transform(text.view().first(size), staging.text.viewMut().subspan(staging.text_size).begin(), [](char character) {
          return static_cast<Byte>(character);
        });

        staging.cells.atMut(staging.count) = {
            .style = style,
            .width = widthOf(cell),
            .size = static_cast<std::uint8_t>(size),
            .offset = static_cast<std::uint16_t>(staging.text_size),
        };

        staging.text_size += size;
        ++staging.count;
        ++column;
      }

      taken += grid.columns;
    }

    flush();
  }

  std::span<const Byte> NvimFrames::next(const NvimScreen& screen) {
    const auto grids = screen.grids();

    while (grid_ < grids.size()) {
      const auto& grid = *grids[grid_];
      const bool first = !started_;

      if (first && !changedSince(grid, seen_)) {
        ++grid_;
        continue;
      }

      if (first) {
        start(grid);
      }

      collect(screen, grid);
      if (row_ == grid.rows) {
        ++grid_;
        started_ = false;
      }

      // The first message goes even without cells: it says where the grid is shown.
      if (!first && runs_.empty()) {
        continue;
      }

      ds::Array<FrameSpan, message_spans> spans{};

      for (std::size_t index = 0; index < runs_.size(); ++index) {
        const auto& run = runs_[index];

        spans.atMut(index) = {.start = run.start, .count = run.count, .cells = cells_.view().subspan(run.offset, run.size)};
      }

      write(
          payload_,
          NvimGrid{
              .pane_id = pane_,
              .frame_id = frame_,
              .grid = grid.id,
              .columns = grid.columns,
              .rows = grid.rows,
              .placement = grid.placement,
              .mouse_enabled = grid.mouse_enabled,
              .row = grid.start_row,
              .column = grid.start_column,
              .width = grid.width,
              .height = grid.height,
              .z_index = grid.z_index,
              .composition_index = grid.composition_index,
              .window = grid.window,
              .top_line = grid.viewport.top_line,
              .bottom_line = grid.viewport.bottom_line,
              .cursor_line = grid.viewport.cursor_line,
              .cursor_column = grid.viewport.cursor_column,
              .line_count = grid.viewport.line_count,
              .scrolled_lines = grid.scrolled_lines,
              .margin_top = grid.margins.top,
              .margin_bottom = grid.margins.bottom,
              .margin_left = grid.margins.left,
              .margin_right = grid.margins.right,
              .border = grid.border,
              .title = grid.title.view(),
              .footer = grid.footer.view(),
              .full = first && whole_,
              .scrolls = first && replay_ ? grid.scrolls.view() : std::span<const NvimScroll>{},
              .spans = spans.view().first(runs_.size()),
          }
      );
      return payload_.view();
    }

    return {};
  }

  std::span<const Byte> NvimFrames::cmdline(const NvimScreen& screen) {
    const auto& line = screen.commandLine();
    if (line.changed_at <= seen_) {
      return {};
    }

    // The runs of the text it sends, in the styles their highlights draw; none when the text is
    // all in the default one.
    const auto text = clipped(line.content.view(), max_nvim_line_bytes);
    ds::Array<NvimTextRun, max_nvim_text_runs> runs{};
    std::size_t run_count = 0;
    bool styled = false;

    for (const auto& chunk : line.content.chunks) {
      if (run_count == runs.size() || chunk.offset >= text.size()) {
        break;
      }

      const auto bytes = static_cast<std::uint32_t>(std::min<std::size_t>(chunk.size, text.size() - chunk.offset));

      runs.atMut(run_count++) = {.bytes = bytes, .style = styleOf(screen.highlightOf(chunk.highlight))};
      styled = styled || chunk.highlight != 0;
    }

    // Neovim leaves `:` uncolored: the configuration's colors, while they are of this text.
    if (!styled && line.first == ':' && line.colored.view() == line.content.view()) {
      run_count = 0;
      for (const auto& run : line.coloring.view().first(std::min(line.coloring.size(), runs.size()))) {
        runs.atMut(run_count++) = {.bytes = run.bytes, .style = styleOf(run.highlight)};
      }

      styled = run_count != 0;
    }

    write(
        payload_,
        NvimCmdline{
            .pane_id = pane_,
            .frame_id = frame_,
            .visible = line.visible,
            .level = line.level,
            .first = static_cast<Byte>(line.first),
            .special = static_cast<Byte>(line.special),
            .position = line.position,
            .indent = line.indent,
            .prompt = clipped(line.prompt.view(), max_nvim_label_bytes),
            .text = text,
            .block = clipped(line.block.view(), max_nvim_line_bytes),
            .runs = styled ? runs.view().first(run_count) : std::span<const NvimTextRun>{},
        }
    );
    return payload_.view();
  }

  std::span<const Byte> NvimFrames::popupMenu(const NvimScreen& screen) {
    const auto& menu = screen.completion();
    if (menu.changed_at <= seen_) {
      return {};
    }

    const auto total = menu.items.size();
    // A menu longer than a message is sent as the items around the selection, again each time
    // the selection moves; a shorter one whole, once.
    const bool windowed = total > max_nvim_menu_items;
    const bool keeps = !windowed && menu.items_at <= seen_;
    std::size_t first = 0;

    if (windowed && menu.selected > 0) {
      first = std::min(static_cast<std::size_t>(menu.selected) - std::min(static_cast<std::size_t>(menu.selected), max_nvim_menu_items / 2), total - max_nvim_menu_items);
    }

    ds::Array<NvimMenuItem, max_nvim_menu_items> items{};
    std::size_t count = 0;

    if (menu.visible && !keeps) {
      const std::string_view text{menu.text.data(), menu.text.size()};
      const auto completes = menu.grid < 0 ? screen.commandLine().completes.view() : std::string_view{};

      for (const auto& item : menu.items.view().subspan(first, std::min(total - first, max_nvim_menu_items))) {
        const auto word = clipped(item.word.of(text), max_nvim_label_bytes);
        const auto kind = item.kind.of(text);

        items.atMut(count++) = {
            .word = word,
            .kind = clipped(kind.empty() ? completedKind(completes, word) : kind, max_nvim_label_bytes),
            .menu = clipped(item.menu.of(text), max_nvim_label_bytes),
        };
      }
    }

    // The documentation of the item selected: of that one alone, each time it changes.
    const std::string_view documented{menu.text.data(), menu.text.size()};
    const bool chosen = menu.visible && menu.selected >= 0 && std::cmp_less(menu.selected, total);
    const auto info = chosen ? clipped(menu.items[static_cast<std::size_t>(menu.selected)].info.of(documented), max_nvim_info_bytes) : std::string_view{};

    write(
        payload_,
        NvimPopupMenu{
            .pane_id = pane_,
            .frame_id = frame_,
            .visible = menu.visible,
            .keeps_items = menu.visible && keeps,
            .selected = menu.selected,
            .grid = menu.grid,
            .row = menu.row,
            .column = menu.column,
            .first = static_cast<std::uint32_t>(first),
            .total = static_cast<std::uint32_t>(total),
            .items = items.view().first(count),
            .info = info,
        }
    );
    return payload_.view();
  }

  std::span<const Byte> NvimFrames::messageList(const NvimScreen& screen) {
    const auto& messages = screen.messages();
    if (messages.changed_at <= seen_) {
      return {};
    }

    const auto visible = messages.visible.view();
    ds::Array<NvimMessageItem, max_nvim_messages> items{};
    std::size_t count = 0;

    // The newest are the ones a client has room to show.
    for (const auto& message : visible.last(std::min(visible.size(), max_nvim_messages))) {
      items.atMut(count++) = {.id = message.id, .kind = message.kind, .text = clipped(message.content.view(), max_nvim_line_bytes)};
    }

    write(
        payload_,
        NvimMessageList{
            .pane_id = pane_,
            .frame_id = frame_,
            .mode = clipped(messages.mode.view(), max_nvim_label_bytes),
            .command = clipped(messages.command.view(), max_nvim_label_bytes),
            .ruler = clipped(messages.ruler.view(), max_nvim_label_bytes),
            .messages = items.view().first(count),
        }
    );
    return payload_.view();
  }

  std::span<const Byte> NvimFrames::tabLine(const NvimScreen& screen) {
    const auto& tabs = screen.tabs();
    if (tabs.changed_at <= seen_) {
      return {};
    }

    const std::string_view text{tabs.text.data(), tabs.text.size()};
    ds::Array<NvimTab, max_nvim_tabs> pages{};
    ds::Array<NvimTab, max_nvim_tabs> buffers{};
    const auto page_count = std::min(tabs.tabs.size(), max_nvim_tabs);
    const auto buffer_count = std::min(tabs.buffers.size(), max_nvim_tabs);

    // An entry of the tab line with what is marked on it.
    const auto marked = [&](const NvimTabs::Entry& entry, const auto& marks) {
      const auto* const mark = std::ranges::find(marks, entry.handle, &NvimTabs::Mark::handle);
      const bool found = mark != marks.end();

      return NvimTab{
          .handle = entry.handle,
          .name = clipped(entry.name.of(text), max_nvim_label_bytes),
          .modified = found && mark->modified,
          .diagnostics = found ? mark->diagnostics : std::uint16_t{0},
      };
    };

    for (std::size_t index = 0; index < page_count; ++index) {
      pages.atMut(index) = marked(tabs.tabs[index], tabs.marks);
    }

    for (std::size_t index = 0; index < buffer_count; ++index) {
      buffers.atMut(index) = marked(tabs.buffers[index], tabs.buffer_marks);
    }

    write(
        payload_,
        NvimTabLine{
            .pane_id = pane_,
            .frame_id = frame_,
            .current_tab = tabs.current_tab,
            .current_buffer = tabs.current_buffer,
            .tabs = pages.view().first(page_count),
            .buffers = buffers.view().first(buffer_count),
        }
    );
    return payload_.view();
  }

  std::span<const Byte> NvimFrames::openFiles(const NvimScreen& screen) {
    const auto& shown = screen.files();
    if (shown.changed_at <= seen_) {
      return {};
    }

    const std::string_view text{shown.text.data(), shown.text.size()};
    ds::Array<NvimOpenFile, max_nvim_open_files> files{};
    const auto count = std::min(shown.files.size(), max_nvim_open_files);

    for (std::size_t index = 0; index < count; ++index) {
      files.atMut(index) = {.path = shown.files[index].path.of(text), .modified = shown.files[index].modified, .current = shown.files[index].current};
    }

    write(payload_, NvimOpenFiles{.pane_id = pane_, .files = files.view().first(count)});
    return payload_.view();
  }

  std::span<const Byte> NvimFrames::end(const NvimScreen& screen) {
    const auto& cursor = screen.cursor();
    const auto modes = screen.modes();
    const auto mode = screen.currentMode() < modes.size() ? modes[screen.currentMode()] : NvimMode{};
    ds::Array<std::uint32_t, max_nvim_removed_grids> removed{};
    std::size_t count = 0;

    // A client that starts over forgets every grid it had; one that goes on is told the ones
    // Neovim destroyed after the frame it has.
    for (const auto& gone : screen.removed()) {
      if (seen_ != 0 && gone.at > seen_ && count < max_nvim_removed_grids) {
        removed.atMut(count++) = gone.grid;
      }
    }

    write(
        payload_,
        NvimFrame{
            .pane_id = pane_,
            .frame_id = frame_,
            .base_frame_id = seen_,
            .cursor_grid = cursor.grid,
            .cursor_row = cursor.row,
            .cursor_column = cursor.column,
            .cursor_visible = !cursor.hidden,
            .cursor_shape = cursorShape(mode.shape),
            .cursor_percentage = mode.cell_percentage,
            .blink_wait_ms = mode.blink_wait,
            .blink_on_ms = mode.blink_on,
            .blink_off_ms = mode.blink_off,
            .mode = clipped(screen.modeName(), max_nvim_mode_bytes),
            .removed = removed.view().first(count),
            .status_line = screen.statusLine().hasValue(),
            .status_row = screen.statusLine().valueOr(0),
        }
    );
    return payload_.view();
  }

}
