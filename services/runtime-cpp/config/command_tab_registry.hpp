#pragma once

#include "command_tab_reference.hpp"
#include "command_tab_view.hpp"
#include "limit_notices.hpp"
#include <algorithm>
#include <array>
#include <concepts>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <optional>
#include <span>
#include <string_view>

namespace telar::runtime::config {

enum class CommandTabLifetime : std::uint8_t {
  configuration,
  retained,
};

template <CommandTabLifetime Lifetime>
class CommandTabStorage {
public:
  CommandTabStorage() noexcept = default;

  struct Checkpoint {
    std::size_t rows;
    std::size_t bytes;
  };

  bool keep(std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
    return keepReference(arguments, label, limits).has_value();
  }

  std::optional<CommandTabReference> keepReference(std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
    std::array<Byte, maximum_encoded_bytes> encoded{};
    const auto length = encode(arguments, label, encoded);
    const auto row = std::span{encoded}.first(length);
    for (std::size_t index = 0; index < rows_; ++index) {
      const auto stored = rowBytes(index);
      if (stored.size() == row.size() && std::ranges::equal(stored, row)) {
        return reference(index);
      }
    }

    if (!admit(row.size(), limits)) {
      return std::nullopt;
    }

    const auto index = rows_++;
    offsets_[index] = static_cast<std::uint32_t>(used_);
    std::ranges::copy(row, bytes_.begin() + used_);
    used_ += row.size();

    return reference(index);
  }

  [[nodiscard]] std::optional<CommandTabView> load(CommandTabReference reference) const {
    if (reference.id >= rows_ || reference != this->reference(reference.id)) {
      return std::nullopt;
    }

    const auto row = rowBytes(reference.id);
    CommandTabView result;
    result.count = row[0];
    const auto label_length = row[1];
    auto offset = header_bytes + (result.count * argument_length_bytes);
    for (std::size_t argument = 0; argument < result.count; ++argument) {
      const auto entry = header_bytes + (argument * argument_length_bytes);
      const auto length = static_cast<std::size_t>(row[entry]) | (static_cast<std::size_t>(row[entry + 1]) << upper_byte_shift);
      result.arguments[argument] = textView(row.subspan(offset, length));
      offset += length;
    }

    result.configured_label = textView(row.subspan(offset, label_length));

    return result;
  }

  void seal() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    sealed_ = true;
    fixed_rows_ = rows_;
    fixed_bytes_ = used_;
  }

  void beginRender() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    if (!sealed_) {
      return;
    }

    const bool crowded = maximum_bytes - used_ < recent_bytes / 2 || maximum_rows - rows_ < recent_rows / 2;
    if (refused_ || crowded) {
      clearRecent();
    }

    refused_ = false;
    rendering_ = true;
  }

  void endRender() noexcept
    requires(Lifetime == CommandTabLifetime::retained)
  {
    rendering_ = false;
  }

  [[nodiscard]] Checkpoint checkpoint() const noexcept {
    return {.rows = rows_, .bytes = used_};
  }

  void restore(Checkpoint saved) noexcept {
    rows_ = saved.rows;
    used_ = saved.bytes;
  }

