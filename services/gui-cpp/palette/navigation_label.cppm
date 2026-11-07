module;
#include <exception>
#include <memory>
#include <type_traits>
#include <cstdio>
#include <limits>
#include <string>
#include <vector>

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <charconv>
#include <concepts>
#include <cstring>
#include <system_error>
#include <algorithm>

#include <variant>

#include <span>
#include <utility>

export module telar.gui.palette.navigation_label;

export import telar.gui.core.unicode_scalar;
export import telar.gui.text.json_unsigned_integer;


export import telar.base.history;
import telar.base.diagnostics;
import telar.client.protocol;

// Interface: palette/navigation_label.cppm
export {
namespace telar::gui {

class NavigationLabel {
public:
  static constexpr std::size_t capacity = 160;
  static constexpr std::string_view detail_separator = "  ";
  static constexpr std::string_view tab_prefix = "tab ";

  inline void append(std::string_view text) {
    const auto available = capacity - text_.view().size();
    text_.append(text.substr(0, std::min(available, text.size())));
  }

  inline void appendDetail(std::string_view detail) {
    if (!detail.empty()) {
      append(detail_separator);
      append(detail);
    }
  }

  [[nodiscard]] inline std::string_view view() const noexcept {
    auto text = text_.view();
    if (text.size() != capacity) {
      return text;
    }

    auto boundary = text.size();
    constexpr unsigned leading_mask = ~Utf8Scalar::continuation_mask;
    while (boundary != 0 && (static_cast<unsigned char>(text[boundary - 1]) & leading_mask) == Utf8Scalar::continuation_prefix) {
      --boundary;
    }

    if (boundary == 0) {
      return text;
    }

    const auto last_start = boundary - 1;
    const auto sequence = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text[last_start]));
    const auto complete = sequence <= Utf8Scalar::leading_masks.size() && text.size() - last_start >= sequence;

    if (!complete) {
      text.remove_suffix(text.size() - last_start);
    }

    return text;
  }

private:
  BoundedText<capacity> text_;
};

}
}

// Interface: palette/navigation_target.cppm
export {
namespace telar::gui {

struct AgentNavigationTarget {
  std::uint64_t pane_id = 0;
  std::uint64_t pane_generation = 0;

  bool operator==(const AgentNavigationTarget &) const = default;
};

using NavigationTarget = std::variant<WorkspaceLocation, TabLocation, AgentNavigationTarget>;

}
}

// Interface: palette/query.cppm
export {
namespace telar::gui {

enum class PaletteMode : std::uint8_t {
  actions = '>',
  navigate = '@',
  suggest = '?',
  machines = ':',
};

struct PaletteQuery {
  static constexpr std::size_t maximum_bytes = 512;

  PaletteMode mode = PaletteMode::navigate;
  std::string_view text;

  [[nodiscard]] static constexpr std::optional<PaletteMode> prefix(char byte) noexcept {
    switch (byte) {
    case static_cast<char>(PaletteMode::actions):
      return PaletteMode::actions;
    case static_cast<char>(PaletteMode::navigate):
      return PaletteMode::navigate;
    case static_cast<char>(PaletteMode::suggest):
      return PaletteMode::suggest;
    case static_cast<char>(PaletteMode::machines):
      return PaletteMode::machines;
    default:
      return std::nullopt;
    }
  }

  [[nodiscard]] static constexpr PaletteQuery parse(std::string_view prompt) noexcept {
    if (!prompt.empty()) {
      if (const auto mode = prefix(prompt.front())) {
        prompt.remove_prefix(1);

        return {.mode = *mode, .text = prompt};
      }
    }

    return {.text = prompt};
  }
};

}
}

// Interface: palette/ranked_matches.cppm
export {
namespace telar::gui {

template <std::semiregular Target, std::size_t Capacity>
class RankedMatches {
  static_assert(Capacity > 0);

public:
  struct Match {
    Target target{};
    std::uint32_t score = 0;
  };

  inline void clear() noexcept {
    length_ = 0;
  }

  inline void add(Target target, std::string_view label, std::string_view query) {
    const auto score = runtime::historyScore(label, query);
    if (!score) {
      return;
    }

    addScored(std::move(target), *score);
  }

  inline void addScored(Target target, std::uint32_t score) {
    auto position = length_;
    while (position != 0 && matches_[position - 1].score < score) {
      --position;
    }

    if (position == Capacity) {
      return;
    }

    auto tail = std::min(length_, Capacity - 1);
    while (tail > position) {
      matches_[tail] = std::move(matches_[tail - 1]);
      --tail;
    }

    matches_[position] = {.target = std::move(target), .score = score};
    length_ = std::min(length_ + 1, Capacity);
  }

  [[nodiscard]] inline std::span<const Match> rows() const noexcept {
    return std::span{matches_}.first(length_);
  }

private:
  std::array<Match, Capacity> matches_{};
  std::size_t length_ = 0;
};

}
}
