module telar.runtime.nvim.screen;

import std;
import telar.tbc;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.wire.nvim;

namespace telar::runtime {

  namespace {

    // U+FFFD, packed as a cell keeps its text.
    constexpr std::uint32_t replacement_glyph = 0x00bd'bfefU;
    constexpr std::size_t cluster_slot_count = NvimLimits::clusters * 2;
    constexpr std::size_t scroll_capacity = 64;

    constexpr unsigned byte_bits = 8;
    constexpr std::uint32_t byte_mask = 0xff;

    constexpr std::uint32_t pack(std::string_view text) noexcept {
      std::uint32_t glyph = 0;
      unsigned shift = 0;

      for (const auto character : text) {
        glyph |= static_cast<std::uint32_t>(static_cast<std::uint8_t>(character)) << shift;
        shift += byte_bits;
      }

      return glyph;
    }

    constexpr std::size_t hash(std::string_view text) noexcept {
      constexpr std::uint64_t offset = 0xcbf2'9ce4'8422'2325ULL;
      constexpr std::uint64_t prime = 0x0000'0100'0000'01b3ULL;
      std::uint64_t value = offset;

      for (const auto character : text) {
        value = (value ^ static_cast<std::uint8_t>(character)) * prime;
      }

      return static_cast<std::size_t>(value % cluster_slot_count);
    }

    // The longest prefix of `text` of at most `limit` bytes that ends between two characters.
    constexpr std::string_view clip(std::string_view text, std::size_t limit) {
      constexpr std::uint8_t continuation_mask = 0xc0;
      constexpr std::uint8_t continuation_bits = 0x80;

      if (text.size() <= limit) {
        return text;
      }

      while (limit > 0 && (static_cast<std::uint8_t>(text[limit]) & continuation_mask) == continuation_bits) {
        --limit;
      }

      return text.substr(0, limit);
    }

  }

  tbc::val_a<std::string_view> NvimSlice::of(tbc::val_a<std::string_view> text) const {
    return text.substr(std::min<std::size_t>(offset, text.size()), size);
  }

  namespace {

    // Copies the cells a scroll moves, row by row from the end the rows leave. A row that moves
    // whole keeps the flush that last changed it; one that moves in part changed `now`.
    void moveRows(NvimScreenGrid& grid, NvimScroll scroll, std::uint64_t now) {
      const bool upward = scroll.rows > 0;
      const bool whole_rows = scroll.left == 0 && scroll.right == grid.columns;
      const std::size_t width = static_cast<std::size_t>(scroll.right) - scroll.left;
      const std::size_t columns = grid.columns;
      const int step = upward ? 1 : -1;
      const int last = upward ? scroll.bottom - scroll.rows : scroll.top - scroll.rows - 1;
      const auto cells = grid.cells.viewMut();
      const auto changed = grid.row_changed_at.viewMut();

      for (int row = upward ? scroll.top : scroll.bottom - 1; row != last; row += step) {
        const auto source = static_cast<std::size_t>(std::ptrdiff_t{row} + scroll.rows);
        const auto target = static_cast<std::size_t>(row);

        // A row never overlaps another: the copy leaves its source as it was.
        std::ranges::copy(cells.subspan((source * columns) + scroll.left, width), cells.subspan((target * columns) + scroll.left, width).begin());
        changed[target] = whole_rows ? changed[source] : now;
      }

      grid.cells_at = now;
    }

    // Keeps a scroll of whole rows for clients to replay: they are then sent only the rows that
    // changed. Past what a flush keeps, the grid is sent whole instead.
    void recordScroll(NvimScreenGrid& grid, NvimScroll scroll, std::uint64_t now) {
      if (grid.scrolled_at != now) {
        grid.scrolled_before = grid.scrolled_at;
        grid.scrolled_at = now;
        grid.scrolls.clear();
      }

      if (grid.scrolls.size() == scroll_capacity) {
        std::ranges::fill(grid.row_changed_at.viewMut(), now);
        grid.scrolls.clear();
        grid.reset_at = now;
      } else if (grid.reset_at != now) {
        grid.scrolls.push(scroll);
      }
    }

  }

