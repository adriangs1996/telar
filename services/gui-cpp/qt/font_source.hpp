#pragma once

#include "core/configuration.hpp"
#include "core/memory.hpp"
#include "fonts/font_query.hpp"
#include "fonts/native_match.hpp"
#include <QByteArray>
#include <QString>
#include <cstdint>
#include <optional>
#include <span>

namespace telar::gui::qt {

struct FontData {
  QByteArray bytes;
  fonts::FontMatch match{};
};

FontData loadFontData(const FontConfiguration &font);
QByteArray loadFontBytes(const QString &path);
std::optional<FontData> loadFallbackFontData(const fonts::FontQuery &query);

template <Allocator Memory>
class FontSource {
public:
  explicit FontSource(Memory &memory, const FontConfiguration &font)
      : bytes_(AllocatorRef<std::uint8_t, Memory>{memory}) {
    const auto data = loadFontData(font);
    bytes_.assign(data.bytes.cbegin(), data.bytes.cend());
    match_ = data.match;
  }

  [[nodiscard]] std::span<const std::uint8_t> bytes() const noexcept {
    return bytes_;
  }

  [[nodiscard]] const fonts::FontMatch &match() const noexcept {
    return match_;
  }

private:
  Vector<std::uint8_t, Memory> bytes_;
  fonts::FontMatch match_{};
};

}
