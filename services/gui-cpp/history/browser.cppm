module;
#include <chrono>
#include <concepts>
#include <cstdlib>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>
#include <cstring>
#include <exception>
#include <type_traits>
#include <cstdio>
#include <bit>

#include <cstddef>
#include <cstdint>

#include <optional>

#include <algorithm>
#include <span>
#include <stdexcept>
#include <string_view>

#include <array>
#include <limits>
#include <utility>
#include <variant>

export module telar.gui.history.browser;

import telar.base.diagnostics;
import telar.base.memory;
import telar.base.text;
import telar.client.protocol;
import telar.gui.core.primitives;


// Interface: history/choice.cppm
export {
namespace telar::gui {

struct HistoryChoice {
  std::size_t index = 0;
  std::uint64_t revision = 0;

  bool operator==(const HistoryChoice &) const = default;
};

}
}

// Interface: history/entry.cppm
export {
namespace telar::gui {

enum class HistoryPhase : std::uint8_t {
  idle,
  loading,
  ready,
  failed,
};

enum class HistoryPage : std::uint8_t {
  older,
  newer,
};

struct HistoryFilters {
  HistoryScope scope = HistoryScope::global;
  HistoryAuthorFilter author = HistoryAuthorFilter::human;
  bool failed_only = false;
};

struct HistoryViewState {
  HistoryPhase phase = HistoryPhase::idle;
  HistoryPhase command_phase = HistoryPhase::idle;
  HistoryPhase output_phase = HistoryPhase::idle;
  std::uint32_t page_offset = 0;
  std::uint64_t snapshot_id = 0;
  std::uint64_t output_id = 0;
  std::uint64_t command_id = 0;
  std::size_t selection = 0;
  bool has_page = false;
  bool has_more = false;
  bool inspecting = false;
  bool output_truncated = false;
};

template <Allocator Memory>
struct HistoryRow {
  inline explicit HistoryRow(Memory &memory)
      : command(AllocatorRef<char, Memory>{memory}),
        cwd(AllocatorRef<char, Memory>{memory}),
        provider(AllocatorRef<char, Memory>{memory}) {}

  std::uint64_t id = 0;
  std::uint64_t pane_id = 0;
  String<Memory> command;
  String<Memory> cwd;
  String<Memory> provider;
  std::size_t full_offset = 0;
  std::size_t full_length = 0;
  std::int64_t started_at_ms = 0;
  std::int64_t duration_ns = 0;
  std::optional<std::int32_t> exit_code;
  HistoryStatus status = HistoryStatus::completed;
  HistoryAuthor author = HistoryAuthor::human;
  HistoryOrigin origin = HistoryOrigin::pane;
  bool command_truncated = false;
  bool command_complete = false;
};

}
}

// Interface: history/page_storage.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class HistoryPageStorage {
public:
  static constexpr std::size_t maximum_entries = 100;
  static constexpr std::size_t command_preview_bytes = 512;
  static constexpr std::size_t command_cache_bytes = std::size_t{768} * 1024;

  inline explicit HistoryPageStorage(Memory &memory, std::span<const HistoryEntry> entries = {})
      : rows_(AllocatorRef<HistoryRow<Memory>, Memory>{memory}),
        commands_(AllocatorRef<char, Memory>{memory}) {
    entries = entries.first(std::min(entries.size(), maximum_entries));
    rows_.reserve(entries.size());
    commands_.reserve(commandBytes(entries));
    for (const auto &entry : entries) {
      append(memory, entry);
    }
  }

  inline void exchangeWith(HistoryPageStorage &other) {
    if (rows_.get_allocator() != other.rows_.get_allocator()) {
      throw std::invalid_argument{"History pages must share an allocator"};
    }

    rows_.swap(other.rows_);
    commands_.swap(other.commands_);
  }

  [[nodiscard]] inline const auto &rows() const noexcept {
    return rows_;
  }

  [[nodiscard]] inline std::string_view command(const HistoryRow<Memory> &row) const {
    if (!row.command_complete) {
      return {};
    }

    if (row.full_length == 0) {
      return row.command;
    }

    return std::string_view{commands_}.substr(row.full_offset, row.full_length);
  }