  NvimScreenGrid::NvimScreenGrid(ConcurrentMemory& memory, std::uint32_t identity)
      : id(identity),
        cells(memory),
        row_changed_at(memory),
        scrolls(memory) {}

  std::span<const NvimCell> NvimScreenGrid::row(std::uint32_t index) const noexcept {
    return cells.view().subspan(std::size_t{index} * columns, columns);
  }

  NvimStyledText::NvimStyledText(ConcurrentMemory& memory)
      : text(memory),
        chunks(memory) {}

  void NvimStyledText::clear() noexcept {
    text.clear();
    chunks.clear();
  }

  void NvimStyledText::append(std::string_view added, std::uint16_t highlight) {
    const auto kept = clip(added, NvimLimits::surface_bytes - std::min(NvimLimits::surface_bytes, text.size()));
    if (kept.empty()) {
      return;
    }

    chunks.push({.offset = static_cast<std::uint32_t>(text.size()), .size = static_cast<std::uint32_t>(kept.size()), .highlight = highlight});
    text.extend(std::span<const char>{kept});
  }

  std::string_view NvimStyledText::view() const noexcept {
    return {text.data(), text.size()};
  }

  NvimCommandLine::NvimCommandLine(ConcurrentMemory& memory)
      : content(memory),
        prompt(memory),
        block(memory) {}

  NvimCompletion::NvimCompletion(ConcurrentMemory& memory)
      : text(memory),
        items(memory) {}

  NvimMessage::NvimMessage(ConcurrentMemory& memory)
      : content(memory) {}

  NvimMessages::NvimMessages(ConcurrentMemory& memory)
      : visible(memory),
        mode(memory),
        command(memory),
        ruler(memory),
        history(memory) {}

  NvimTabs::NvimTabs(ConcurrentMemory& memory)
      : text(memory),
        tabs(memory),
        buffers(memory) {}

  NvimScreen::NvimScreen(ConcurrentMemory& memory)
      : memory_(memory),
        grids_(memory),
        highlights_(memory),
        links_(memory),
        clusters_(memory),
        cluster_slots_(memory),
        modes_(memory),
        mode_name_(memory),
        title_(memory),
        directory_(memory),
        command_line_(memory),
        completion_(memory),
        messages_(memory),
        tabs_(memory),
        removed_(memory) {
    highlights_.push({});
  }

  void NvimScreen::touch() noexcept {
    settled_ = false;
  }

  std::uint64_t NvimScreen::stamp() const noexcept {
    return flushed_ + 1;
  }

  std::uint64_t NvimScreen::flushed() const noexcept {
    return flushed_;
  }

  bool NvimScreen::settled() const noexcept {
    return settled_;
  }

  void NvimScreen::flush() noexcept {
    flushed_ = stamp();
    settled_ = true;
  }

  ds::Option<std::size_t> NvimScreen::indexOf(std::uint32_t id) const noexcept {
    if (recent_ < grids_.size() && grids_[recent_]->id == id) {
      return recent_;
    }

    for (std::size_t index = 0; index < grids_.size(); ++index) {
      if (grids_[index]->id == id) {
        recent_ = index;
        return index;
      }
    }

    return ds::none;
  }

  NvimScreenGrid* NvimScreen::find(std::uint32_t id) noexcept {
    const auto index = indexOf(id);

    return index ? &grids_.atMut(*index).getMut() : nullptr;
  }

  NvimScreenGrid& NvimScreen::add(std::uint32_t id) {
    recent_ = grids_.size();
    return grids_.push(ds::makeBox<NvimScreenGrid>(memory_, memory_, id)).getMut();
  }

  void NvimScreen::reset(NvimScreenGrid& grid, std::uint64_t stamp) noexcept {
    std::ranges::fill(grid.row_changed_at.viewMut(), stamp);
    grid.scrolls.clear();
    grid.reset_at = stamp;
    grid.cells_at = stamp;
  }

