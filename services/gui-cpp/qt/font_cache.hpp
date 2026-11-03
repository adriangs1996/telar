#pragma once

#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "font_resolver.hpp"
#include "font_source.hpp"
#include "fonts/face.hpp"
#include "telar_base/memory/allocator.hpp"
#include "terminal/font_grid.hpp"
#include <QtCore/qtypes.h>
#include <array>
#include <cstddef>
#include <optional>
#include <utility>

namespace telar::gui::qt {

template <Allocator Memory>
class FontCache {
public:
  static constexpr std::size_t scale_capacity = 8;

  explicit FontCache(Memory &memory) noexcept
      : memory_(memory),
        generation_(nullptr, runtime::AllocationDeleter<Generation, Memory>{memory}) {}

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
    FontSource<Memory> source;
    fonts::Face face;

    explicit Generation(Memory &memory, const FontConfiguration &font)
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

  Memory &memory_;
  Owned<Generation, Memory> generation_;
  std::array<Entry, scale_capacity> entries_{};
  std::size_t next_slot_ = 0;
};

}
