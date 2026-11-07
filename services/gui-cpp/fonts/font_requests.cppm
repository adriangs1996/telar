module;
#include <exception>
#include <cstdio>
#include <string>
#include <variant>
#include <vector>

#include <array>
#include <bit>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string_view>
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <algorithm>
#include <cstring>
#include <chrono>
#include <cmath>
#include <limits>
#include <type_traits>

#include <concepts>
#include <utility>

#include <functional>

export module telar.gui.fonts.font_requests;

export import telar.gui.core.unicode_scalar;
export import telar.gui.fonts.face;


export import telar.gui.core.json_writer;
import telar.base.diagnostics;
import telar.base.memory;
import telar.client.protocol;

// Interface: fonts/font_coverage.cppm
export {
namespace telar::gui::fonts {

struct FontCoverage {
  [[nodiscard]] inline static bool covers(const Face &face, std::string_view text) {
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontCoverageUtf8"};
      }

      const auto codepoint = Utf8Scalar::decode(text.substr(0, length));
      if (!isSelectorOrJoiner(codepoint) && !face.covers(static_cast<char32_t>(codepoint))) {
        return false;
      }

      text.remove_prefix(length);
    }

    return true;
  }

  [[nodiscard]] inline static bool isSelectorOrJoiner(std::uint32_t codepoint) noexcept {
    constexpr std::uint32_t non_joiner = 0x200c;
    constexpr std::uint32_t joiner = 0x200d;
    constexpr std::uint32_t first_selector = 0xfe00;
    constexpr std::uint32_t last_selector = 0xfe0f;
    constexpr std::uint32_t first_extended_selector = 0xe0100;
    constexpr std::uint32_t last_extended_selector = 0xe01ef;

    return codepoint == non_joiner || codepoint == joiner || (codepoint >= first_selector && codepoint <= last_selector) || (codepoint >= first_extended_selector && codepoint <= last_extended_selector);
  }
};

}
}

// Interface: fonts/font_cascade.cppm
export {
namespace telar::gui::fonts {

struct FontCascade {
  template <FontProvider Fonts>
  [[nodiscard]] inline static std::optional<FontRole> source(Fonts &fonts, std::string_view text, FontRole preferred) {
    if (FontCoverage::covers(fonts.face(preferred), text)) {
      return preferred;
    }

    constexpr std::array fallback{FontRole::primary, FontRole::text, FontRole::symbols};
    for (const auto role : fallback) {
      if (FontCoverage::covers(fonts.face(role), text)) {
        return role;
      }
    }

    if constexpr (requires { fonts.fallbackCount(); }) {
      for (std::size_t index = 0; index < fonts.fallbackCount(); ++index) {
        const auto role = fallbackRole(index);
        if (FontCoverage::covers(fonts.face(role), text)) {
          return role;
        }
      }
    }

    return std::nullopt;
  }
};

}
}

// Interface: fonts/font_query.cppm
export {
namespace telar::gui::fonts {

class FontQuery {
public:
  static constexpr std::size_t maximum_bytes = 64;

  [[nodiscard]] inline static std::optional<FontQuery> create(std::string_view text) {
    if (text.size() > maximum_bytes) {
      return std::nullopt;
    }

    FontQuery query;
    std::ranges::copy(text, query.text_.begin());
    query.text_length_ = static_cast<std::uint8_t>(text.size());
    while (!text.empty()) {
      const auto length = Utf8Scalar::sequenceLength(static_cast<unsigned char>(text.front()));
      if (length == 0 || length > Utf8Scalar::leading_masks.size() || length > text.size()) {
        throw std::invalid_argument{"InvalidFontQueryUtf8"};
      }

      const auto scalar = text.substr(0, length);
      if (!FontCoverage::isSelectorOrJoiner(Utf8Scalar::decode(scalar))) {
        std::ranges::copy(scalar, query.codepoints_.begin() + query.query_length_);
        query.query_length_ = static_cast<std::uint8_t>(query.query_length_ + length);
      }

      text.remove_prefix(length);
    }

    return query.query_length_ == 0 ? std::nullopt : std::optional{query};
  }

  [[nodiscard]] inline std::string_view text() const noexcept {
    return {text_.data(), text_length_};
  }

  [[nodiscard]] inline const char *codepoints() const noexcept {
    return codepoints_.data();
  }

private:
  std::array<char, maximum_bytes> text_{};
  std::array<char, maximum_bytes + 1> codepoints_{};
  std::uint8_t text_length_ = 0;
  std::uint8_t query_length_ = 0;
};

}
}

