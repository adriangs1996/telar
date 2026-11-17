module telar.gui.features.history;

import std;

import telar.base.text.utf8;
import telar.gui.foundation.core;
import telar.tbc;
import telar.base.memory.allocators;
import telar.wire.history;
import telar.wire.vocabulary;

namespace telar::gui::features::history {

  template <Allocator Memory>
  HistoryRow<Memory>::HistoryRow(Memory& memory)
      : command(AllocatorRef<char, Memory>{memory}),
        cwd(AllocatorRef<char, Memory>{memory}),
        provider(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  HistoryPageStorage<Memory>::HistoryPageStorage(tbc::view<Memory&, tbc::lt::a> memory, std::span<const HistoryEntry> entries)
      : rows_(AllocatorRef<HistoryRow<Memory>, Memory>{memory}),
        commands_(AllocatorRef<char, Memory>{memory}) {
    entries = entries.first(std::min(entries.size(), maximum_entries));
    rows_.reserve(entries.size());
    commands_.reserve(commandBytes(entries));
    for (const auto& entry : entries) {
      append(memory, entry);
    }
  }

  template <Allocator Memory>
  void HistoryPageStorage<Memory>::exchangeWith(HistoryPageStorage& other) {
    if (rows_.get_allocator() != other.rows_.get_allocator()) {
      throw std::invalid_argument{"History pages must share an allocator"};
    }

    rows_.swap(other.rows_);
    commands_.swap(other.commands_);
  }

  template <Allocator Memory>
  const Vector<HistoryRow<Memory>, Memory>& HistoryPageStorage<Memory>::rows() const noexcept {
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
  void HistoryPageStorage<Memory>::append(tbc::view<Memory&, tbc::lt::a> memory, const HistoryEntry& entry) {
    auto& row = rows_.emplace_back(memory);

    row.id = entry.id;
    row.pane_id = entry.pane_id;
    row.command = runtime::utf8Prefix(entry.command, command_preview_bytes);
    row.cwd = entry.cwd;
    row.provider = entry.provider;
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

    for (const auto byte : bytes) {
      if (state != State::ground) {
        state = advance(state, byte);

        continue;
      }

      if (byte == escape) {
        state = State::escape;

        continue;
      }

      if (byte != '\n' && byte != '\t' && (byte < first_printable || byte == delete_control)) {
        continue;
      }

      if (written == output.size()) {
        return written;
      }

      output[written++] = static_cast<char>(byte);
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
    default:
      return State::ground;
    }
  }

  HistorySearch HistorySearch::parse(std::string_view text, bool failed_only) noexcept {
    if (text.starts_with('!')) {
      failed_only = true;
      text.remove_prefix(1);
      while (text.starts_with(' ')) {
        text.remove_prefix(1);
      }
    }

    return {.query = text, .failed_only = failed_only};
  }

  template <Allocator Memory>
  HistoryBrowser<Memory>::HistoryBrowser(Memory& memory)
      : memory_(memory),
        page_(memory),
        selected_command_(AllocatorRef<char, Memory>{memory}),
        query_(AllocatorRef<char, Memory>{memory}),
        scope_path_(AllocatorRef<char, Memory>{memory}),
        output_(AllocatorRef<char, Memory>{memory}) {}

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
  QueryHistory HistoryBrowser<Memory>::refresh(std::uint64_t request_id) {
    return requestPage({.request_id = request_id});
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::canPage(HistoryPage direction) const noexcept {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return false;
    }

    return direction == HistoryPage::older ? state_.has_more : state_.page_offset != 0;
  }

  template <Allocator Memory>
  std::optional<QueryHistory> HistoryBrowser<Memory>::page(HistoryPage direction, std::uint64_t request_id) {
    if (!canPage(direction)) {
      return {};
    }

    const auto older = std::min<std::uint64_t>(static_cast<std::uint64_t>(state_.page_offset) + page_.rows().size(), std::numeric_limits<std::uint32_t>::max());
    const auto newer = state_.page_offset - std::min<std::uint32_t>(state_.page_offset, page_entries);
    const auto offset = direction == HistoryPage::older ? static_cast<std::uint32_t>(older) : newer;

    return requestPage({.request_id = request_id, .offset = offset, .snapshot_id = state_.snapshot_id});
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryResults& message) {
    retire(message.request_id);
    if (message.request_id != 0 && message.request_id == command_request_) {
      return applyCommand(message.entries);
    }

    if (message.request_id == 0 || message.request_id != page_request_ || state_.phase != HistoryPhase::loading) {
      return false;
    }

    auto incoming = copyPage(message.entries);

    const bool newer = pending_offset_ < state_.page_offset;

    page_.exchangeWith(incoming);
    state_.phase = HistoryPhase::ready;
    state_.snapshot_id = message.snapshot_id;
    state_.has_more = message.has_more;
    state_.has_page = true;
    state_.page_offset = pending_offset_;
    state_.selection = newer && !page_.rows().empty() ? page_.rows().size() - 1 : 0;
    page_request_ = 0;
    ++rows_version_;
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  const HistoryRow<Memory>& HistoryBrowser<Memory>::entry(std::uint64_t id) const {
    return page_.rows()[entryIndex(id)];
  }

  template <Allocator Memory>
  std::size_t HistoryBrowser<Memory>::entryIndex(std::uint64_t id) const {
    if (state_.phase != HistoryPhase::ready) {
      throw EncodingError{"History results are not ready"};
    }

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
  std::optional<QueryHistory> HistoryBrowser<Memory>::readCommand(std::uint64_t request_id) {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    const auto& row = page_.rows()[state_.selection];
    if (row.command_complete || row.command_truncated || state_.command_id == row.id) {
      return {};
    }

    track(request_id);
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
  std::optional<ReadHistoryOutput> HistoryBrowser<Memory>::readOutput(std::uint64_t request_id) {
    if (!state_.inspecting || state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    const auto id = page_.rows()[state_.selection].id;
    if (state_.output_id == id) {
      return {};
    }

    track(request_id);
    output_request_ = request_id;
    state_.output_id = id;
    state_.output_phase = HistoryPhase::loading;
    contentChanged();

    return ReadHistoryOutput{.request_id = request_id, .id = id};
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
      output_.resize(PlainText::strip(message.content, {output_.data(), output_.size()}));
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
    static_cast<void>(entry(id));
    if (delete_request_ != 0) {
      throw EncodingError{"A history deletion is already pending"};
    }

    track(request_id);
    delete_request_ = request_id;
    contentChanged();

    return {.request_id = request_id, .id = id};
  }

  template <Allocator Memory>
  bool HistoryBrowser<Memory>::apply(const HistoryPruned& message) {
    retire(message.request_id);
    if (message.request_id == 0 || message.request_id != delete_request_) {
      return false;
    }

    delete_request_ = 0;
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
  bool HistoryBrowser<Memory>::fail(std::uint64_t request_id, std::string_view message) {
    retire(request_id);
    if (request_id != 0 && request_id == page_request_) {
      state_.phase = HistoryPhase::failed;
      page_request_ = 0;
    } else if (request_id != 0 && request_id == output_request_) {
      state_.output_phase = HistoryPhase::failed;
      output_request_ = 0;
    } else if (request_id != 0 && request_id == command_request_) {
      state_.command_phase = HistoryPhase::failed;
      command_request_ = 0;
    } else if (request_id != 0 && request_id == delete_request_) {
      delete_request_ = 0;
    } else {
      return false;
    }

    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();

    return true;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::suspend() noexcept {
    requests_.fill(0);
    page_request_ = 0;
    delete_request_ = 0;
    state_.phase = HistoryPhase::idle;
    clearCommand();
    clearOutput();
    contentChanged();
  }

  template <Allocator Memory>
  const Vector<HistoryRow<Memory>, Memory>& HistoryBrowser<Memory>::rows() const noexcept {
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
  std::optional<HistoryChoice> HistoryBrowser<Memory>::choice() const noexcept {
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
  bool HistoryBrowser<Memory>::deleting() const noexcept {
    return delete_request_ != 0;
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
    String<Memory> next_query{query.query, AllocatorRef<char, Memory>{memory_}};
    String<Memory> next_scope{AllocatorRef<char, Memory>{memory_}};

    if (const auto* path = std::get_if<std::string_view>(&query.scope_value)) {
      next_scope = *path;
    }

    query_ = std::move(next_query);
    scope_path_ = std::move(next_scope);
    const auto* const scope_id = std::get_if<std::uint64_t>(&query.scope_value);

    criteria_ = {
        .scope = query.scope,
        .scope_id = scope_id == nullptr ? std::nullopt : std::optional{*scope_id},
        .scope_path = std::holds_alternative<std::string_view>(query.scope_value),
        .failed_only = query.failed_only,
        .author = query.author,
        .match = query.match,
        .distinct = query.distinct,
    };

    delete_request_ = 0;

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
        .offset = page.offset,
        .snapshot_id = page.snapshot_id,
        .entry_id = 0,
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
      selected_command_ = entries.front().command;
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
    state_.phase = HistoryPhase::failed;
    page_request_ = 0;
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  template <Allocator Memory>
  QueryHistory HistoryBrowser<Memory>::requestPage(PageRequest page) {
    track(page.request_id);
    page_request_ = page.request_id;
    pending_offset_ = page.offset;
    state_.phase = HistoryPhase::loading;
    error_.assign({});
    clearCommand();
    clearOutput();
    contentChanged();

    return request(page);
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::track(std::uint64_t request_id) {
    auto* const slot = std::ranges::find(requests_, std::uint64_t{0});
    if (request_id == 0 || slot == requests_.end() || owns(request_id)) {
      state_.phase = HistoryPhase::failed;
      contentChanged();
      throw EncodingError{"History is busy; retry the search"};
    }

    *slot = request_id;
  }

  template <Allocator Memory>
  void HistoryBrowser<Memory>::retire(std::uint64_t request_id) noexcept {
    if (auto* const slot = std::ranges::find(requests_, request_id); request_id != 0 && slot != requests_.end()) {
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