  bool NvimScreen::resize(std::uint32_t id, NvimExtent size) {
    if (size.columns == 0 || size.rows == 0 || size.columns > NvimLimits::columns || size.rows > NvimLimits::rows) {
      return false;
    }

    auto* grid = find(id);
    const std::size_t wanted = std::size_t{size.columns} * size.rows;
    const std::size_t held = grid == nullptr ? 0 : grid->cells.size();
    if (cell_count_ - held + wanted > NvimLimits::cells || (grid == nullptr && grids_.size() == NvimLimits::grids)) {
      return false;
    }

    touch();
    if (grid == nullptr) {
      grid = &add(id);
    }

    // What the old size and the new share stays where it was until Neovim redraws it.
    ds::Vec<NvimCell, ConcurrentMemory> cells{memory_};

    cells.resize(wanted, NvimCell{});

    const auto shared_rows = std::min<std::uint32_t>(size.rows, grid->rows);
    const auto shared_columns = std::min<std::uint32_t>(size.columns, grid->columns);

    for (std::uint32_t row = 0; row < shared_rows; ++row) {
      std::ranges::copy(grid->row(row).first(shared_columns), cells.viewMut().subspan(std::size_t{row} * size.columns).begin());
    }

    cell_count_ = cell_count_ - held + wanted;
    grid->cells = std::move(cells);
    grid->columns = static_cast<std::uint16_t>(size.columns);
    grid->rows = static_cast<std::uint16_t>(size.rows);
    grid->row_changed_at.resize(size.rows, stamp());
    reset(*grid, stamp());
    return true;
  }

  void NvimScreen::clear(std::uint32_t id) {
    auto* grid = find(id);
    if (grid == nullptr) {
      return;
    }

    touch();
    std::ranges::fill(grid->cells.viewMut(), NvimCell{});
    reset(*grid, stamp());
  }

  void NvimScreen::destroy(std::uint32_t id) noexcept {
    for (std::size_t index = 0; index < grids_.size(); ++index) {
      if (grids_[index]->id != id) {
        continue;
      }

      touch();
      cell_count_ -= grids_[index]->cells.size();

      [[maybe_unused]] const auto removed = grids_.remove(index);

      if (removed_.size() == NvimLimits::grids) {
        removed_forgotten_at_ = removed_.front().at;
        [[maybe_unused]] const auto forgotten = removed_.remove(0);
      }

      removed_.push({.grid = id, .at = stamp()});
      return;
    }
  }

  bool NvimScreen::line(std::uint32_t id, NvimPoint start) noexcept {
    const auto index = indexOf(id);
    const auto now = stamp();

    if (!index) {
      return false;
    }

    auto& grid = grids_.atMut(*index).getMut();
    if (start.row >= grid.rows || start.column >= grid.columns) {
      return false;
    }

    grid.row_changed_at.atMut(start.row) = now;
    grid.cells_at = now;
    put_grid_ = *index;
    put_ = start;
    touch();
    return true;
  }

  std::uint32_t NvimScreen::intern(std::string_view text) {
    const auto kept = clip(text, NvimCell::text_capacity);

    if (cluster_slots_.empty()) {
      cluster_slots_.resize(cluster_slot_count, 0);
    }

    auto slot = hash(kept);

    while (cluster_slots_[slot] != 0) {
      const auto& cluster = clusters_[cluster_slots_[slot] - 1U];
      if (std::string_view{cluster.bytes.data(), cluster.size} == kept) {
        return cluster_slots_[slot] - 1U;
      }

      slot = (slot + 1) % cluster_slot_count;
    }

    if (clusters_.size() == NvimLimits::clusters) {
      cluster_overflow_ = true;
      return std::numeric_limits<std::uint32_t>::max();
    }

    Cluster cluster;

    std::ranges::copy(kept, cluster.bytes.viewMut().begin());
    cluster.size = static_cast<std::uint8_t>(kept.size());
    clusters_.push(cluster);
    cluster_slots_.atMut(slot) = static_cast<std::uint16_t>(clusters_.size());
    return static_cast<std::uint32_t>(clusters_.size() - 1);
  }

