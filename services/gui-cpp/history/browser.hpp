#pragma once

#include "choice.hpp"
#include "entry.hpp"
#include "page_storage.hpp"
#include "plain_text.hpp"
#include "search.hpp"
#include "telar_base/memory/fixed_text.hpp"
#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <span>
#include <string_view>
#include <utility>
#include <variant>

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

  explicit HistoryBrowser(Memory &memory)
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

  [[nodiscard]] QueryHistory begin(QueryHistory query) {
    try {
      return prepareQuery(query);
    } catch (...) {
      rejectQuery("Could not start history search");
      throw;
    }
  }

  [[nodiscard]] QueryHistory refresh(std::uint64_t request_id) {
    auto request = criteria_;
    request.request_id = request_id;

    return requestPage(request);
  }

  [[nodiscard]] bool canPage(HistoryPage direction) const noexcept {
    if (state_.phase != HistoryPhase::ready || page_.rows().empty()) {
      return false;
    }

    return direction == HistoryPage::older ? state_.has_more : state_.page_offset != 0;
  }

  [[nodiscard]] std::optional<QueryHistory> page(HistoryPage direction, std::uint64_t request_id) {
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

  bool apply(const HistoryResults &message) {
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

  [[nodiscard]] const HistoryRow<Memory> &entry(std::uint64_t id) const {
    if (state_.phase != HistoryPhase::ready) {
      throw EncodingError{"History results are not ready"};
    }

    const auto found = std::ranges::find(page_.rows(), id, &HistoryRow<Memory>::id);
    if (found == page_.rows().end()) {
      throw EncodingError{"The selected command is no longer available"};
    }

    return *found;
  }

  [[nodiscard]] std::string_view command(std::uint64_t id) const {
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

  [[nodiscard]] bool canSubmit() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return false;
    }

    const auto &row = page_.rows()[state_.selection];

    return !row.command_truncated && (row.command_complete || (state_.command_id == row.id && state_.command_phase == HistoryPhase::ready));
  }

  [[nodiscard]] std::string_view selectedCommand() const {
    if (state_.selection >= page_.rows().size()) {
      return {};
    }

    const auto &row = page_.rows()[state_.selection];
    if (row.command_complete) {
      return page_.command(row);
    }

    return state_.command_id == row.id && state_.command_phase == HistoryPhase::ready ? std::string_view{selected_command_} : std::string_view{row.command};
  }

  [[nodiscard]] std::optional<QueryHistory> readCommand(std::uint64_t request_id) {
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

  bool select(std::size_t index) {
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

  void setInspecting(bool enabled) {
    if (state_.inspecting != enabled) {
      state_.inspecting = enabled;
      clearOutput();
      ++view_version_;
    }
  }

  [[nodiscard]] std::optional<ReadHistoryOutput> readOutput(std::uint64_t request_id) {
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

  bool apply(const HistoryOutput &message) {
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

  [[nodiscard]] DeleteHistory erase(std::uint64_t id, std::uint64_t request_id) {
    static_cast<void>(entry(id));
    if (delete_request_ != 0) {
      throw EncodingError{"A history deletion is already pending"};
    }

    track(request_id);
    delete_request_ = request_id;
    contentChanged();

    return {.request_id = request_id, .id = id};
  }

  bool apply(const HistoryPruned &message) {
    retire(message.request_id);
    if (message.request_id == 0 || message.request_id != delete_request_) {
      return false;
    }

    delete_request_ = 0;
    contentChanged();

    return true;
  }

  [[nodiscard]] bool owns(std::uint64_t request_id) const noexcept {
    return request_id != 0 && std::ranges::find(requests_, request_id) != requests_.end();
  }

  void setError(std::string_view message) {
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  bool fail(std::uint64_t request_id, std::string_view message) {
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

  void suspend() noexcept {
    requests_.fill(0);
    page_request_ = 0;
    delete_request_ = 0;
    state_.phase = HistoryPhase::idle;
    clearCommand();
    clearOutput();
    contentChanged();
  }

  [[nodiscard]] const auto &rows() const noexcept {
    return page_.rows();
  }

  [[nodiscard]] const HistoryViewState &state() const noexcept {
    return state_;
  }

  [[nodiscard]] std::string_view output() const noexcept {
    return output_;
  }

  [[nodiscard]] std::string_view error() const noexcept {
    return error_.view();
  }

  [[nodiscard]] std::uint64_t viewVersion() const noexcept {
    return view_version_;
  }

  [[nodiscard]] std::uint64_t revision() const noexcept {
    return revision_;
  }

  [[nodiscard]] std::optional<HistoryChoice> choice() const noexcept {
    if (state_.phase != HistoryPhase::ready || state_.selection >= page_.rows().size()) {
      return {};
    }

    return HistoryChoice{.index = state_.selection, .revision = revision_};
  }

  [[nodiscard]] bool acceptsRow(HistoryChoice candidate) const noexcept {
    return state_.phase == HistoryPhase::ready && candidate.revision == revision_ && candidate.index < page_.rows().size();
  }

  [[nodiscard]] bool accepts(HistoryChoice candidate) const noexcept {
    return acceptsRow(candidate) && candidate.index == state_.selection;
  }

  [[nodiscard]] std::uint64_t rowsVersion() const noexcept {
    return rows_version_;
  }

  [[nodiscard]] HistoryScope scope() const noexcept {
    return criteria_.scope;
  }

  [[nodiscard]] HistoryMatch match() const noexcept {
    return criteria_.match;
  }

  [[nodiscard]] bool deleting() const noexcept {
    return delete_request_ != 0;
  }

private:
  void contentChanged() noexcept {
    ++revision_;
    ++view_version_;
  }

  QueryHistory prepareQuery(QueryHistory query) {
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

  HistoryPageStorage<Memory> copyPage(std::span<const HistoryEntry> entries) {
    try {
      return HistoryPageStorage<Memory>{memory_, entries};
    } catch (...) {
      rejectQuery("Could not store history results");
      throw;
    }
  }

  bool applyCommand(std::span<const HistoryEntry> entries) {
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

  void rejectQuery(std::string_view message) {
    state_.phase = HistoryPhase::failed;
    page_request_ = 0;
    error_.assign(runtime::utf8Prefix(message, maximum_error_bytes));
    contentChanged();
  }

  QueryHistory requestPage(QueryHistory request) {
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

  void track(std::uint64_t request_id) {
    auto *const slot = std::ranges::find(requests_, std::uint64_t{0});
    if (request_id == 0 || slot == requests_.end() || owns(request_id)) {
      state_.phase = HistoryPhase::failed;
      contentChanged();
      throw EncodingError{"History is busy; retry the search"};
    }

    *slot = request_id;
  }

  void retire(std::uint64_t request_id) noexcept {
    if (auto *const slot = std::ranges::find(requests_, request_id); request_id != 0 && slot != requests_.end()) {
      *slot = 0;
    }
  }

  void clearCommand() noexcept {
    command_request_ = 0;
    state_.command_id = 0;
    state_.command_phase = HistoryPhase::idle;
    selected_command_.clear();
  }

  void clearOutput() noexcept {
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
