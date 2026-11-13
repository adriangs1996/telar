#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "tbc/view.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <algorithm>
#include "telar_base/memory/fixed_text.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include <chrono>
#include "../core/memory.hpp"
#include "font_resolver.hpp"
#include "font_source.hpp"
#include <span>
#include <freetype/freetype.h>
#include <hb.h>
#include <memory>
#include "../platform/font.h"
#include <cstring>
#include <cmath>
#include <limits>
#include <stdexcept>
#include <type_traits>
#include "telar_base/memory/allocator.hpp"
#include <QtCore/qtypes.h>
#include <utility>

#pragma once
#include "core/memory.hpp"


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.terminal.font_grid;

namespace telar::gui::qt {

template <Allocator Memory>
class FontCache {
public:
  static constexpr std::size_t scale_capacity = 8;

  // The cache allocates its generations from memory, region `a`.
  explicit FontCache(tbc::view<Memory &, tbc::lt::a> memory) noexcept
      : memory_(memory),
        generation_(nullptr, AllocationDeleter<Generation, Memory>{memory}) {}

  [[nodiscard]] ResolvedFont resolve(const FontConfiguration &font, qreal scale) {
    static_cast<void>(FontGrid::pixelHeight(font, static_cast<float>(scale)));
    if (!generation_ || !sameGeometry(generation_->configuration, font)) {
      return replace(font, scale);
    }

    for (const auto &entry : entries_) {
      if (entry.font && entry.scale == scale) {
        return *entry.font;
      }
    }

    return remember(FontResolver::resolve(generation_->face, font, scale), scale);
  }

private:
  struct Generation {
    FontConfiguration configuration;
    tbc::view<FontSource<Memory>, tbc::lt::a> source;
    // The face reads the bytes its source holds.
    tbc::view<fonts::Face, tbc::lt::self> face;

    explicit Generation(tbc::view<Memory &, tbc::lt::a> memory, const FontConfiguration &font)
        : configuration(font),
          source(memory, font),
          face(source.bytes(), source.match()) {}
  };

  struct Entry {
    qreal scale = 0;
    std::optional<ResolvedFont> font;
  };

  static bool sameGeometry(const FontConfiguration &first, const FontConfiguration &second) noexcept {
    return first.family.view() == second.family.view() && first.style.view() == second.style.view() && first.size == second.size && first.line_height == second.line_height && first.letter_spacing == second.letter_spacing;
  }

  ResolvedFont replace(const FontConfiguration &font, qreal scale) {
    auto replacement = makeOwned<Generation>(memory_, memory_, font);
    auto resolved = FontResolver::resolve(replacement->face, font, scale);
    generation_ = std::move(replacement);
    for (auto &entry : entries_) {
      entry.font.reset();
    }

    next_slot_ = 0;

    return remember(std::move(resolved), scale);
  }

  ResolvedFont remember(ResolvedFont &&font, qreal scale) {
    auto &entry = entries_[next_slot_];
    const auto &stored = entry.font.emplace(std::move(font));
    entry.scale = scale;
    next_slot_ = (next_slot_ + 1) % entries_.size();

    return stored;
  }

  tbc::view<Memory &, tbc::lt::a> memory_;
  tbc::view<Owned<Generation, Memory>, tbc::lt::a> generation_;
  std::array<Entry, scale_capacity> entries_{};
  std::size_t next_slot_ = 0;
};

}
