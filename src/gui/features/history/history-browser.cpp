module telar.gui.features.history;

import std;

import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.tbc;
import telar.base.memory.allocators;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::features::history {

  template <Allocator Memory>
  HistoryRow<Memory>::HistoryRow(Memory& memory)
      : command(memory),
        cwd(memory),
        provider(memory),
        host(memory),
        excerpt(memory) {}

  template <Allocator Memory>
  HistoryPageStorage<Memory>::HistoryPageStorage(tbc::mut_a<Memory> memory, std::span<const HistoryEntry> entries)
      : rows_(memory),
        commands_(memory) {
    entries = entries.first(std::min(entries.size(), maximum_entries));
    rows_.reserve(entries.size());
    commands_.reserve(commandBytes(entries));
    for (const auto& entry : entries) {
      append(memory, entry);
    }
  }

  template <Allocator Memory>
  void HistoryPageStorage<Memory>::exchangeWith(HistoryPageStorage& other) {
    if (&rows_.memory() != &other.rows_.memory()) {
      throw std::invalid_argument{"History pages must share an allocator"};
    }

    std::swap(rows_, other.rows_);
    std::swap(commands_, other.commands_);
  }

  template <Allocator Memory>
  const ds::Vec<HistoryRow<Memory>, Memory>& HistoryPageStorage<Memory>::rows() const noexcept {
    return rows_;
  }

  template <Allocator Memory>
  std::string_view HistoryPageStorage<Memory>::command(std::size_t index) const {
    const auto& row = rows_[index];
    if (!row.command_complete) {
      return {};
    }

    if (row.full_length == 0) {
      return row.command;
    }

    return std::string_view{commands_}.substr(row.full_offset, row.full_length);
  }

  template <Allocator Memory>
  void HistoryPageStorage<Memory>::remove(std::size_t index) {
    static_cast<void>(rows_.remove(index));
  }

  template <Allocator Memory>
  std::size_t HistoryPageStorage<Memory>::commandBytes(std::span<const HistoryEntry> entries) {
    std::size_t bytes = 0;

    for (const auto& entry : entries) {
      static_cast<void>(ValueCodec<HistoryEntry>::encodedSize(entry));
      if (entry.command.size() > command_preview_bytes && entry.command.size() <= command_cache_bytes - bytes) {
        bytes += entry.command.size();
      }
    }

    return bytes;
  }

  template <Allocator Memory>
  void HistoryPageStorage<Memory>::append(tbc::mut_a<Memory> memory, const HistoryEntry& entry) {
    auto& row = rows_.emplace(memory);

    row.id = entry.id;
    row.pane_id = entry.pane_id;
    row.command.assign(runtime::utf8Prefix(entry.command, command_preview_bytes));
    row.cwd.assign(entry.cwd);
    row.provider.assign(entry.provider);
    row.host.assign(entry.host);
    row.excerpt.assign(runtime::utf8Prefix(entry.excerpt, max_history_excerpt_bytes));
    row.ranges.assign(entry.ranges);
    row.excerpt_ranges.assign(entry.excerpt_ranges);
    row.run_count = entry.run_count;
    row.neighbour = entry.neighbour;
    row.started_at_ms = entry.started_at_ms;
    row.duration_ns = entry.duration_ns;
    row.exit_code = entry.exit_code;
    row.status = entry.status;
    row.author = entry.author;
    row.origin = entry.origin;
    row.command_truncated = entry.command_truncated;
    row.command_complete = entry.command.size() <= command_preview_bytes;
    if (!row.command_complete && entry.command.size() <= command_cache_bytes - commands_.size()) {
      row.full_offset = commands_.size();
      row.full_length = entry.command.size();
      commands_.append(entry.command);
      row.command_complete = true;
    }
  }

  std::size_t PlainText::strip(std::span<const Byte> bytes, std::span<char> output) noexcept {
    State state = State::ground;
    std::size_t written = 0;
    // Where the line being written starts, and whether a carriage return went back to it: what
    // follows on the line replaces it, as a progress bar's last state does.
    std::size_t line_start = 0;
    bool returned = false;

    for (const auto byte : bytes) {
      if (state != State::ground) {
        state = advance(state, byte);

        continue;
      }

      if (byte == escape) {
        state = State::escape;

        continue;
      }

      if (byte == '\r') {
        returned = true;

        continue;
      }

      if (byte != '\n' && byte != '\t' && (byte < first_printable || byte == delete_control)) {
        continue;
      }

      // A carriage return before a newline ends the line it is on; before anything else it
      // takes the line back to its start.
      if (returned && byte != '\n') {
        written = line_start;
      }

      returned = false;
      if (written == output.size()) {
        return written;
      }

      output[written++] = static_cast<char>(byte);
      if (byte == '\n') {
        line_start = written;
      }
    }

    return written;
  }

  PlainText::State PlainText::escapeState(Byte byte) noexcept {
    switch (byte) {
    case '[':
      return State::csi;
    case ']':
    case 'P':
    case 'X':
    case '^':
    case '_':
      return State::string;
    case escape:
      return State::escape;
    default:
      return byte >= first_intermediate && byte <= last_intermediate ? State::intermediate : State::ground;
    }
  }

  PlainText::State PlainText::advance(State state, Byte byte) noexcept {
    switch (state) {
    case State::escape:
      return escapeState(byte);
    case State::intermediate:
      if (byte == escape) {
        return State::escape;
      }

      return byte >= first_escape_final ? State::ground : State::intermediate;
    case State::csi:
      if (byte == escape) {
        return State::escape;
      }

      return byte >= first_csi_final && byte <= last_csi_final ? State::ground : State::csi;
    case State::string:
      if (byte == bell) {
        return State::ground;
      }

      return byte == escape ? State::string_escape : State::string;
    case State::string_escape:
      if (byte == '\\') {
        return State::ground;
      }

      return byte == escape ? State::string_escape : State::string;
    case State::ground:
      break;
    }

    // The ground state, or one outside the enum.
    return State::ground;
  }

  template <Allocator Memory>
  HistoryBrowser<Memory>::HistoryBrowser(Memory& memory)
      : memory_(memory),
        page_(memory),
        selected_command_(memory),
        query_(memory),
        scope_path_(memory),
        host_(memory),
        branch_(memory),
        shell_(memory),
        origin_cwd_(memory),
        output_(memory),
        context_text_(memory),
        hidden_command_(memory),
        marked_text_(memory) {}

  template <Allocator Memory>
  QueryHistory HistoryBrowser<Memory>::begin(QueryHistory query) {
    try {
      return prepareQuery(query);
    } catch (...) {
      rejectQuery("Could not start history search");
      throw;
    }
  }

  template <Allocator Memory>
  ds::Option<QueryHistory> HistoryBrowser<Memory>::refresh(std::uint64_t request_id) {
    // A search or a page on its way reads the history as it is now.
    if (state_.load == HistoryLoad::search || state_.load == HistoryLoad::page) {
      return {};
    }

    // One on its way may have read the history before the change: one more follows it, however
    // many changes come meanwhile.
    if (state_.load == HistoryLoad::refresh && page_request_ != 0) {
      refresh_again_ = true;
      return {};
    }

    // The same page from a new insertion boundary; a later page its deletes emptied gives way to
    // the one before it.
    const bool emptied = page_.rows().empty() && state_.page_offset != 0;
    const auto start = emptied ? newerStart() : page_start_;

    if (state_.phase != HistoryPhase::ready) {
      return requestPage({.request_id = request_id, .start = start});
    }

    // The rows stay usable while it loads: nothing they show changes until its page arrives.
    track(request_id);
    page_request_ = request_id;
    pending_start_ = start;
    state_.load = HistoryLoad::refresh;

    return request({.request_id = request_id, .start = start});
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::canPage(HistoryPage direction) const noexcept {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return false;
    }

    return direction == HistoryPage::older ? state_.has_more : state_.page_offset != 0;
  }

  template <Allocator Memory>
  ds::Option<QueryHistory> HistoryBrowser<Memory>::page(HistoryPage direction, std::uint64_t request_id) {
    if (!canPage(direction)) {
      return {};
    }

    // A page the search entered before this one is where going back returns; one past what it
    // remembers, or that a refresh left, a page of matches back.
    while (newer_count_ != 0 && newer_starts_[newer_count_ - 1].offset >= state_.page_offset) {
      --newer_count_;
    }

    PageStart start = newerStart();

    if (direction == HistoryPage::older) {
      const auto& last = page_.rows().back();

      start = {.offset = static_cast<std::uint32_t>(std::min<std::uint64_t>(static_cast<std::uint64_t>(state_.page_offset) + matchesShown(), std::numeric_limits<std::uint32_t>::max()))};
      if (listsByTime()) {
        start.after_started_ms = last.started_at_ms;
        start.after_id = last.id;
      }
    }

    auto query = requestPage({.request_id = request_id, .start = start, .snapshot_id = state_.snapshot_id, .load = HistoryLoad::page});

    if (direction == HistoryPage::older) {
      // The oldest is forgotten first.
      if (newer_count_ == remembered_pages) {
        std::ranges::copy(newer_starts_.view().subspan(1), newer_starts_.viewMut().begin());
        --newer_count_;
      }

      newer_starts_.atMut(newer_count_++) = page_start_;
    }

    return query;
  }

  template <Allocator Memory>
  std::uint32_t HistoryBrowser<Memory>::matchesShown() const noexcept {
    return static_cast<std::uint32_t>(std::ranges::count(page_.rows(), false, &HistoryRow<Memory>::neighbour));
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::listsByTime() const noexcept {
    if (criteria_.output) {
      return true;
    }

    switch (criteria_.sort) {
    case HistorySort::rank:
      return false;
    case HistorySort::time:
      return true;
    case HistorySort::automatic:
      break;
    }

    return criteria_.match != HistoryMatch::fuzzy || query_.empty();
  }

  template <Allocator Memory>
  auto HistoryBrowser<Memory>::newerStart() const noexcept -> PageStart {
    if (newer_count_ != 0) {
      return newer_starts_[newer_count_ - 1];
    }

    return {.offset = state_.page_offset - std::min<std::uint32_t>(state_.page_offset, page_entries)};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryResults& message) {
    retire(message.request_id);
    if (message.request_id != 0 && message.request_id == command_request_) {
      return applyCommand(message.entries);
    }

    if (message.request_id != 0 && message.request_id == context_request_) {
      return applyContext(message.entries);
    }

    if (message.request_id == 0 || message.request_id != page_request_ || state_.load == HistoryLoad::none) {
      return false;
    }

    auto incoming = copyPage(message.entries);

    // A page read before a delete the runtime has yet to confirm, or one that waits for its undo
    // to pass, still holds its row.
    for (std::size_t index = incoming.rows().size(); index-- > 0;) {
      if (incoming.rows()[index].id == hidden_id_ || std::ranges::contains(deleted_ids_, incoming.rows()[index].id)) {
        incoming.remove(index);
      }
    }

    const auto load = std::exchange(state_.load, HistoryLoad::none);

    refresh_due_ = std::exchange(refresh_again_, false) && load == HistoryLoad::refresh;
    const bool newer = load == HistoryLoad::page && pending_start_.offset < state_.page_offset;
    ds::Option<KeptSelection> kept;

    // A refresh keeps the command selected when it arrives, which may not be the one selected
    // when it was asked for.
    if (load == HistoryLoad::refresh) {
      const bool emptied = page_.rows().empty() && pending_start_.offset < state_.page_offset;
      KeptSelection selected{.index = emptied ? std::numeric_limits<std::size_t>::max() : state_.selection};

      if (state_.selection < page_.rows().size()) {
        selected.id = page_.rows()[state_.selection].id;
        selected.status = page_.rows()[state_.selection].status;
      }

      kept = selected;
    }

    page_.exchangeWith(incoming);
    state_.phase = HistoryPhase::ready;
    state_.snapshot_id = message.snapshot_id;
    state_.has_more = message.has_more;
    state_.has_page = true;
    page_start_ = pending_start_;
    state_.page_offset = page_start_.offset;
    if (kept) {
      restoreSelection(*kept);
    } else {
      state_.selection = newer && !page_.rows().empty() ? page_.rows().size() - 1 : 0;
    }

    page_request_ = 0;
    ++rows_version_;
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  const HistoryRow<Memory>& HistoryBrowser<Memory>::entry(std::uint64_t id) const {
    return page_.rows()[entryIndex(id)];
  }

  // A row shown is usable while the next page loads: copying or deleting what the panel shows
  // never waits for a page that may not hold it.
  template <Allocator Memory>
  std::size_t HistoryBrowser<Memory>::entryIndex(std::uint64_t id) const {
    const auto found = std::ranges::find(page_.rows(), id, &HistoryRow<Memory>::id);
    if (found == page_.rows().end()) {
      throw EncodingError{"The selected command is no longer available"};
    }

    return static_cast<std::size_t>(found - page_.rows().begin());
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::command(std::uint64_t id) const {
    const auto index = entryIndex(id);
    const auto& row = page_.rows()[index];
    if (row.command_truncated) {
      throw EncodingError{"Command unavailable or capture truncated; cannot paste"};
    }

    if (row.command_complete) {
      return page_.command(index);
    }

    if (state_.command_id == id && state_.command_phase == HistoryPhase::ready) {
      return selected_command_;
    }

    throw EncodingError{"The selected command is not loaded; cannot paste"};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::canSubmit() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return false;
    }

    const auto& row = page_.rows()[state_.selection];

    return !row.command_truncated && (row.command_complete || (state_.command_id == row.id && state_.command_phase == HistoryPhase::ready));
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::selectedCommand() const {
    if (state_.selection >= page_.rows().size()) {
      return {};
    }

    const auto& row = page_.rows()[state_.selection];
    if (row.command_complete) {
      return page_.command(state_.selection);
    }

    return state_.command_id == row.id && state_.command_phase == HistoryPhase::ready ? std::string_view{selected_command_} : std::string_view{row.command};
  }

  template <Allocator Memory>
  ds::Option<QueryHistory> HistoryBrowser<Memory>::readCommand(std::uint64_t request_id) {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    const auto& row = page_.rows()[state_.selection];
    if (row.command_complete || row.command_truncated || state_.command_id == row.id) {
      return {};
    }

    try {
      track(request_id);
    } catch (...) {
      state_.command_id = row.id;
      state_.command_phase = HistoryPhase::failed;
      contentChanged();
      throw;
    }

    command_request_ = request_id;
    state_.command_id = row.id;
    state_.command_phase = HistoryPhase::loading;
    contentChanged();

    return QueryHistory{.request_id = request_id, .limit = 1, .entry_id = row.id};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::select(std::size_t index) {
    if (state_.phase != HistoryPhase::ready || index >= page_.rows().size() || state_.selection == index) {
      return false;
    }

    state_.selection = index;
    const auto& selected = page_.rows()[index];
    if (!selected.command_complete && !selected.command_truncated && (state_.command_id != selected.id || state_.command_phase == HistoryPhase::failed)) {
      clearCommand();
    }

    error_.assign({});
    clearOutput();
    ++view_version_;

    return true;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::setInspecting(bool enabled) {
    if (state_.inspecting != enabled) {
      state_.inspecting = enabled;
      clearOutput();
      ++view_version_;
    }
  }

  template <Allocator Memory>
  ds::Option<ReadHistoryOutput> HistoryBrowser<Memory>::readOutput(std::uint64_t request_id) {
    if (!state_.inspecting || state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    // A failed output is read again; one read or on its way is not.
    const auto id = page_.rows()[state_.selection].id;
    if (state_.output_id == id && state_.output_phase != HistoryPhase::failed) {
      return {};
    }

    try {
      track(request_id);
    } catch (...) {
      state_.output_id = id;
      state_.output_phase = HistoryPhase::failed;
      contentChanged();
      throw;
    }

    output_request_ = request_id;
    state_.output_id = id;
    state_.output_phase = HistoryPhase::loading;
    contentChanged();

    return ReadHistoryOutput{.request_id = request_id, .id = id};
  }

  template <Allocator Memory>
  ds::Option<QueryHistory> HistoryBrowser<Memory>::sameCommand(std::uint64_t request_id) const {
    if (!state_.inspecting || state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    const auto& row = page_.rows()[state_.selection];
    const auto command = row.command_complete ? page_.command(state_.selection) : std::string_view{};
    if (command.empty() || command.size() > QueryHistory::maximum_query_bytes) {
      return {};
    }

    return QueryHistory{
        .request_id = request_id,
        .query = command,
        .author = HistoryAuthorFilter::all,
        .match = HistoryMatch::prefix,
        .distinct = false,
        .limit = page_entries,
        .sort = HistorySort::time,
    };
  }

  template <Allocator Memory>
  ds::Option<QueryHistoryCommandStats> HistoryBrowser<Memory>::readRuns(std::uint64_t request_id, std::int64_t until_ms) {
    const auto id = page_.rows().empty() ? 0 : page_.rows()[state_.selection].id;
    // Read once a command, and again after a failure. By the entry, the runtime reads the
    // command's whole text, however long, whatever the row holds of it.
    if (!state_.inspecting || state_.phase != HistoryPhase::ready || id == 0 || (runs_id_ == id && state_.runs_phase != HistoryPhase::failed)) {
      return {};
    }

    track(request_id);
    runs_request_ = request_id;
    runs_id_ = id;
    run_stats_ = {};
    state_.runs_phase = HistoryPhase::loading;
    contentChanged();

    return QueryHistoryCommandStats{.request_id = request_id, .entry_id = id, .days = HistoryRunStats::days, .until_ms = until_ms};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryCommandStats& message) {
    retire(message.request_id);
    if (message.request_id == 0 || message.request_id != runs_request_) {
      return false;
    }

    runs_request_ = 0;
    HistoryRunStats stats{.runs = message.runs, .measured = message.measured, .mean_duration_ms = message.mean_duration_ms, .ended = message.ended, .succeeded = message.succeeded, .last_started_ms = message.last_started_ms, .last_exit = message.last_exit};
    // The days end today, the oldest first: fewer than asked fill the newest.
    const auto days = message.per_day.last(std::min(message.per_day.size(), stats.per_day.size()));

    std::ranges::copy(days, stats.per_day.viewMut().subspan(stats.per_day.size() - days.size()).begin());
    run_stats_ = stats;
    state_.runs_phase = HistoryPhase::ready;
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  ds::Option<QueryHistory> HistoryBrowser<Memory>::readContext(std::uint64_t request_id) {
    const auto id = page_.rows().empty() ? 0 : page_.rows()[state_.selection].id;
    const auto pane_id = page_.rows().empty() ? 0 : page_.rows()[state_.selection].pane_id;
    if (pane_id == 0 || (context_id_ == id && state_.context_phase != HistoryPhase::failed)) {
      return {};
    }

    const auto same = sameCommand(request_id);
    if (!same) {
      return {};
    }

    // The runs of the command in its pane, each with the runs around it; the one inspected is
    // among them unless the pane ran the command more often since than a page holds.
    auto query = *same;

    query.scope = HistoryScope::pane;
    query.scope_value = pane_id;
    query.neighbours = HistoryLimits::context_entries;
    track(request_id);
    context_request_ = request_id;
    context_id_ = id;
    context_count_ = 0;
    context_text_.clear();
    state_.context_phase = HistoryPhase::loading;
    contentChanged();

    return query;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::applyContext(std::span<const HistoryEntry> entries) {
    context_request_ = 0;
    context_count_ = 0;
    context_text_.clear();
    const auto found = std::ranges::find(entries, context_id_, &HistoryEntry::id);

    try {
      if (found != entries.end()) {
        keepContext(entries, static_cast<std::size_t>(found - entries.begin()));
      }
    } catch (...) {
      context_count_ = 0;
      state_.context_phase = HistoryPhase::failed;
      contentChanged();
      throw;
    }

    state_.context_phase = HistoryPhase::ready;
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::keepContext(std::span<const HistoryEntry> entries, std::size_t inspected) {
    // A listing by time runs newest first, the runs around each match beside it: those before
    // the one inspected ran after it.
    const auto first = inspected - std::min(inspected, HistoryLimits::context_entries);
    const auto last = std::min(entries.size(), inspected + 1 + HistoryLimits::context_entries);

    for (auto index = first; index < last; ++index) {
      if (index == inspected) {
        continue;
      }

      const auto command = runtime::utf8Prefix(entries[index].command, HistoryLimits::command_preview_bytes);

      context_.atMut(context_count_++) = {.offset = context_text_.size(), .length = command.size(), .newer = index < inspected};
      context_text_.append(command);
    }
  }

  template <Allocator Memory>
  const HistoryRunStats& HistoryBrowser<Memory>::runStats() const noexcept {
    return run_stats_;
  }

  template <Allocator Memory>
  std::size_t HistoryBrowser<Memory>::contextCount() const noexcept {
    return context_count_;
  }

  template <Allocator Memory>
  HistoryContextEntry HistoryBrowser<Memory>::contextAt(std::size_t index) const {
    if (index >= context_count_) {
      return {};
    }

    const auto& line = context_[index];

    return {.command = std::string_view{context_text_}.substr(line.offset, line.length), .newer = line.newer};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryOutput& message) {
    retire(message.request_id);
    if (message.request_id == 0 || message.request_id != output_request_ || message.id != state_.output_id) {
      return false;
    }

    try {
      if (message.content.size() > maximum_output_bytes) {
        throw EncodingError{"History output exceeds its byte capacity"};
      }

      output_.resize(message.content.size());
      output_.resize(PlainText::strip(message.content, output_.viewMut()));
    } catch (...) {
      state_.output_phase = HistoryPhase::failed;
      output_request_ = 0;
      error_.assign("Could not store captured output");
      contentChanged();
      throw;
    }

    state_.output_phase = HistoryPhase::ready;
    state_.output_truncated = message.truncated;
    error_.assign({});
    output_request_ = 0;
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  DeleteHistory HistoryBrowser<Memory>::erase(std::uint64_t id, std::uint64_t request_id) {
    const auto index = entryIndex(id);
    const auto slot = static_cast<std::size_t>(std::ranges::find(delete_requests_, std::uint64_t{0}) - delete_requests_.begin());

    track(request_id);
    // track bounds the requests in flight by the same count as the slots.
    delete_requests_.atMut(slot) = request_id;
    deleted_ids_.atMut(slot) = id;

    // The row leaves at once.
    removeRow(index);

    return {.request_id = request_id, .id = id};
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::removeRow(std::size_t index) {
    page_.remove(index);
    state_.selection = std::min(state_.selection, page_.rows().empty() ? 0 : page_.rows().size() - 1);
    clearCommand();
    clearOutput();
    ++rows_version_;
    contentChanged();
  }

  template <Allocator Memory>
  // NOLINTNEXTLINE(bugprone-easily-swappable-parameters): the command and the request that may delete the one before it, as erase names them
  ds::Option<DeleteHistory> HistoryBrowser<Memory>::hide(std::uint64_t id, std::uint64_t request_id) {
    const auto index = entryIndex(id);
    // The delete that waited before can no longer be taken back.
    const auto previous = commitHidden(request_id);

    hidden_command_.assign(page_.rows()[index].command);
    hidden_id_ = id;
    removeRow(index);

    return previous;
  }

  template <Allocator Memory>
  ds::Option<DeleteHistory> HistoryBrowser<Memory>::commitHidden(std::uint64_t request_id) {
    if (hidden_id_ == 0) {
      return {};
    }

    const auto slot = static_cast<std::size_t>(std::ranges::find(delete_requests_, std::uint64_t{0}) - delete_requests_.begin());

    track(request_id);
    // track bounds the requests in flight by the same count as the slots.
    delete_requests_.atMut(slot) = request_id;
    deleted_ids_.atMut(slot) = std::exchange(hidden_id_, 0);
    hidden_command_.clear();
    contentChanged();

    return DeleteHistory{.request_id = request_id, .id = deleted_ids_[slot]};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::unhide() noexcept {
    if (hidden_id_ == 0) {
      return false;
    }

    hidden_id_ = 0;
    hidden_command_.clear();
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  std::uint64_t HistoryBrowser<Memory>::hidden() const noexcept {
    return hidden_id_;
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::hiddenCommand() const noexcept {
    return hidden_command_;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::toggleMark(std::uint64_t id) {
    const auto marks = std::span{marks_}.first(mark_count_);
    const auto found = std::ranges::find(marks, id, &Mark::id);

    if (found != marks.end()) {
      // The text after the mark's moves back over it.
      const auto removed = *found;
      const auto index = static_cast<std::size_t>(found - marks.begin());

      marked_text_.remove(removed.offset, removed.length);
      for (auto next = index + 1; next < mark_count_; ++next) {
        auto moved = marks_[next];

        moved.offset -= removed.length;
        marks_.atMut(next - 1) = moved;
      }

      --mark_count_;
      contentChanged();

      return false;
    }

    const auto command = this->command(id);
    if (mark_count_ == marks_.size() || command.size() > HistoryLimits::maximum_marked_bytes - marked_text_.size()) {
      throw EncodingError{"Too many commands marked to use together"};
    }

    marks_.atMut(mark_count_++) = {.id = id, .offset = marked_text_.size(), .length = command.size()};
    marked_text_.append(command);
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::clearMarks() noexcept {
    if (mark_count_ == 0) {
      return;
    }

    mark_count_ = 0;
    marked_text_.clear();
    contentChanged();
  }

  template <Allocator Memory>
  std::size_t HistoryBrowser<Memory>::markCount() const noexcept {
    return mark_count_;
  }

  template <Allocator Memory>
  std::uint64_t HistoryBrowser<Memory>::markedId(std::size_t index) const noexcept {
    return index < mark_count_ ? marks_[index].id : 0;
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::markedCommand(std::size_t index) const {
    return index < mark_count_ ? std::string_view{marked_text_}.substr(marks_[index].offset, marks_[index].length) : std::string_view{};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::marked(std::uint64_t id) const noexcept {
    return std::ranges::contains(std::span{marks_}.first(mark_count_), id, &Mark::id);
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryPruned& message) {
    retire(message.request_id);
    return message.request_id != 0 && forgetDelete(message.request_id);
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::forgetDelete(std::uint64_t request_id) noexcept {
    const auto* const found = std::ranges::find(delete_requests_, request_id);
    if (found == delete_requests_.end()) {
      return false;
    }

    const auto slot = static_cast<std::size_t>(found - delete_requests_.begin());

    delete_requests_.atMut(slot) = 0;
    deleted_ids_.atMut(slot) = 0;
    contentChanged();
    return true;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::owns(std::uint64_t request_id) const noexcept {
    return request_id != 0 && std::ranges::find(requests_, request_id) != requests_.end();
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  template <Allocator Memory>
  HistoryFailure HistoryBrowser<Memory>::fail(std::uint64_t request_id, std::string_view message) {
    retire(request_id);
    auto failure = HistoryFailure::none;

    if (request_id != 0 && request_id == page_request_) {
      // A search's rows answered the query before it: they leave, or they would show under the
      // new query, its matches highlighted in them. A page or a refresh leaves the rows usable.
      if (std::exchange(state_.load, HistoryLoad::none) == HistoryLoad::search) {
        clearRows();
        state_.phase = HistoryPhase::failed;
      } else {
        state_.phase = HistoryPhase::ready;
      }

      page_request_ = 0;
      failure = HistoryFailure::page;
    } else if (request_id != 0 && request_id == output_request_) {
      state_.output_phase = HistoryPhase::failed;
      output_request_ = 0;
      failure = HistoryFailure::detail;
    } else if (request_id != 0 && request_id == command_request_) {
      state_.command_phase = HistoryPhase::failed;
      command_request_ = 0;
      failure = HistoryFailure::detail;
    } else if (request_id != 0 && request_id == runs_request_) {
      state_.runs_phase = HistoryPhase::failed;
      runs_request_ = 0;
      failure = HistoryFailure::detail;
    } else if (request_id != 0 && request_id == context_request_) {
      state_.context_phase = HistoryPhase::failed;
      context_request_ = 0;
      failure = HistoryFailure::detail;
    } else if (request_id != 0 && forgetDelete(request_id)) {
      failure = HistoryFailure::erase;
    } else {
      return HistoryFailure::none;
    }

    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();

    return failure;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::suspend() noexcept {
    requests_.fill(0);
    page_request_ = 0;
    state_.load = HistoryLoad::none;
    delete_requests_.fill(0);
    deleted_ids_.fill(0);
    hidden_id_ = 0;
    hidden_command_.clear();
    // The panel follows a runtime connected again from its next search.
    watching_ = false;
    refresh_again_ = false;
    refresh_due_ = false;
    state_.phase = HistoryPhase::idle;
    clearCommand();
    clearOutput();
    contentChanged();
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::watch(bool watching) noexcept {
    return std::exchange(watching_, watching) != watching;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::watching() const noexcept {
    return watching_;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::takeRefreshDue() noexcept {
    return std::exchange(refresh_due_, false);
  }

  template <Allocator Memory>
  const ds::Vec<HistoryRow<Memory>, Memory>& HistoryBrowser<Memory>::rows() const noexcept {
    return page_.rows();
  }

  template <Allocator Memory>
  const HistoryViewState& HistoryBrowser<Memory>::state() const noexcept {
    return state_;
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::output() const noexcept {
    return output_;
  }

  template <Allocator Memory>
  std::string_view HistoryBrowser<Memory>::error() const noexcept {
    return error_.view();
  }

  template <Allocator Memory>
  std::uint64_t HistoryBrowser<Memory>::viewVersion() const noexcept {
    return view_version_;
  }

  template <Allocator Memory>
  std::uint64_t HistoryBrowser<Memory>::revision() const noexcept {
    return revision_;
  }

  template <Allocator Memory>
  ds::Option<HistoryChoice> HistoryBrowser<Memory>::choice() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return {};
    }

    return HistoryChoice{.index = state_.selection, .revision = revision_};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::acceptsRow(HistoryChoice candidate) const noexcept {
    return state_.phase == HistoryPhase::ready && candidate.revision == revision_ && candidate.index < page_.rows().size();
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::accepts(HistoryChoice candidate) const noexcept {
    return acceptsRow(candidate) && candidate.index == state_.selection;
  }

  template <Allocator Memory>
  std::uint64_t HistoryBrowser<Memory>::rowsVersion() const noexcept {
    return rows_version_;
  }

  template <Allocator Memory>
  HistoryScope HistoryBrowser<Memory>::scope() const noexcept {
    return criteria_.scope;
  }

  template <Allocator Memory>
  HistoryMatch HistoryBrowser<Memory>::match() const noexcept {
    return criteria_.match;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::preloads() const noexcept {
    return criteria_.preload;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::searchesOutput() const noexcept {
    return criteria_.output;
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::deleting() const noexcept {
    return std::ranges::any_of(delete_requests_, [](std::uint64_t request) {
      return request != 0;
    });
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::contentChanged() noexcept {
    ++revision_;
    ++view_version_;
  }

  template <Allocator Memory>
  QueryHistory HistoryBrowser<Memory>::prepareQuery(QueryHistory query) {
    query.query = runtime::utf8Prefix(query.query, maximum_query_bytes);
    query.limit = page_entries;
    query.offset = 0;
    query.snapshot_id = 0;
    query.entry_id = 0;
    static_cast<void>(Codec::encodedSize(query));
    ds::String<Memory> next_query{memory_, query.query};
    ds::String<Memory> next_scope{memory_};
    ds::String<Memory> next_host{memory_, query.host};
    ds::String<Memory> next_branch{memory_, query.branch};
    ds::String<Memory> next_shell{memory_, query.shell};
    ds::String<Memory> next_origin{memory_, query.origin_cwd};

    if (const auto* path = std::get_if<std::string_view>(&query.scope_value)) {
      next_scope.assign(*path);
    }

    query_ = std::move(next_query);
    scope_path_ = std::move(next_scope);
    host_ = std::move(next_host);
    branch_ = std::move(next_branch);
    shell_ = std::move(next_shell);
    origin_cwd_ = std::move(next_origin);
    const auto* const scope_id = std::get_if<std::uint64_t>(&query.scope_value);

    criteria_ = {
        .scope = query.scope,
        .scope_id = scope_id == nullptr ? ds::none : ds::Option{*scope_id},
        .scope_path = std::holds_alternative<std::string_view>(query.scope_value),
        .failed_only = query.failed_only,
        .author = query.author,
        .match = query.match,
        .distinct = query.distinct,
        .sort = query.sort,
        .since_ms = query.since_ms,
        .until_ms = query.until_ms,
        .exit_code = query.exit_code,
        .min_duration_ms = query.min_duration_ms,
        .origin_pane = query.origin_pane,
        .neighbours = query.neighbours,
        .preload = query.preload,
        .output = query.output,
    };

    newer_count_ = 0;
    delete_requests_.fill(0);
    deleted_ids_.fill(0);

    return requestPage({.request_id = query.request_id});
  }

  template <Allocator Memory>
  QueryHistory HistoryBrowser<Memory>::request(PageRequest page) const noexcept {
    HistoryScopeValue scope_value{};

    if (criteria_.scope_path) {
      scope_value = std::string_view{scope_path_};
    } else if (criteria_.scope_id) {
      scope_value = *criteria_.scope_id;
    }

    return {
        .request_id = page.request_id,
        .query = query_,
        .scope = criteria_.scope,
        .scope_value = scope_value,
        .failed_only = criteria_.failed_only,
        .author = criteria_.author,
        .match = criteria_.match,
        .distinct = criteria_.distinct,
        .limit = page_entries,
        .offset = page.start.offset,
        .snapshot_id = page.snapshot_id,
        .entry_id = 0,
        .sort = criteria_.sort,
        .since_ms = criteria_.since_ms,
        .until_ms = criteria_.until_ms,
        .exit_code = criteria_.exit_code,
        .min_duration_ms = criteria_.min_duration_ms,
        .host = host_,
        .branch = branch_,
        .shell = shell_,
        .preload = criteria_.preload,
        .output = criteria_.output,
        .neighbours = criteria_.neighbours,
        .origin_pane = criteria_.origin_pane,
        .origin_cwd = origin_cwd_,
        .after_started_ms = page.start.after_started_ms,
        .after_id = page.start.after_id,
    };
  }

  template <Allocator Memory>
  HistoryPageStorage<Memory> HistoryBrowser<Memory>::copyPage(std::span<const HistoryEntry> entries) {
    try {
      return HistoryPageStorage<Memory>{memory_, entries};
    } catch (...) {
      rejectQuery("Could not store history results");
      throw;
    }
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::applyCommand(std::span<const HistoryEntry> entries) {
    command_request_ = 0;
    if (entries.size() != 1 || entries.front().id != state_.command_id || entries.front().command_truncated || entries.front().command.empty() || entries.front().command.size() > maximum_command_bytes) {
      state_.command_phase = HistoryPhase::failed;
      error_.assign("The selected command is no longer available");
      contentChanged();

      return true;
    }

    try {
      static_cast<void>(ValueCodec<HistoryEntry>::encodedSize(entries.front()));
      selected_command_.reserve(maximum_command_bytes);
      selected_command_.assign(entries[0].command);
    } catch (...) {
      state_.command_phase = HistoryPhase::failed;
      error_.assign("Could not store the selected command");
      contentChanged();
      throw;
    }

    state_.command_phase = HistoryPhase::ready;
    error_.assign({});
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::rejectQuery(std::string_view message) {
    clearRows();
    state_.phase = HistoryPhase::failed;
    state_.load = HistoryLoad::none;
    page_request_ = 0;
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::clearRows() {
    HistoryPageStorage<Memory> empty{memory_};

    page_.exchangeWith(empty);
    state_.selection = 0;
    state_.has_more = false;
    clearCommand();
    clearOutput();
    ++rows_version_;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::restoreSelection(KeptSelection kept) {
    const auto& rows = page_.rows();
    if (rows.empty()) {
      state_.selection = 0;
      clearCommand();
      clearOutput();

      return;
    }

    const auto found = kept.id == 0 ? rows.end() : std::ranges::find(rows, kept.id, &HistoryRow<Memory>::id);

    state_.selection = found != rows.end() ? static_cast<std::size_t>(found - rows.begin()) : std::min(kept.index, rows.size() - 1);
    // The details of the command still selected stay, so the inspector does not flicker; a
    // command that ended since has more output to read.
    const auto& selected = rows[state_.selection];
    if (selected.id != kept.id) {
      clearCommand();
      clearOutput();
    } else if (selected.status != kept.status) {
      clearOutput();
    }
  }

  template <Allocator Memory>
  QueryHistory HistoryBrowser<Memory>::requestPage(PageRequest page) {
    // A page that does not fit leaves the rows as they are; a search's caller fails them.
    track(page.request_id);
    page_request_ = page.request_id;
    pending_start_ = page.start;
    state_.phase = HistoryPhase::loading;
    state_.load = page.load;
    error_.assign({});
    clearCommand();
    clearOutput();
    contentChanged();

    return request(page);
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::track(std::uint64_t request_id) {
    const auto requests = requests_.viewMut();
    const auto slot = std::ranges::find(requests, std::uint64_t{0});
    // The caller fails the phase of the request that did not fit, never another one's.
    if (request_id == 0 || slot == requests.end() || owns(request_id)) {
      throw EncodingError{"History is busy; retry the search"};
    }

    *slot = request_id;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::retire(std::uint64_t request_id) noexcept {
    if (request_id == 0) {
      return;
    }

    const auto requests = requests_.viewMut();
    const auto slot = std::ranges::find(requests, request_id);
    if (slot != requests.end()) {
      *slot = 0;
    }
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::clearCommand() noexcept {
    command_request_ = 0;
    state_.command_id = 0;
    state_.command_phase = HistoryPhase::idle;
    selected_command_.clear();
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::clearOutput() noexcept {
    output_request_ = 0;
    state_.output_id = 0;
    state_.output_phase = HistoryPhase::idle;
    state_.output_truncated = false;
    output_.clear();
    // The runs and the context are the inspector's too.
    runs_request_ = 0;
    context_request_ = 0;
    runs_id_ = 0;
    context_id_ = 0;
    state_.runs_phase = HistoryPhase::idle;
    state_.context_phase = HistoryPhase::idle;
    run_stats_ = {};
    context_count_ = 0;
    context_text_.clear();
  }

  // What production passes (ApplicationAllocator) and what the session tests pass.
  template struct HistoryRow<telar::Memory>;
  template struct HistoryRow<telar::ConcurrentMemory>;
  template struct HistoryRow<telar::SystemAllocator>;
  template class HistoryPageStorage<telar::Memory>;
  template class HistoryPageStorage<telar::ConcurrentMemory>;
  template class HistoryPageStorage<telar::SystemAllocator>;
  template class HistoryBrowser<telar::Memory>;
  template class HistoryBrowser<telar::ConcurrentMemory>;
  template class HistoryBrowser<telar::SystemAllocator>;

}