private:
  static constexpr std::size_t recent_rows = 256;
  static constexpr std::size_t fixed_row_limit = 768;
  static constexpr std::size_t recent_bytes = std::size_t{64} * 1024;
  static constexpr std::size_t fixed_byte_limit = std::size_t{80} * 1024;
  static constexpr std::size_t maximum_rows = fixed_row_limit + (Lifetime == CommandTabLifetime::retained ? recent_rows : 0);
  static constexpr std::size_t maximum_bytes = fixed_byte_limit + (Lifetime == CommandTabLifetime::retained ? recent_bytes : 0);
  static constexpr std::size_t header_bytes = 2;
  static constexpr std::size_t argument_length_bytes = sizeof(std::uint16_t);
  static constexpr unsigned upper_byte_shift = std::numeric_limits<Byte>::digits;
  static constexpr std::size_t maximum_encoded_bytes = header_bytes + (argument_length_bytes * CommandTabView::maximum_arguments) + CommandTabView::maximum_argument_bytes + CommandTabView::maximum_label_bytes;

  static_assert(maximum_encoded_bytes <= recent_bytes);
  static_assert(maximum_bytes <= std::numeric_limits<std::uint32_t>::max());
  static_assert(maximum_rows - 1 <= std::numeric_limits<std::uint16_t>::max());

  static std::size_t encode(std::span<const std::string_view> arguments, std::string_view label, std::span<Byte> encoded) {
    if (arguments.empty() || arguments.size() > CommandTabView::maximum_arguments || label.size() > CommandTabView::maximum_label_bytes) {
      throw EncodingError{"Invalid command tab bounds"};
    }

    std::size_t argument_bytes = 0;
    for (const auto argument : arguments) {
      if (argument.empty() || argument.size() > CommandTabView::maximum_argument_bytes - argument_bytes || argument.contains('\0')) {
        throw EncodingError{"Invalid command tab argument"};
      }

      argument_bytes += argument.size();
    }

    std::size_t length = 0;
    encoded[length++] = static_cast<Byte>(arguments.size());
    encoded[length++] = static_cast<Byte>(label.size());
    for (const auto argument : arguments) {
      encoded[length++] = static_cast<Byte>(argument.size());
      encoded[length++] = static_cast<Byte>(argument.size() >> upper_byte_shift);
    }

    for (const auto argument : arguments) {
      std::memcpy(encoded.data() + length, argument.data(), argument.size());
      length += argument.size();
    }

    if (!label.empty()) {
      std::memcpy(encoded.data() + length, label.data(), label.size());
    }

    return length + label.size();
  }

  bool admit(std::size_t length, LimitNotices &limits) noexcept {
    if (Lifetime == CommandTabLifetime::configuration || !sealed_) {
      if (rows_ >= fixed_row_limit) {
        limits.add({.name = "config.command_tab_rows", .noun = "command tabs", .value = fixed_row_limit});

        return false;
      }

      if (used_ + length > fixed_byte_limit) {
        limits.add({.name = "config.command_tab_bytes", .noun = "command tab bytes", .value = fixed_byte_limit});

        return false;
      }
    } else if (used_ + length > maximum_bytes || rows_ == maximum_rows) {
      if (rendering_) {
        refused_ = true;
        limits.add({.name = "config.recent_command_tab_bytes", .noun = "command tab bytes", .value = recent_bytes});

        return false;
      }

      clearRecent();
    }

    return true;
  }

  [[nodiscard]] CommandTabReference reference(std::size_t index) const noexcept {
    return {.epoch = Lifetime == CommandTabLifetime::retained && sealed_ && index >= fixed_rows_ ? epoch_ : 0, .id = static_cast<std::uint16_t>(index)};
  }

  [[nodiscard]] std::span<const Byte> rowBytes(std::size_t index) const noexcept {
    const auto start = offsets_[index];
    const auto end = index + 1 == rows_ ? used_ : offsets_[index + 1];

    return std::span{bytes_}.subspan(start, end - start);
  }

  void clearRecent() noexcept {
    rows_ = fixed_rows_;
    used_ = fixed_bytes_;
    if (++epoch_ == 0) {
      ++epoch_;
    }
  }

  std::array<Byte, maximum_bytes> bytes_{};
  std::array<std::uint32_t, maximum_rows> offsets_{};
  std::size_t rows_ = 0;
  std::size_t used_ = 0;
  std::size_t fixed_rows_ = 0;
  std::size_t fixed_bytes_ = 0;
  std::uint32_t epoch_ = 1;
  bool sealed_ = false;
  bool rendering_ = false;
  bool refused_ = false;
};

using CommandTabRegistry = CommandTabStorage<CommandTabLifetime::configuration>;
using RetainedCommandTabRegistry = CommandTabStorage<CommandTabLifetime::retained>;

template <typename Store>
concept CommandTabStore = requires(Store &store, std::span<const std::string_view> arguments, std::string_view label, LimitNotices &limits) {
  { store.keep(arguments, label, limits) } -> std::same_as<bool>;
  { store.restore(store.checkpoint()) } noexcept -> std::same_as<void>;
};

}