// Interface: fonts/font_requests.cppm
export {
namespace telar::gui::fonts {

class FontRequests {
public:
  static constexpr std::size_t pending_capacity = 16;
  static constexpr unsigned maximum_retries = 4;

  inline void request(std::string_view text) {
    if (text.starts_with(placeholder_prefix) || misses_.contains(text) || queued(text)) {
      return;
    }

    const auto query = FontQuery::create(text);
    if (!query) {
      misses_.remember(text);
      return;
    }

    if (count_ == pending_.size()) {
      turned_away_ = true;
      return;
    }

    pending_[(head_ + count_) % pending_.size()] = *query;
    ++count_;
  }

  [[nodiscard]] inline std::optional<FontQuery> take() {
    if (in_flight_ || count_ == 0) {
      return std::nullopt;
    }

    in_flight_ = pending_[head_];
    head_ = (head_ + 1) % pending_.size();
    --count_;

    return in_flight_;
  }

  [[nodiscard]] inline bool finish(const FontQuery &query, bool changed) {
    if (in_flight_ && in_flight_->text() == query.text()) {
      in_flight_.reset();
    }

    if (changed) {
      retries_ = 0;
    } else {
      misses_.remember(query.text());
    }

    if (turned_away_ && count_ == 0 && !in_flight_) {
      turned_away_ = false;
      if (retries_ < maximum_retries) {
        ++retries_;
        return true;
      }
    }

    return changed;
  }

private:
  class Misses {
  public:
    [[nodiscard]] inline bool contains(std::string_view text) const {
      const auto hash = digest(text);
      const auto entries = bucket(hash);

      return std::ranges::find(entries, hash) != entries.end();
    }

    inline void remember(std::string_view text) {
      const auto hash = digest(text);
      auto entries = bucket(hash);
      for (auto &entry : entries) {
        if (entry == hash) {
          return;
        }

        if (entry == 0) {
          entry = hash;
          return;
        }
      }

      auto &next = next_[hash % sets];
      entries[next] = hash;
      next = (next + 1) % ways;
    }

  private:
    static constexpr std::size_t capacity = 4096;
    static constexpr std::size_t ways = 8;
    static constexpr std::size_t sets = capacity / ways;

    inline static std::uint64_t digest(std::string_view text) {
      return static_cast<std::uint64_t>(std::hash<std::string_view>{}(text)) | std::uint64_t{1};
    }

    [[nodiscard]] inline std::span<std::uint64_t> bucket(std::uint64_t hash) noexcept {
      return std::span{hashes_}.subspan((hash % sets) * ways, ways);
    }

    [[nodiscard]] inline std::span<const std::uint64_t> bucket(std::uint64_t hash) const noexcept {
      return std::span{hashes_}.subspan((hash % sets) * ways, ways);
    }

    std::array<std::uint64_t, capacity> hashes_{};
    std::array<std::size_t, sets> next_{};
  };

  [[nodiscard]] inline bool queued(std::string_view text) const {
    if (in_flight_ && in_flight_->text() == text) {
      return true;
    }

    for (std::size_t offset = 0; offset < count_; ++offset) {
      if (pending_[(head_ + offset) % pending_.size()].text() == text) {
        return true;
      }
    }

    return false;
  }

  std::array<FontQuery, pending_capacity> pending_{};
  std::optional<FontQuery> in_flight_;
  Misses misses_;
  std::size_t head_ = 0;
  std::size_t count_ = 0;
  unsigned retries_ = 0;
  bool turned_away_ = false;
};

}
}

// Interface: fonts/glyph_rasterization.cppm
export {
namespace telar::gui::fonts {

struct GlyphRasterization {
  bool optical = false;
  std::uint8_t strength = std::numeric_limits<std::uint8_t>::max();

  [[nodiscard]] constexpr std::uint16_t key() const noexcept {
    constexpr unsigned optical_shift = std::numeric_limits<std::uint8_t>::digits;

    return optical ? static_cast<std::uint16_t>((1U << optical_shift) | strength) : 0;
  }

  bool operator==(const GlyphRasterization &) const = default;
};

}
}
