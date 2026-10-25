#pragma once

#include "limit_notices.hpp"
#include <cstring>

namespace telar::runtime::config {

class CommandTabRegistry {
public:
  CommandTabRegistry() noexcept {}

  struct Checkpoint {
    std::size_t rows;
    std::size_t bytes;
  };

  bool keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
    std::array<Byte, maximum_encoded_bytes> encoded;
    std::size_t length = 0;
    encoded[length++] = static_cast<Byte>(arguments.size());
    encoded[length++] = static_cast<Byte>(label.size());
    for (const auto argument : arguments) {
      encoded[length++] = static_cast<Byte>(argument.size());
      encoded[length++] = static_cast<Byte>(argument.size() >> 8);
    }
    for (const auto argument : arguments) {
      std::memcpy(encoded.data() + length, argument.data(), argument.size());
      length += argument.size();
    }
    if (!label.empty()) {
      std::memcpy(encoded.data() + length, label.data(), label.size());
    }
    length += label.size();

    for (std::size_t index = 0; index < rows_; ++index) {
      const auto start = offsets_[index];
      const auto end = index + 1 == rows_ ? used_ : offsets_[index + 1];
      if (end - start == length && std::memcmp(bytes_.data() + start, encoded.data(), length) == 0) {
        return true;
      }
    }
    if (rows_ == maximum_rows) {
      limits.add({"config.command_tab_rows", "command tabs", maximum_rows, {}, {}});
      return false;
    }
    if (used_ + length > bytes_.size()) {
      limits.add({"config.command_tab_bytes", "command tab bytes", bytes_.size(), {}, {}});
      return false;
    }

    offsets_[rows_++] = used_;
    std::copy_n(encoded.begin(), length, bytes_.begin() + used_);
    used_ += length;
    return true;
  }

  Checkpoint checkpoint() const noexcept {
    return {rows_, used_};
  }

  void restore(Checkpoint saved) noexcept {
    rows_ = saved.rows;
    used_ = saved.bytes;
  }

private:
  static constexpr std::size_t maximum_rows = 768;
  static constexpr std::size_t maximum_bytes = 80 * 1024;
  static constexpr std::size_t maximum_encoded_bytes = 2 + 2 * 32 + 4096 + 32;

  std::array<Byte, maximum_bytes> bytes_;
  std::array<std::size_t, maximum_rows> offsets_;
  std::size_t rows_ = 0;
  std::size_t used_ = 0;
};

}
