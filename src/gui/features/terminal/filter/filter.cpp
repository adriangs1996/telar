module telar.gui.features.terminal.filter;

import std;

import telar.gui.foundation.terminal;
import telar.base.text.pattern;
import telar.base.text.utf8;
import telar.base.memory.allocators;
import telar.wire.content;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::terminal::filter {

  namespace {

    // A wide character's second cell holds nothing of its own.
    void appendCells(ds::String<Memory>& text, std::span<const CellValue> cells) {
      for (const auto& cell : cells) {
        if (cell.width != CellWidth::continuation) {
          text.append(cell.utf8());
        }
      }
    }

    [[nodiscard]] bool wraps(Byte flags) noexcept {
      return (flags & static_cast<Byte>(RowFlag::wrap)) != 0;
    }

  }

  State::State(Memory& memory)
      : memory_(&memory),
        settled_(memory),
        tail_(memory),
        row_(memory),
        columns_(memory) {}

  // What the use cases share: the state's own steps.
  struct Steps {
    // Where reading goes on: the output's first row before any is read.
    [[nodiscard]] static std::uint64_t frontier(const State& state, const Extent& extent) noexcept {
      return std::max(state.frontier_, extent.first);
    }

    static void restart(State& state) noexcept {
      state.settled_.reset(state.query_.context, state.query_.invert);
      state.tail_.reset(state.query_.context, state.query_.invert);
      state.frontier_ = 0;
      state.tail_frontier_ = 0;
      state.tail_end_ = 0;
      state.tail_revision_ = 0;
      state.request_.reset();
      ++state.revision_;
    }

    static void settle(State& state, std::uint64_t row, std::string_view text, bool wrapping) {
      state.settled_.feed(state.pattern_.getMut().getMut(), row, text, wrapping);
      state.frontier_ = row + 1;
    }

    // The rows from the frontier the screen holds, read again as the tail.
    static bool readTail(State& state, const ScreenRows& rows, const Extent& extent) {
      const auto count = rows.flags.size();
      const auto end = std::min(extent.end, rows.first + count);
      const bool held = state.frontier_ >= rows.first && state.frontier_ < end;
      if (!held) {
        const bool had = !state.tail_.runs().empty();

        state.tail_.follow(state.settled_);
        state.tail_frontier_ = 0;
        return had;
      }

      if (rows.revision == state.tail_revision_ && state.frontier_ == state.tail_frontier_ && end == state.tail_end_) {
        return false;
      }

      state.tail_.follow(state.settled_);
      for (auto row = state.frontier_; row < end; ++row) {
        const auto index = static_cast<std::size_t>(row - rows.first);

        state.row_.clear();
        appendCells(state.row_, rows.cells.subspan(index * rows.columns, rows.columns));
        state.tail_.feed(state.pattern_.getMut().getMut(), row, state.row_.view(), wraps(rows.flags[index]));
      }

      state.tail_revision_ = rows.revision;
      state.tail_frontier_ = state.frontier_;
      state.tail_end_ = end;
      return true;
    }

    static void open(State& state, const Opening& opening) {
      const auto [pane_id, block, top] = opening;

      ++state.opened_;
      if (state.open_ && state.pane_id_ == pane_id && state.block_ == block) {
        return;
      }

      static_cast<void>(close(state));
      state.open_ = true;
      state.pane_id_ = pane_id;
      state.block_ = block;
      state.top_ = top;
      state.text_.assign({});
      state.query_ = {};
      state.error_ = nullptr;
      state.pattern_.reset();
      Steps::restart(state);
    }

    static bool query(State& state, const Query& query) {
      if (!state.open_) {
        return false;
      }

      state.text_.assign(runtime::utf8Prefix(query.text, maximum_query_bytes));
      // How the text is read; the text itself is the state's own copy.
      state.query_ = Query{.regex = query.regex, .ignore_case = query.ignore_case, .invert = query.invert, .context = static_cast<std::uint8_t>(std::min<std::size_t>(query.context, maximum_context))};
      state.error_ = nullptr;
      state.pattern_.reset();
      if (!state.text_.view().empty()) {
        try {
          state.pattern_ = ds::makeBox<runtime::Pattern>(*state.memory_, state.text_.view(), runtime::PatternOptions{.regex = query.regex, .ignore_case = query.ignore_case});
        } catch (const runtime::PatternError& error) {
          state.error_ = error.what();
        }
      }

      Steps::restart(state);
      return state.error_ == nullptr;
    }

    static ds::Option<std::uint64_t> close(State& state) noexcept {
      if (!state.open_) {
        return ds::none;
      }

      state.open_ = false;
      state.pattern_.reset();
      state.query_ = {};
      Steps::restart(state);
      return state.top_;
    }

    static bool open(const State& state) noexcept {
      return state.open_;
    }

    static bool filters(const State& state, std::uint64_t pane_id, std::uint64_t block) noexcept {
      return Access::filtering(state) && state.pane_id_ == pane_id && state.block_ == block;
    }

    static Status status(const State& state) noexcept {
      return Status{
          .pane_id = state.pane_id_,
          .block = state.block_,
          .text = state.text_.view(),
          .regex = state.query_.regex,
          .ignore_case = state.query_.ignore_case,
          .invert = state.query_.invert,
          .context = state.query_.context,
          .matches = state.settled_.matches() + state.tail_.matches(),
          .complete = state.frontier_ >= state.extent_.end || (state.tail_frontier_ == state.frontier_ && state.tail_end_ >= state.extent_.end && state.extent_.end != 0),
          .truncated = state.settled_.truncated() || state.tail_.truncated(),
          .error = state.error_ == nullptr ? std::string_view{} : std::string_view{state.error_},
          .opened = state.opened_,
      };
    }

    static std::uint64_t revision(const State& state) noexcept {
      return state.revision_;
    }

    static ds::Option<RowRequest> wanted(const State& state, const Extent& extent) noexcept {
      if (!Access::filtering(state) || state.request_) {
        return ds::none;
      }

      const auto from = Steps::frontier(state, extent);
      const auto end = std::min({extent.settled, extent.end, extent.screen});
      if (from >= end) {
        return ds::none;
      }

      return RowRequest{.from = from, .count = static_cast<std::uint16_t>(std::min<std::uint64_t>(end - from, ReadPaneRows::maximum_rows))};
    }

    static void asked(State& state, std::uint64_t request_id, RowRequest rows) noexcept {
      state.request_ = request_id;
      state.asked_ = rows;
    }

    static bool receive(State& state, const PaneRows& reply, const Extent& extent) {
      if (!state.request_ || reply.request_id != *state.request_) {
        return false;
      }

      state.request_.reset();
      state.extent_ = extent;
      state.frontier_ = Steps::frontier(state, extent);
      // Rows read since from the screen, or an output that moved, leave the reply behind.
      if (!Access::filtering(state) || reply.from != state.frontier_ || reply.cols == 0) {
        return true;
      }

      auto reader = reply.reader();

      for (std::uint16_t row = 0; row < reply.rows; ++row) {
        const auto stable = reply.from + row;

        state.row_.clear();
        for (std::uint16_t column = 0; column < reply.cols; ++column) {
          const auto cell = reader.next();
          if (cell && cell->width != CellWidth::continuation) {
            state.row_.append(textView(cell->text));
          }
        }

        if (stable >= extent.settled || stable >= extent.end) {
          break;
        }

        const auto flags = reply.text_metadata && row < reply.text_metadata->row_flags.size() ? reply.text_metadata->row_flags[row] : Byte{0};

        Steps::settle(state, stable, state.row_.view(), wraps(flags));
      }

      // The tail began where the frontier was; it is read again from where it is now.
      state.tail_.follow(state.settled_);
      state.tail_frontier_ = 0;
      ++state.revision_;
      return true;
    }

    static bool fail(State& state, std::uint64_t request_id) noexcept {
      if (!state.request_ || *state.request_ != request_id) {
        return false;
      }

      state.request_.reset();
      return true;
    }

    static bool screen(State& state, const ScreenRows& rows, const Extent& extent) {
      state.extent_ = extent;
      if (!Access::filtering(state) || rows.columns == 0) {
        return false;
      }

      state.frontier_ = Steps::frontier(state, extent);
      const auto count = rows.flags.size();
      bool changed = false;

      // The settled rows next in order that the screen holds are read for good.
      while (state.frontier_ < std::min(extent.settled, extent.end) && state.frontier_ >= rows.first && state.frontier_ < rows.first + count) {
        const auto index = static_cast<std::size_t>(state.frontier_ - rows.first);

        state.row_.clear();
        appendCells(state.row_, rows.cells.subspan(index * rows.columns, rows.columns));
        Steps::settle(state, state.frontier_, state.row_.view(), wraps(rows.flags[index]));
        changed = true;
      }

      changed = Steps::readTail(state, rows, extent) || changed;
      if (changed) {
        ++state.revision_;
      }

      return changed;
    }

    static void follow(State& state, const Extent& extent) noexcept {
      state.extent_ = extent;
    }

    static void copy(const State& state, ds::String<Memory>& text) {
      text.clear();
      text.append(state.settled_.text());
      text.append(state.tail_.text());
      // The last line's break is the copy's own.
      if (!text.empty() && text.view().back() == '\n') {
        text.truncate(text.size() - 1);
      }
    }

    static std::size_t highlight(State& state, std::span<const CellValue> cells, std::span<Mark> marks) {
      if (!Access::filtering(state) || state.query_.invert || marks.empty()) {
        return 0;
      }

      // The row's text, and the column each of its bytes is drawn in.
      state.row_.clear();
      state.columns_.clear();
      for (std::size_t column = 0; column < cells.size(); ++column) {
        const auto& cell = cells[column];
        if (cell.width == CellWidth::continuation) {
          continue;
        }

        const auto bytes = cell.utf8();

        state.row_.append(bytes);
        for (std::size_t byte = 0; byte < bytes.size(); ++byte) {
          state.columns_.push(static_cast<std::uint16_t>(column));
        }
      }

      const auto& pattern = *state.pattern_.getMut();
      // The blanks a row is drawn with past its text are none of the line's, which `$` ends.
      const auto drawn = state.row_.view();
      const auto text = drawn.substr(0, drawn.find_last_not_of(' ') + 1);
      std::size_t count = 0;

      for (std::size_t from = 0; count < marks.size() && from <= text.size();) {
        const auto match = pattern.find(text, from);
        if (!match) {
          break;
        }

        if (match->end == match->begin) {
          from = match->end + 1;
          continue;
        }

        const auto first = state.columns_[match->begin];
        const auto last = state.columns_[match->end - 1];
        const auto width = cells[last].width == CellWidth::wide ? 2U : 1U;

        marks[count++] = Mark{.column = first, .length = static_cast<std::uint16_t>(last + width - first)};
        from = match->end;
      }

      return count;
    }
  };

  void open(State& state, const Opening& opening) {
    Steps::open(state, opening);
  }

  bool query(State& state, const Query& query) {
    return Steps::query(state, query);
  }

  ds::Option<std::uint64_t> close(State& state) noexcept {
    return Steps::close(state);
  }

  bool open(const State& state) noexcept {
    return Steps::open(state);
  }

  bool filters(const State& state, std::uint64_t pane_id, std::uint64_t block) noexcept {
    return Steps::filters(state, pane_id, block);
  }

  Status status(const State& state) noexcept {
    return Steps::status(state);
  }

  std::uint64_t revision(const State& state) noexcept {
    return Steps::revision(state);
  }

  ds::Option<RowRequest> wanted(const State& state, const Extent& extent) noexcept {
    return Steps::wanted(state, extent);
  }

  void asked(State& state, std::uint64_t request_id, RowRequest rows) noexcept {
    Steps::asked(state, request_id, rows);
  }

  bool receive(State& state, const PaneRows& reply, const Extent& extent) {
    return Steps::receive(state, reply, extent);
  }

  bool fail(State& state, std::uint64_t request_id) noexcept {
    return Steps::fail(state, request_id);
  }

  bool screen(State& state, const ScreenRows& rows, const Extent& extent) {
    return Steps::screen(state, rows, extent);
  }

  void follow(State& state, const Extent& extent) noexcept {
    Steps::follow(state, extent);
  }

  void copy(const State& state, ds::String<Memory>& text) {
    Steps::copy(state, text);
  }

  std::size_t highlight(State& state, std::span<const CellValue> cells, std::span<Mark> marks) {
    return Steps::highlight(state, cells, marks);
  }

}
