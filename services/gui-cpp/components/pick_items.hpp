#pragma once

#include "telar_base/text/utf8.hpp"
#include "telar_client/codecs/telar_value_codec.hpp"
#include "telar_client/serializers/telar_messages.hpp"
#include "telar_config/limit_notices.hpp"
#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <optional>
#include <stdexcept>
#include <string_view>

namespace telar::gui::components {

using PickSwatch = std::array<std::uint32_t, 3>;

struct PickInput {
  std::string_view label;
  std::string_view detail;
  std::optional<std::string_view> value = std::nullopt;
  std::optional<PickSwatch> swatch = std::nullopt;
  bool selected = false;
};

struct PickOption {
  std::string_view label;
  std::string_view value;
  std::string_view detail;
  std::optional<PickSwatch> swatch;
  bool selected;
};

class PickItems {
public:
  static constexpr std::size_t maximum_items = 4096;
  static constexpr std::size_t maximum_text_bytes = std::size_t{256} * 1024;
  static constexpr std::size_t maximum_label_bytes = 128;
  static constexpr std::size_t maximum_value_bytes = 512;
  static constexpr std::size_t maximum_detail_bytes = 128;

  void clear() noexcept {
    count_ = 0;
    used_ = 0;
    offered_ = {};
  }

  // A value remains one argv element; only labels and details may be shortened.
  void keep(const PickInput &input) {
    const auto value = input.value.value_or(input.label);
    offer(offered_.items, 1);
    for (const auto text : {input.label, value, input.detail}) {
      offer(offered_.text, text.size());
    }

    offered_.label = std::max(offered_.label, saturated(input.label.size()));
    offered_.value = std::max(offered_.value, saturated(value.size()));
    offered_.detail = std::max(offered_.detail, saturated(input.detail.size()));
    if (value.size() > maximum_value_bytes || count_ == maximum_items || offered_.text_full) {
      return;
    }

    const auto label = runtime::utf8Prefix(input.label, maximum_label_bytes);
    const auto detail = runtime::utf8Prefix(input.detail, maximum_detail_bytes);
    if (label.empty() || value.empty()) {
      throw std::invalid_argument{"A pick option needs a label and value"};
    }

    validate(label, false);
    validate(detail, false);
    validate(value, true);
    const auto shared = label == value;
    const auto needed = label.size() + detail.size() + (shared ? 0 : value.size());
    if (needed > maximum_text_bytes - used_) {
      offered_.text_full = true;
      return;
    }

    Row row;
    row.label = store(label);
    row.value = shared ? row.label : store(value);
    row.detail = store(detail);
    row.selected = input.selected;
    row.swatch = input.swatch;
    rows_[count_++] = row;
  }

  [[nodiscard]] std::size_t size() const noexcept {
    return count_;
  }

  [[nodiscard]] PickOption at(std::size_t index) const {
    if (index >= count_) {
      throw std::out_of_range{"Pick option is no longer available"};
    }

    const auto &row = rows_[index];

    return {.label = text(row.label), .value = text(row.value), .detail = text(row.detail), .swatch = row.swatch, .selected = row.selected};
  }

  void report(runtime::config::LimitNotices &limits) const noexcept {
    const auto reaches = std::to_array<LimitReach>({
        {.name = "picks.max_items", .noun = "options", .value = maximum_items, .requested = offered_.items, .route = {}},
        {.name = "picks.max_text_bytes", .noun = "option text bytes", .value = maximum_text_bytes, .requested = offered_.text_full ? std::optional<std::size_t>{offered_.text} : std::nullopt, .route = {}},
        {.name = "picks.max_label_bytes", .noun = "label bytes", .value = maximum_label_bytes, .requested = offered_.label, .route = {}},
        {.name = "picks.max_value_bytes", .noun = "value bytes", .value = maximum_value_bytes, .requested = offered_.value, .route = {}},
        {.name = "picks.max_detail_bytes", .noun = "detail bytes", .value = maximum_detail_bytes, .requested = offered_.detail, .route = {}},
    });
    for (const auto &reach : reaches) {
      if (reach.requested.value_or(0) > reach.value) {
        limits.add(reach);
      }
    }
  }

private:
  struct Range {
    std::uint32_t offset = 0;
    std::uint16_t length = 0;
  };

  struct Row {
    Range label;
    Range value;
    Range detail;
    std::optional<PickSwatch> swatch = std::nullopt;
    bool selected = false;
  };

  struct Offered {
    std::uint32_t items = 0;
    std::uint32_t text = 0;
    std::uint32_t label = 0;
    std::uint32_t value = 0;
    std::uint32_t detail = 0;
    bool text_full = false;
  };

  static std::uint32_t saturated(std::size_t value) noexcept {
    return static_cast<std::uint32_t>(std::min<std::size_t>(value, std::numeric_limits<std::uint32_t>::max()));
  }

  static void offer(std::uint32_t &total, std::size_t value) noexcept {
    total += std::min(saturated(value), std::numeric_limits<std::uint32_t>::max() - total);
  }

  static void validate(std::string_view text, bool tabs) {
    validateUtf8(text);
    constexpr unsigned first_printable = 0x20;
    constexpr unsigned delete_control = 0x7f;
    if (std::ranges::any_of(text, [tabs](unsigned char byte) {
          return (byte < first_printable || byte == delete_control) && (!tabs || byte != '\t');
        })) {
      throw std::invalid_argument{"Pick options must contain printable single-line text"};
    }
  }

  Range store(std::string_view value) noexcept {
    const Range range{.offset = static_cast<std::uint32_t>(used_), .length = static_cast<std::uint16_t>(value.size())};
    std::ranges::copy(value, bytes_.begin() + static_cast<std::ptrdiff_t>(used_));
    used_ += value.size();

    return range;
  }

  [[nodiscard]] std::string_view text(Range range) const noexcept {
    return {bytes_.data() + range.offset, range.length};
  }

  std::array<char, maximum_text_bytes> bytes_{};
  std::array<Row, maximum_items> rows_{};
  std::size_t count_ = 0;
  std::size_t used_ = 0;
  Offered offered_;
};

}
