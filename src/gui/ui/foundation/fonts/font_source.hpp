#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "foundation/core/memory.hpp"
#include "tbc/view.hpp"
#include <QByteArray>
#include <QString>
#include <cstdint>
#include <optional>
#include <span>

#pragma once

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.base.ds;

namespace telar::gui::qt {

  struct FontData {
    QByteArray bytes;
    fonts::FontMatch match{};
  };

  FontData loadFontData(const FontConfiguration& font);
  QByteArray loadFontBytes(const QString& path);
  ds::Option<FontData> loadFallbackFontData(const fonts::FontQuery& query);

  template <Allocator Memory>
  class FontSource {
  public:
    // The source reads the font into memory, region `a`, and keeps nothing of the configuration.
    explicit FontSource(tbc::view<Memory&, tbc::lt::a> memory, const FontConfiguration& font)
        : bytes_(memory) {
      const auto data = loadFontData(font);

      bytes_.clear();
      bytes_.extend({reinterpret_cast<const std::uint8_t*>(data.bytes.constData()), static_cast<std::size_t>(data.bytes.size())});
      match_ = data.match;
    }

    [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
      return bytes_;
    }

    [[nodiscard]] const fonts::FontMatch& match() const noexcept {
      return match_;
    }

  private:
    tbc::view<ds::Vec<std::uint8_t, Memory>, tbc::lt::a> bytes_;
    fonts::FontMatch match_{};
  };

}