  bool NvimScreen::put(std::string_view text, NvimRun run) {
    NvimCell cell{.glyph = 0, .highlight = run.highlight, .flags = 0};

    if (text.empty()) {
      // The right half of a double-width character: the cell before it holds the character.
      cell.flags = NvimCell::continuation;
    } else if (text.size() <= sizeof(cell.glyph)) {
      cell.glyph = pack(text);
    } else {
      const auto index = intern(text);
      const bool kept = index != std::numeric_limits<std::uint32_t>::max();

      cell.glyph = kept ? index : replacement_glyph;
      cell.flags = kept ? NvimCell::cluster : 0;
    }

    auto& grid = grids_.atMut(put_grid_).getMut();
    if (run.repeat > grid.columns - put_.column) {
      return false;
    }

    const auto first = (std::size_t{put_.row} * grid.columns) + put_.column;
    const auto cells = grid.cells.viewMut();

    if (text.empty() && put_.column > 0 && run.repeat > 0) {
      cells[first - 1].flags |= NvimCell::wide;
    }

    std::ranges::fill(cells.subspan(first, run.repeat), cell);
    put_.column += run.repeat;
    return true;
  }

  bool NvimScreen::dropClusters(std::span<NvimCell> row) noexcept {
    bool dropped = false;

    for (auto& cell : row) {
      if ((cell.flags & NvimCell::cluster) != 0) {
        cell.glyph = replacement_glyph;
        cell.flags = static_cast<std::uint8_t>(cell.flags & ~NvimCell::cluster);
        dropped = true;
      }
    }

    return dropped;
  }

  void NvimScreen::dropClusters() noexcept {
    for (std::size_t index = 0; index < grids_.size(); ++index) {
      auto& owned = grids_.atMut(index).getMut();

      for (std::uint32_t row = 0; row < owned.rows; ++row) {
        if (dropClusters(owned.cells.viewMut().subspan(std::size_t{row} * owned.columns, owned.columns))) {
          owned.row_changed_at.atMut(row) = stamp();
          owned.cells_at = stamp();
        }
      }
    }

    clusters_.clear();
    std::ranges::fill(cluster_slots_.viewMut(), std::uint16_t{0});
  }

  bool NvimScreen::takeClusterOverflow() noexcept {
    if (!cluster_overflow_) {
      return false;
    }

    cluster_overflow_ = false;
    touch();
    dropClusters();
    return true;
  }

  bool NvimScreen::scroll(std::uint32_t id, NvimScroll scroll) {
    const auto now = stamp();
    auto* grid = find(id);
    if (grid == nullptr) {
      return true;
    }

    const int height = scroll.bottom - scroll.top;

    if (scroll.top >= scroll.bottom || scroll.left >= scroll.right || scroll.bottom > grid->rows || scroll.right > grid->columns) {
      return false;
    }

    if (scroll.rows == 0 || std::abs(scroll.rows) >= height) {
      return true;
    }

    const bool whole_rows = scroll.left == 0 && scroll.right == grid->columns;

    moveRows(*grid, scroll, now);
    if (whole_rows) {
      recordScroll(*grid, scroll, now);
    }

    touch();
    return true;
  }

  void NvimScreen::moveCursor(std::uint32_t grid, NvimPoint place) noexcept {
    touch();
    cursor_.grid = grid;
    cursor_.row = static_cast<std::uint16_t>(std::min<std::uint32_t>(place.row, NvimLimits::rows));
    cursor_.column = static_cast<std::uint16_t>(std::min<std::uint32_t>(place.column, NvimLimits::columns));
    cursor_.changed_at = stamp();
  }

  void NvimScreen::hideCursor(bool hidden) noexcept {
    if (cursor_.hidden == hidden) {
      return;
    }

    touch();
    cursor_.hidden = hidden;
    cursor_.changed_at = stamp();
  }

