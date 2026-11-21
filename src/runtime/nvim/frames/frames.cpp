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
    constexpr std::string_view clipped(std::string_view text, std::size_t limit) noexcept {
      return text.substr(0, std::min(text.size(), limit));
    }

    // The entries a tab line names, as many as its message takes.
    void collectTabs(ds::Vec<NvimTab, ConcurrentMemory>& tabs, std::span<const NvimTabs::Entry> entries, std::string_view text) {
      tabs.clear();

      for (const auto& entry : entries.first(std::min(entries.size(), max_nvim_tabs))) {
        tabs.push({.handle = entry.handle, .name = clipped(entry.name.of(text), max_nvim_label_bytes)});
      }
    }

    // Whether a client that has frame `seen` lacks something of a grid. A grid Neovim placed
    // before giving it a size has no cells to show yet, and is sent once it has.
    constexpr bool changedSince(const NvimScreenGrid& grid, std::uint64_t seen) noexcept {
      if (grid.columns == 0 || grid.rows == 0) {
        return false;
      }

      return seen == 0 || grid.reset_at > seen || grid.cells_at > seen || grid.placed_at > seen || grid.viewport_at > seen || grid.scrolled_at > seen;
    }

  }

  NvimFrames::NvimFrames(ConcurrentMemory& memory)
      : cells_(memory),
        texts_(memory),
        bytes_(memory),
        runs_(memory),
        spans_(memory),
        removed_(memory),
        menu_items_(memory),
        messages_(memory),
        tabs_(memory),
        buffers_(memory) {}

  bool NvimFrames::pending(const NvimScreen& screen, std::uint64_t seen) noexcept {
    return screen.flushed() > seen;
  }

  void NvimFrames::begin(const NvimScreen& screen, std::uint64_t pane_id, std::uint64_t seen) {
    pane_ = pane_id;
    // A client so far behind that the grids removed since are forgotten is sent every grid.
    seen_ = seen < screen.removedForgottenAt() ? 0 : seen;
    frame_ = screen.flushed();
    grid_ = 0;
    row_ = 0;
    started_ = false;
    whole_ = false;
    replay_ = false;
    cells_.reserve(message_cells);
    // Reserved whole: the cells view their text here, so it must not move while they are filled.
    texts_.reserve(message_cells * NvimCell::text_capacity);
  }

  void NvimFrames::appendRow(const NvimScreen& screen, const NvimScreenGrid& grid, std::uint32_t row) {
    const auto first = cells_.size();
    std::uint16_t last_highlight = std::numeric_limits<std::uint16_t>::max();
    CellStyle style;

    for (const auto& cell : grid.row(row)) {
      if (cell.highlight != last_highlight) {
        last_highlight = cell.highlight;
        style = styleOf(screen.highlightOf(cell.highlight));
      }

      const auto offset = texts_.size();
      ds::Array<char, NvimCell::text_capacity> text{};
      const auto size = screen.copyText(cell, text.viewMut());

      texts_.resize(offset + size);
      std::ranges::transform(text.view().first(size), texts_.viewMut().subspan(offset).begin(), [](char character) {
        return static_cast<Byte>(character);
      });

      const bool continuation = (cell.flags & NvimCell::continuation) != 0;
      const bool wide = (cell.flags & NvimCell::wide) != 0;

      cells_.push({
          .width = continuation ? CellWidth::continuation : wide ? CellWidth::wide
                                                                 : CellWidth::single,
          .style = style,
          .text = texts_.view().subspan(offset, size),
      });
    }

    const auto start = row * std::uint32_t{grid.columns};

    if (!runs_.empty() && runs_.back().start + runs_.back().count == start) {
      runs_.backMut().count += grid.columns;
    } else {
      runs_.push({.first = first, .count = grid.columns, .start = start});
    }
  }

  void NvimFrames::collect(const NvimScreen& screen, const NvimScreenGrid& grid) {
    cells_.clear();
    texts_.clear();
    runs_.clear();

    for (; row_ < grid.rows; ++row_) {
      if (!whole_ && grid.row_changed_at[row_] <= seen_) {
        continue;
      }

      if (cells_.size() + grid.columns > message_cells || runs_.size() == max_nvim_grid_spans) {
        return;
      }

      appendRow(screen, grid, row_);
    }
  }

  void NvimFrames::encodeSpans() {
    std::size_t total = 0;

    for (const auto& run : runs_) {
      total += CellRunCodec::encodedSize(cells_.view().subspan(run.first, run.count));
    }

    bytes_.resize(total);
    spans_.clear();

    std::size_t offset = 0;

    for (const auto& run : runs_) {
      const auto encoded = CellRunCodec::encode(cells_.view().subspan(run.first, run.count), bytes_.viewMut().subspan(offset));

      spans_.push({.start = run.start, .count = static_cast<std::uint32_t>(run.count), .cells = bytes_.view().subspan(offset, encoded.size())});
      offset += encoded.size();
    }
  }

  NvimGrid NvimFrames::message(const NvimScreenGrid& grid, bool first) const {
    return {
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
        .full = first && whole_,
        .scrolls = first && replay_ ? grid.scrolls.view() : std::span<const NvimScroll>{},
        .spans = spans_.view(),
    };
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

  ds::Option<NvimGrid> NvimFrames::next(const NvimScreen& screen) {
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
      encodeSpans();

      const bool finished = row_ == grid.rows;

      if (finished) {
        ++grid_;
        started_ = false;
      }

      // The first message goes even without cells: it says where the grid is shown.
      if (first || !spans_.empty()) {
        return message(grid, first);
      }
    }

    return ds::none;
  }

  ds::Option<NvimCmdline> NvimFrames::cmdline(const NvimScreen& screen) const {
    const auto& line = screen.commandLine();
    if (line.changed_at <= seen_) {
      return ds::none;
    }

    return NvimCmdline{
        .pane_id = pane_,
        .frame_id = frame_,
        .visible = line.visible,
        .level = line.level,
        .first = static_cast<Byte>(line.first),
        .special = static_cast<Byte>(line.special),
        .position = line.position,
        .indent = line.indent,
        .prompt = clipped(line.prompt.view(), max_nvim_label_bytes),
        .text = clipped(line.content.view(), max_nvim_line_bytes),
        .block = clipped(line.block.view(), max_nvim_line_bytes),
    };
  }

  ds::Option<NvimPopupMenu> NvimFrames::popupMenu(const NvimScreen& screen) {
    const auto& menu = screen.completion();
    if (menu.changed_at <= seen_) {
      return ds::none;
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

    menu_items_.clear();
    if (menu.visible && !keeps) {
      const std::string_view text{menu.text.data(), menu.text.size()};

      for (const auto& item : menu.items.view().subspan(first, std::min(total - first, max_nvim_menu_items))) {
        menu_items_.push({
            .word = clipped(item.word.of(text), max_nvim_label_bytes),
            .kind = clipped(item.kind.of(text), max_nvim_label_bytes),
            .menu = clipped(item.menu.of(text), max_nvim_label_bytes),
        });
      }
    }

    return NvimPopupMenu{
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
        .items = menu_items_.view(),
    };
  }

  ds::Option<NvimMessageList> NvimFrames::messageList(const NvimScreen& screen) {
    const auto& messages = screen.messages();
    if (messages.changed_at <= seen_) {
      return ds::none;
    }

    const auto visible = messages.visible.view();

    messages_.clear();
    // The newest are the ones a client has room to show.
    for (const auto& message : visible.last(std::min(visible.size(), max_nvim_messages))) {
      messages_.push({.id = message.id, .kind = message.kind, .text = clipped(message.content.view(), max_nvim_line_bytes)});
    }

    return NvimMessageList{
        .pane_id = pane_,
        .frame_id = frame_,
        .mode = clipped(messages.mode.view(), max_nvim_label_bytes),
        .command = clipped(messages.command.view(), max_nvim_label_bytes),
        .ruler = clipped(messages.ruler.view(), max_nvim_label_bytes),
        .messages = messages_.view(),
    };
  }

  ds::Option<NvimTabLine> NvimFrames::tabLine(const NvimScreen& screen) {
    const auto& tabs = screen.tabs();
    if (tabs.changed_at <= seen_) {
      return ds::none;
    }

    const std::string_view text{tabs.text.data(), tabs.text.size()};

    collectTabs(tabs_, tabs.tabs.view(), text);
    collectTabs(buffers_, tabs.buffers.view(), text);
    return NvimTabLine{
        .pane_id = pane_,
        .frame_id = frame_,
        .current_tab = tabs.current_tab,
        .current_buffer = tabs.current_buffer,
        .tabs = tabs_.view(),
        .buffers = buffers_.view(),
    };
  }

  NvimFrame NvimFrames::end(const NvimScreen& screen) {
    const auto& cursor = screen.cursor();
    const auto modes = screen.modes();
    const auto mode = screen.currentMode() < modes.size() ? modes[screen.currentMode()] : NvimMode{};
    const auto name = screen.modeName().substr(0, mode_.size());

    std::ranges::copy(name, mode_.viewMut().begin());
    removed_.clear();

    // A client that starts over forgets every grid it had; one that goes on is told the ones
    // Neovim destroyed after the frame it has.
    for (const auto& removed : screen.removed()) {
      if (seen_ != 0 && removed.at > seen_ && removed_.size() < max_nvim_removed_grids) {
        removed_.push(removed.grid);
      }
    }

    return {
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
        .mode = std::string_view{mode_.view()}.substr(0, name.size()),
        .removed = removed_.view(),
    };
  }

}
