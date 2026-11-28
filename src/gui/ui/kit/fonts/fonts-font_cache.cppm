export module telar.gui.ui.kit.fonts:font_cache;

import std;
import telar.gui.qt;
import telar.tbc;
import :font_resolver;
import :font_source;
import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.gui.foundation.terminal;
import telar.base.ds;
import telar.base.memory.allocators;

export namespace telar::gui::qt {

  template <Allocator Memory>
  class FontCache {
  public:
    static constexpr std::size_t scale_capacity = 8;

    // The cache allocates its generations from memory, region `a`.
    [[tbc::generic]] explicit FontCache(tbc::mut_a<Memory> memory) noexcept
        : memory_(memory),
          generation_() {}

    [[tbc::generic]] [[nodiscard]] ResolvedFont resolve(const FontConfiguration& font, qreal scale) {
      static_cast<void>(FontGrid::pixelHeight(font, static_cast<float>(scale)));
      if (!generation_ || !sameGeometry(generation_->configuration, font)) {
        return replace(font, scale);
      }

      for (const auto& entry : entries_) {
        if (entry.font && std::equal_to<>{}(entry.scale, scale)) {
          return *entry.font;
        }
      }

      return remember(FontResolver::resolve(generation_.getMut().face, font, scale), scale);
    }

  private:
    struct Generation {
      FontConfiguration configuration;
      tbc::val_a<FontSource<Memory>> source;
      // The face reads the bytes its source holds.
      tbc::val_self<fonts::Face> face;

      [[tbc::hot_path]] inline explicit Generation(tbc::mut_a<Memory> memory, const FontConfiguration& font)
          : configuration(font),
            source(memory, font),
            face(source.bytes(), source.match()) {}
    };

    struct Entry {
      qreal scale = 0;
      ds::Option<ResolvedFont> font;
    };

    [[tbc::generic]] static bool sameGeometry(const FontConfiguration& first, const FontConfiguration& second) noexcept {
      return first.family.view() == second.family.view() && first.style.view() == second.style.view() && std::equal_to<>{}(first.size, second.size) && std::equal_to<>{}(first.line_height, second.line_height) && std::equal_to<>{}(first.letter_spacing, second.letter_spacing);
    }

    [[tbc::generic]] ResolvedFont replace(const FontConfiguration& font, qreal scale) {
      auto replacement = ds::makeBox<Generation>(memory_, memory_, font);
      auto resolved = FontResolver::resolve(replacement.getMut().face, font, scale);

      generation_ = std::move(replacement);
      for (auto& entry : entries_.viewMut()) {
        entry.font.reset();
      }

      next_slot_ = 0;

      return remember(std::move(resolved), scale);
    }

    [[tbc::generic]] ResolvedFont remember(ResolvedFont&& font, qreal scale) {
      auto& entry = entries_.atMut(next_slot_);
      const auto& stored = entry.font.emplace(std::move(font));

      entry.scale = scale;
      next_slot_ = (next_slot_ + 1) % entries_.size();

      return stored;
    }

    tbc::mut_a<Memory> memory_;
    tbc::val_a<ds::Box<Generation, Memory>> generation_;
    ds::Array<Entry, scale_capacity> entries_{};
    std::size_t next_slot_ = 0;
  };

}
