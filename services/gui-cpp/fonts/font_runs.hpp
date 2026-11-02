#pragma once

#include "font_role.hpp"
#include "text/grapheme_cursor.hpp"
#include <concepts>
#include <cstdint>
#include <optional>
#include <string_view>

namespace telar::gui::fonts {

template <typename Fonts>
concept CascadingFontProvider = FontProvider<Fonts> && requires(Fonts &fonts, std::string_view text, FontRole role) {
  { fonts.source(text, role) } -> std::same_as<std::optional<FontRole>>;
};

struct FontSpan {
  std::string_view text;
  std::optional<FontRole> role = std::nullopt;
  std::uint32_t columns = 0;
};

template <CascadingFontProvider Fonts>
class FontRuns {
public:
  FontRuns(Fonts &fonts, std::string_view text, FontRole preferred) noexcept
      : fonts_(fonts),
        text_(text),
        cursor_(text),
        preferred_(preferred) {}

  [[nodiscard]] std::optional<FontSpan> next() {
    const auto start = cursor_.position();
    const auto cluster = cursor_.next();
    if (!cluster) {
      return std::nullopt;
    }

    auto role = fonts_.source(*cluster, preferred_);
    const auto resolved = role.value_or(FontRole::primary);
    std::uint32_t columns = cursor_.columns();
    if (resolved == preferred_) {
      while (cursor_.position() < text_.size()) {
        auto candidate = cursor_;
        const auto following = candidate.next();
        if (!following) {
          break;
        }

        const auto following_role = fonts_.source(*following, preferred_);
        if (following_role.value_or(FontRole::primary) != resolved) {
          break;
        }

        if (!following_role) {
          role.reset();
        }

        cursor_ = candidate;
        columns += cursor_.columns();
      }
    }

    return FontSpan{.text = text_.substr(start, cursor_.position() - start), .role = role, .columns = columns};
  }

private:
  Fonts &fonts_;
  std::string_view text_;
  GraphemeCursor cursor_;
  FontRole preferred_;
};

}