  void NvimScreen::defaultColors(std::uint32_t foreground, std::uint32_t background, std::uint32_t special) noexcept {
    const NvimHighlight colors{.foreground = foreground, .background = background, .special = special};
    if (colors == defaults_) {
      return;
    }

    touch();
    defaults_ = colors;
    highlights_at_ = stamp();

    // Neovim does not redraw what only changed its default colors: every row is sent again.
    for (std::size_t index = 0; index < grids_.size(); ++index) {
      reset(grids_.atMut(index).getMut(), stamp());
    }
  }

  bool NvimScreen::highlight(std::uint32_t id, NvimHighlight value) {
    if (id >= NvimLimits::highlights) {
      return false;
    }

    touch();
    if (id >= highlights_.size()) {
      highlights_.resize(std::size_t{id} + 1, NvimHighlight{});
    }

    highlights_.atMut(id) = value;
    highlights_at_ = stamp();
    return true;
  }

  std::uint16_t NvimScreen::link(std::string_view url) {
    const auto kept = clip(url, NvimLimits::link_bytes);

    for (std::size_t index = 0; index < links_.size(); ++index) {
      if (links_[index].view() == kept) {
        return static_cast<std::uint16_t>(index + 1);
      }
    }

    if (links_.size() == NvimLimits::links) {
      return 0;
    }

    links_.push(ds::String<ConcurrentMemory>{memory_, kept});
    return static_cast<std::uint16_t>(links_.size());
  }

  NvimScreenGrid* NvimScreen::place(std::uint32_t id, NvimPlacement placement) {
    auto* grid = find(id);
    if (grid == nullptr) {
      if (grids_.size() == NvimLimits::grids) {
        return nullptr;
      }

      grid = &add(id);
    }

    touch();
    grid->placement = placement;
    grid->placed_at = stamp();
    return grid;
  }

  void NvimScreen::hide(std::uint32_t id) noexcept {
    auto* grid = find(id);
    if (grid == nullptr || grid->placement == NvimPlacement::hidden) {
      return;
    }

    touch();
    grid->placement = NvimPlacement::hidden;
    grid->placed_at = stamp();
  }

  void NvimScreen::viewport(std::uint32_t id, const NvimViewport& viewport, std::int64_t scroll_delta) noexcept {
    auto* grid = find(id);
    if (grid == nullptr || (grid->viewport == viewport && scroll_delta == 0)) {
      return;
    }

    touch();
    grid->viewport = viewport;
    grid->scrolled_lines += scroll_delta;
    grid->viewport_at = stamp();
  }

  void NvimScreen::margins(std::uint32_t id, NvimMargins margins) noexcept {
    auto* grid = find(id);
    if (grid == nullptr || grid->margins == margins) {
      return;
    }

    touch();
    grid->margins = margins;
    grid->viewport_at = stamp();
  }

  bool NvimScreen::mode(std::size_t index, NvimMode mode) {
    if (index >= NvimLimits::modes) {
      return false;
    }

    touch();
    if (index >= modes_.size()) {
      modes_.resize(index + 1, NvimMode{});
    }

    modes_.atMut(index) = mode;
    mode_at_ = stamp();
    return true;
  }

  void NvimScreen::truncateModes(std::size_t count) noexcept {
    if (count < modes_.size()) {
      touch();
      modes_.truncate(count);
      mode_at_ = stamp();
    }
  }

  void NvimScreen::currentMode(std::size_t index, std::string_view name) {
    constexpr std::size_t name_bytes = 64;

    touch();
    current_mode_ = index;
    mode_name_.assign(clip(name, name_bytes));
    mode_at_ = stamp();
  }

  void NvimScreen::title(std::string_view title) {
    constexpr std::size_t title_bytes = 1024;

    touch();
    title_.assign(clip(title, title_bytes));
    title_at_ = stamp();
  }

  void NvimScreen::directory(std::string_view path) {
    if (path.size() > NvimLimits::path_bytes) {
      return;
    }

    touch();
    directory_.assign(path);
    directory_at_ = stamp();
  }

