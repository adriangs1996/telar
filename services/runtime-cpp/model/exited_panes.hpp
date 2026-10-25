#pragma once

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>

namespace telar::runtime {

class ExitedPanes {
public:
  static constexpr std::size_t capacity = 16;
  static constexpr std::size_t maximum_bytes = 16 * 1024;
  static constexpr std::uint16_t kept_rows = 200;

  struct Record {
    std::uint64_t pane_id = 0;
    std::uint64_t generation = 0;
    std::int32_t exit_code = 0;
    std::array<char, maximum_bytes> bytes{};
    std::size_t length = 0;
    bool truncated = false;

    PaneText response(const ReadPane &request) const noexcept {
      std::string_view text{bytes.data(), length};
      const auto last = text.find_last_not_of("\n ");
      text = last == std::string_view::npos ? std::string_view{} : text.substr(0, last + 1);
      auto start = text.size();
      unsigned lines = 0;

      while (start != 0) {
        if (text[start - 1] == '\n' && ++lines == request.rows) {
          break;
        }
        --start;
      }

      return PaneText{.request_id = request.request_id,
                      .pane_id = pane_id,
                      .truncated = start == 0 && truncated,
                      .text = text.substr(start),
                      .exit_code = exit_code};
    }
  };

  void record(std::uint64_t pane_id, std::uint64_t generation, const PaneText &text) noexcept {
    auto &entry = entries_[next_];
    entry.pane_id = pane_id;
    entry.generation = generation;
    entry.exit_code = text.exit_code.value_or(0);
    entry.length = std::min(text.text.size(), maximum_bytes);
    entry.truncated = text.truncated || entry.length != text.text.size();
    std::copy_n(text.text.end() - entry.length, entry.length, entry.bytes.begin());
    next_ = (next_ + 1) % capacity;
  }

  const Record *find(std::uint64_t pane_id, std::uint64_t generation) const noexcept {
    for (std::size_t offset = 0; offset < capacity; ++offset) {
      const auto &entry = entries_[(next_ + capacity - 1 - offset) % capacity];
      if (pane_id != 0 && entry.pane_id == pane_id && (generation == 0 || entry.generation == generation)) {
        return &entry;
      }
    }
    return nullptr;
  }

private:
  std::array<Record, capacity> entries_{};
  std::size_t next_ = 0;
};

}
