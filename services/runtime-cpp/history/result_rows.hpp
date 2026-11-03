#pragma once

#include "database.hpp"
#include "telar_base/memory/byte_queue.hpp"

namespace telar::runtime {

template <Allocator Memory>
class HistoryRows {
public:
  explicit HistoryRows(Memory &memory)
      : text_(memory, max_payload_size),
        entries_(AllocatorRef<HistoryEntry, Memory>{memory}) {
    text_.reserve(max_payload_size);
    entries_.reserve(maximum_entries);
    clear();
  }

  void clear() noexcept {
    text_.clear();
    entries_.clear();
    encoded_bytes_ = result_header_bytes;
  }

  bool append(const Statement &row) {
    auto entry = view(row);
    const auto bytes = ValueCodec<HistoryEntry>::encodedSize(entry);
    if (entries_.size() == maximum_entries || bytes > max_payload_size - encoded_bytes_) {
      return false;
    }

    entry.command = copy(entry.command);
    entry.cwd = copy(entry.cwd);
    entry.workspace_path = copy(entry.workspace_path);
    entry.provider = copy(entry.provider);
    entries_.push_back(entry);
    encoded_bytes_ += bytes;
    return true;
  }

  std::string_view copy(std::string_view text) {
    const auto offset = text_.size();
    text_.append(std::span{reinterpret_cast<const Byte *>(text.data()), text.size()});
    return {reinterpret_cast<const char *>(text_.readable().data() + offset), text.size()};
  }

  std::span<const HistoryEntry> entries() const noexcept {
    return entries_;
  }

private:
  static HistoryEntry view(const Statement &row) {
    if (row.integer(0) <= 0 || row.integer(1) <= 0) {
      throw RequestError{FailureCode::internal, "Invalid stored history identity"};
    }

    if (row.integer(5) < 0 || row.integer(5) > static_cast<std::int64_t>(HistoryStatus::running) || row.integer(9) < 0 || row.integer(9) > static_cast<std::int64_t>(HistoryAuthor::agent) || row.integer(10) < 0 || row.integer(10) > static_cast<std::int64_t>(HistoryOrigin::plugin)) {
      throw RequestError{FailureCode::internal, "Invalid stored history state"};
    }

    return HistoryEntry{
        .id = static_cast<std::uint64_t>(row.integer(0)),
        .pane_id = static_cast<std::uint64_t>(row.integer(1)),
        .started_at_ms = row.integer(2),
        .duration_ns = row.integer(3),
        .exit_code = row.isNull(4) ? std::nullopt : std::optional{static_cast<std::int32_t>(row.integer(4))},
        .status = static_cast<HistoryStatus>(row.integer(5)),
        .author = static_cast<HistoryAuthor>(row.integer(9)),
        .origin = static_cast<HistoryOrigin>(row.integer(10)),
        .provider = row.text(11),
        .command = row.text(6),
        .cwd = row.text(7),
        .workspace_path = row.text(8),
        .command_truncated = row.integer(12) != 0,
    };
  }

  static constexpr std::size_t maximum_entries = 1000;
  static constexpr std::size_t result_header_bytes = sizeof(Byte) + sizeof(std::uint64_t) * 2 + sizeof(std::uint16_t) + sizeof(Byte);
  ByteQueue<Memory> text_;
  Vector<HistoryEntry, Memory> entries_;
  std::size_t encoded_bytes_ = result_header_bytes;
};

}