private:
  inline static std::size_t commandBytes(std::span<const HistoryEntry> entries) {
    std::size_t bytes = 0;
    for (const auto &entry : entries) {
      static_cast<void>(ValueCodec<HistoryEntry>::encodedSize(entry));
      if (entry.command.size() > command_preview_bytes && entry.command.size() <= command_cache_bytes - bytes) {
        bytes += entry.command.size();
      }
    }

    return bytes;
  }

  inline void append(Memory &memory, const HistoryEntry &entry) {
    auto &row = rows_.emplace_back(memory);
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

  Vector<HistoryRow<Memory>, Memory> rows_;
  String<Memory> commands_;
};

}
}

// Interface: history/plain_text.cppm
export {
namespace telar::gui {

class PlainText {
public:
  inline static std::size_t strip(std::span<const Byte> bytes, std::span<char> output) noexcept {
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

private:
  enum class State : Byte {
    ground,
    escape,
    intermediate,
    csi,
    string,
    string_escape,
  };

  static constexpr Byte escape = 0x1b;
  static constexpr Byte bell = 0x07;
  static constexpr Byte first_printable = 0x20;
  static constexpr Byte delete_control = 0x7f;
  static constexpr Byte first_intermediate = 0x20;
  static constexpr Byte last_intermediate = 0x2f;
  static constexpr Byte first_escape_final = 0x30;
  static constexpr Byte first_csi_final = 0x40;
  static constexpr Byte last_csi_final = 0x7e;

  inline static State escapeState(Byte byte) noexcept {
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

  inline static State advance(State state, Byte byte) noexcept {
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
};

}
}

// Interface: history/search.cppm
export {
namespace telar::gui {

struct HistorySearch {
  static constexpr std::size_t maximum_query_bytes = 128;

  std::string_view query;
  bool failed_only = false;

  [[nodiscard]] inline static HistorySearch parse(std::string_view text, bool failed_only) noexcept {
    if (text.starts_with('!')) {
      failed_only = true;
      text.remove_prefix(1);
      while (text.starts_with(' ')) {
        text.remove_prefix(1);
      }
    }

    return {.query = text, .failed_only = failed_only};
  }
};

}
}

// Interface: history/browser.cppm
export {
namespace telar::gui {

template <Allocator Memory>
class HistoryBrowser {
public:
  static constexpr auto page_entries = static_cast<std::uint16_t>(HistoryPageStorage<Memory>::maximum_entries);
  static constexpr std::size_t maximum_command_bytes = std::size_t{64} * 1024;
  static constexpr std::size_t maximum_query_bytes = HistorySearch::maximum_query_bytes;
  static constexpr std::size_t maximum_output_bytes = std::size_t{64} * 1024;
  static constexpr std::size_t maximum_requests = 128;
  static constexpr std::size_t maximum_error_bytes = 128;

  inline explicit HistoryBrowser(Memory &memory)
      : memory_(memory),
        page_(memory),
        selected_command_(AllocatorRef<char, Memory>{memory}),
        query_(AllocatorRef<char, Memory>{memory}),
        scope_path_(AllocatorRef<char, Memory>{memory}),
        output_(AllocatorRef<char, Memory>{memory}) {}

  ~HistoryBrowser() = default;
  HistoryBrowser(const HistoryBrowser &) = delete;
  HistoryBrowser &operator=(const HistoryBrowser &) = delete;
  HistoryBrowser(HistoryBrowser &&) = delete;
  HistoryBrowser &operator=(HistoryBrowser &&) = delete;

  [[nodiscard]] inline QueryHistory begin(QueryHistory query) {
    try {
      return prepareQuery(query);
    } catch (...) {
      rejectQuery("Could not start history search");
      throw;
    }
  }

  [[nodiscard]] inline QueryHistory refresh(std::uint64_t request_id) {
    auto request = criteria_;
    request.request_id = request_id;

    return requestPage(request);
  }

  [[nodiscard]] inline bool canPage(HistoryPage direction) const noexcept {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return false;
    }

    return direction == HistoryPage::older ? state_.has_more : state_.page_offset != 0;
  }

  [[nodiscard]] inline std::optional<QueryHistory> page(HistoryPage direction, std::uint64_t request_id) {
    if (!canPage(direction)) {
      return {};
    }

    const auto older = std::min<std::uint64_t>(static_cast<std::uint64_t>(state_.page_offset) + page_.rows().size(), std::numeric_limits<std::uint32_t>::max());
    const auto newer = state_.page_offset - std::min<std::uint32_t>(state_.page_offset, page_entries);
    const auto offset = direction == HistoryPage::older ? static_cast<std::uint32_t>(older) : newer;

    auto request = criteria_;
    request.request_id = request_id;
    request.offset = offset;
    request.snapshot_id = state_.snapshot_id;

    return requestPage(request);
  }

  inline bool apply(const HistoryResults &message) {
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

  [[nodiscard]] inline const HistoryRow<Memory> &entry(std::uint64_t id) const {
    if (state_.phase != HistoryPhase::ready) {
      throw EncodingError{"History results are not ready"};
    }

    const auto found = std::ranges::find(page_.rows(), id, &HistoryRow<Memory>::id);
    if (found == page_.rows().end()) {
      throw EncodingError{"The selected command is no longer available"};
    }

    return *found;
  }

  [[nodiscard]] inline std::string_view command(std::uint64_t id) const {
    const auto &row = entry(id);
    if (row.command_truncated) {
      throw EncodingError{"Command unavailable or capture truncated; cannot paste"};
    }

    if (row.command_complete) {
      return page_.command(row);
    }

    if (state_.command_id == id && state_.command_phase == HistoryPhase::ready) {
      return selected_command_;
    }

    throw EncodingError{"The selected command is not loaded; cannot paste"};
  }

  [[nodiscard]] inline bool canSubmit() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return false;
    }

    const auto &row = page_.rows()[state_.selection];

    return !row.command_truncated && (row.command_complete || (state_.command_id == row.id && state_.command_phase == HistoryPhase::ready));
  }

  [[nodiscard]] inline std::string_view selectedCommand() const {
    if (state_.selection >= page_.rows().size()) {
      return {};
    }

    const auto &row = page_.rows()[state_.selection];
    if (row.command_complete) {
      return page_.command(row);
    }

    return state_.command_id == row.id && state_.command_phase == HistoryPhase::ready ? std::string_view{selected_command_} : std::string_view{row.command};
  }

  [[nodiscard]] inline std::optional<QueryHistory> readCommand(std::uint64_t request_id) {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return {};
    }

    const auto &row = page_.rows()[state_.selection];
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

  inline bool select(std::size_t index) {
    if (state_.phase != HistoryPhase::ready || index >= page_.rows().size() || state_.selection == index) {
      return false;
    }

    state_.selection = index;
    const auto &selected = page_.rows()[index];
    if (!selected.command_complete && !selected.command_truncated && (state_.command_id != selected.id || state_.command_phase == HistoryPhase::failed)) {
      clearCommand();
    }

    error_.assign({});
    clearOutput();
    ++view_version_;

    return true;
  }

  inline void setInspecting(bool enabled) {
    if (state_.inspecting != enabled) {
      state_.inspecting = enabled;
      clearOutput();
      ++view_version_;
    }
  }

  [[nodiscard]] inline std::optional<ReadHistoryOutput> readOutput(std::uint64_t request_id) {
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

  inline bool apply(const HistoryOutput &message) {
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

  [[nodiscard]] inline DeleteHistory erase(std::uint64_t id, std::uint64_t request_id) {
    static_cast<void>(entry(id));
    if (delete_request_ != 0) {
      throw EncodingError{"A history deletion is already pending"};
    }

    track(request_id);
    delete_request_ = request_id;
    contentChanged();

    return {.request_id = request_id, .id = id};
  }

  inline bool apply(const HistoryPruned &message) {
    retire(message.request_id);
    if (message.request_id == 0 || message.request_id != delete_request_) {
      return false;
    }

    delete_request_ = 0;
    contentChanged();

    return true;
  }

  [[nodiscard]] inline bool owns(std::uint64_t request_id) const noexcept {
    return request_id != 0 && std::ranges::find(requests_, request_id) != requests_.end();
  }

  inline void setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  inline bool fail(std::uint64_t request_id, std::string_view message) {
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

  inline void suspend() noexcept {
    requests_.fill(0);
    page_request_ = 0;
    delete_request_ = 0;
    state_.phase = HistoryPhase::idle;
    clearCommand();
    clearOutput();
    contentChanged();
  }

  [[nodiscard]] inline const auto &rows() const noexcept {
    return page_.rows();
  }

  [[nodiscard]] inline const HistoryViewState &state() const noexcept {
    return state_;
  }

  [[nodiscard]] inline std::string_view output() const noexcept {
    return output_;
  }

  [[nodiscard]] inline std::string_view error() const noexcept {
    return error_.view();
  }

  [[nodiscard]] inline std::uint64_t viewVersion() const noexcept {
    return view_version_;
  }

  [[nodiscard]] inline std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] inline std::optional<HistoryChoice> choice() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return {};
    }

    return HistoryChoice{.index = state_.selection, .revision = revision_};
  }

  [[nodiscard]] inline bool acceptsRow(HistoryChoice candidate) const noexcept {
    return state_.phase == HistoryPhase::ready && candidate.revision == revision_ && candidate.index < page_.rows().size();
  }

  [[nodiscard]] inline bool accepts(HistoryChoice candidate) const noexcept {
    return acceptsRow(candidate) && candidate.index == state_.selection;
  }

  [[nodiscard]] inline std::uint64_t rowsVersion() const noexcept {
    return rows_version_;
  }

  [[nodiscard]] inline HistoryScope scope() const noexcept {
    return criteria_.scope;
  }

  [[nodiscard]] inline HistoryMatch match() const noexcept {
    return criteria_.match;
  }

  [[nodiscard]] inline bool deleting() const noexcept {
    return delete_request_ != 0;
  }

private:
  inline void contentChanged() noexcept {
    ++revision_;
    ++view_version_;
  }

  inline QueryHistory prepareQuery(QueryHistory query) {
    query.query = runtime::utf8Prefix(query.query, maximum_query_bytes);
    query.limit = page_entries;
    query.offset = 0;
    query.snapshot_id = 0;
    query.entry_id = 0;
    static_cast<void>(Codec::encodedSize(query));
    String<Memory> next_query{query.query, AllocatorRef<char, Memory>{memory_}};
    String<Memory> next_scope{AllocatorRef<char, Memory>{memory_}};
    if (const auto *path = std::get_if<std::string_view>(&query.scope_value)) {
      next_scope = *path;
    }

    query_ = std::move(next_query);
    scope_path_ = std::move(next_scope);
    criteria_ = query;
    criteria_.query = query_;
    if (std::holds_alternative<std::string_view>(criteria_.scope_value)) {
      criteria_.scope_value = std::string_view{scope_path_};
    }

    delete_request_ = 0;

    return requestPage(criteria_);
  }

  inline HistoryPageStorage<Memory> copyPage(std::span<const HistoryEntry> entries) {
    try {
      return HistoryPageStorage<Memory>{memory_, entries};
    } catch (...) {
      rejectQuery("Could not store history results");
      throw;
    }
  }

  inline bool applyCommand(std::span<const HistoryEntry> entries) {
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

  inline void rejectQuery(std::string_view message) {
    state_.phase = HistoryPhase::failed;
    page_request_ = 0;
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  inline QueryHistory requestPage(QueryHistory request) {
    track(request.request_id);
    page_request_ = request.request_id;
    pending_offset_ = request.offset;
    state_.phase = HistoryPhase::loading;
    error_.assign({});
    clearCommand();
    clearOutput();
    contentChanged();

    return request;
  }

  inline void track(std::uint64_t request_id) {
    auto *const slot = std::ranges::find(requests_, std::uint64_t{0});
    if (request_id == 0 || slot == requests_.end() || owns(request_id)) {
      state_.phase = HistoryPhase::failed;
      contentChanged();
      throw EncodingError{"History is busy; retry the search"};
    }

    *slot = request_id;
  }

  inline void retire(std::uint64_t request_id) noexcept {
    if (auto *const slot = std::ranges::find(requests_, request_id); request_id != 0 && slot != requests_.end()) {
      *slot = 0;
    }
  }

  inline void clearCommand() noexcept {
    command_request_ = 0;
    state_.command_id = 0;
    state_.command_phase = HistoryPhase::idle;
    selected_command_.clear();
  }

  inline void clearOutput() noexcept {
    output_request_ = 0;
    state_.output_id = 0;
    state_.output_phase = HistoryPhase::idle;
    state_.output_truncated = false;
    output_.clear();
  }

  Memory &memory_;
  HistoryPageStorage<Memory> page_;
  String<Memory> selected_command_;
  String<Memory> query_;
  String<Memory> scope_path_;
  String<Memory> output_;
  runtime::FixedText<maximum_error_bytes> error_;
  QueryHistory criteria_;
  HistoryViewState state_;
  std::array<std::uint64_t, maximum_requests> requests_{};
  std::uint64_t page_request_ = 0;
  std::uint64_t command_request_ = 0;
  std::uint64_t output_request_ = 0;
  std::uint64_t delete_request_ = 0;
  std::uint64_t revision_ = 0;
  std::uint64_t view_version_ = 0;
  std::uint64_t rows_version_ = 0;
  std::uint32_t pending_offset_ = 0;
};

}
}