  void NvimScreen::mouse(bool enabled) noexcept {
    mouse_ = enabled;
  }

  NvimCommandLine& NvimScreen::commandLineMut() noexcept {
    touch();
    command_line_.changed_at = stamp();
    return command_line_;
  }

  NvimCompletion& NvimScreen::completionMut() noexcept {
    touch();
    completion_.changed_at = stamp();
    return completion_;
  }

  NvimMessages& NvimScreen::messagesMut() noexcept {
    touch();
    messages_.changed_at = stamp();
    return messages_;
  }

  NvimTabs& NvimScreen::tabsMut() noexcept {
    touch();
    tabs_.changed_at = stamp();
    return tabs_;
  }

  std::span<const ds::Box<NvimScreenGrid, ConcurrentMemory>> NvimScreen::grids() const noexcept {
    return grids_.view();
  }

  const NvimScreenGrid* NvimScreen::grid(std::uint32_t id) const noexcept {
    const auto index = indexOf(id);

    return index ? &*grids_[*index] : nullptr;
  }

  std::span<const NvimRemoved> NvimScreen::removed() const noexcept {
    return removed_.view();
  }

  std::uint64_t NvimScreen::removedForgottenAt() const noexcept {
    return removed_forgotten_at_;
  }

  const NvimHighlight& NvimScreen::highlightOf(std::uint16_t id) const noexcept {
    return highlights_[id < highlights_.size() ? id : 0];
  }

  std::string_view NvimScreen::linkOf(const NvimHighlight& highlight) const noexcept {
    return highlight.link == 0 || highlight.link > links_.size() ? std::string_view{} : links_[highlight.link - 1U].view();
  }

  std::uint64_t NvimScreen::highlightsAt() const noexcept {
    return highlights_at_;
  }

  NvimHighlight NvimScreen::defaults() const noexcept {
    return defaults_;
  }

  std::size_t NvimScreen::copyText(const NvimCell& cell, std::span<char, NvimCell::text_capacity> destination) const noexcept {
    if ((cell.flags & NvimCell::continuation) != 0) {
      return 0;
    }

    if ((cell.flags & NvimCell::cluster) != 0) {
      if (cell.glyph >= clusters_.size()) {
        return 0;
      }

      const auto& cluster = clusters_[cell.glyph];

      std::ranges::copy(cluster.bytes.view().first(cluster.size), destination.begin());
      return cluster.size;
    }

    std::size_t size = 0;

    for (auto glyph = cell.glyph; glyph != 0; glyph >>= byte_bits) {
      destination[size++] = static_cast<char>(glyph & byte_mask);
    }

    return size;
  }

  const NvimCursor& NvimScreen::cursor() const noexcept {
    return cursor_;
  }

  std::span<const NvimMode> NvimScreen::modes() const noexcept {
    return modes_.view();
  }

  std::size_t NvimScreen::currentMode() const noexcept {
    return current_mode_;
  }

  std::string_view NvimScreen::modeName() const noexcept {
    return mode_name_.view();
  }

  std::uint64_t NvimScreen::modeAt() const noexcept {
    return mode_at_;
  }

  std::string_view NvimScreen::title() const noexcept {
    return title_.view();
  }

  std::uint64_t NvimScreen::titleAt() const noexcept {
    return title_at_;
  }

  std::string_view NvimScreen::directory() const noexcept {
    return directory_.view();
  }

  std::uint64_t NvimScreen::directoryAt() const noexcept {
    return directory_at_;
  }

  bool NvimScreen::mouseEnabled() const noexcept {
    return mouse_;
  }

  const NvimCommandLine& NvimScreen::commandLine() const noexcept {
    return command_line_;
  }

  const NvimCompletion& NvimScreen::completion() const noexcept {
    return completion_;
  }

  const NvimMessages& NvimScreen::messages() const noexcept {
    return messages_;
  }

  const NvimTabs& NvimScreen::tabs() const noexcept {
    return tabs_;
  }

}
