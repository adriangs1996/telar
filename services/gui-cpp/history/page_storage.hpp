#pragma once

#include "core/memory.hpp"
#include "entry.hpp"
#include "telar_client/codecs/telar_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "text/utf8.hpp"
#include <algorithm>
#include <cstddef>
#include <span>
#include <stdexcept>
#include <string_view>

namespace telar::gui {

template <Allocator Memory>
class HistoryPageStorage {
public:
  static constexpr std::size_t maximum_entries = 100;
  static constexpr std::size_t command_preview_bytes = 512;
  static constexpr std::size_t command_cache_bytes = std::size_t{768} * 1024;

  explicit HistoryPageStorage(Memory &memory, std::span<const HistoryEntry> entries = {})
      : rows_(AllocatorRef<HistoryRow<Memory>, Memory>{memory}),
        commands_(AllocatorRef<char, Memory>{memory}) {
    entries = entries.first(std::min(entries.size(), maximum_entries));
    rows_.reserve(entries.size());
    commands_.reserve(commandBytes(entries));
    for (const auto &entry : entries) {
      append(memory, entry);
    }
  }

  void exchangeWith(HistoryPageStorage &other) {
    if (rows_.get_allocator() != other.rows_.get_allocator()) {
      throw std::invalid_argument{"History pages must share an allocator"};
    }

    rows_.swap(other.rows_);
    commands_.swap(other.commands_);
  }

  [[nodiscard]] const auto &rows() const noexcept {
    return rows_;
  }

  [[nodiscard]] std::string_view command(const HistoryRow<Memory> &row) const {
    if (!row.command_complete) {
      return {};
    }

    if (row.full_length == 0) {
      return row.command;
    }

    return std::string_view{commands_}.substr(row.full_offset, row.full_length);
  }

private:
  static std::size_t commandBytes(std::span<const HistoryEntry> entries) {
    std::size_t bytes = 0;
    for (const auto &entry : entries) {
      static_cast<void>(ValueCodec<HistoryEntry>::encodedSize(entry));
      if (entry.command.size() > command_preview_bytes && entry.command.size() <= command_cache_bytes - bytes) {
        bytes += entry.command.size();
      }
    }

    return bytes;
  }

  void append(Memory &memory, const HistoryEntry &entry) {
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
