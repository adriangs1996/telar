#pragma once

#include "chrome_fonts.hpp"
#include "font_asset.hpp"
#include "font_collection.hpp"
#include "fonts/face.hpp"
#include "fonts/font_role.hpp"
#include <QByteArray>
#include <QString>
#include <array>
#include <cstddef>
#include <memory>
#include <optional>
#include <string_view>

namespace telar::gui::qt {

class ResidentFonts {
public:
  explicit ResidentFonts(std::shared_ptr<const FontAsset> source);
  explicit ResidentFonts(std::shared_ptr<const FontCollection> collection);
  [[nodiscard]] fonts::Face &face(fonts::FontRole role);
  [[nodiscard]] std::optional<fonts::FontRole> source(std::string_view text, fonts::FontRole preferred);
  [[nodiscard]] std::size_t fallbackCount() const noexcept;
  [[nodiscard]] static std::shared_ptr<const FontAsset> resolveSource(const QString &family, const QString &style);
  [[nodiscard]] static std::shared_ptr<ResidentFonts> shared(const std::shared_ptr<const FontAsset> &source);
  [[nodiscard]] static std::shared_ptr<ResidentFonts> shared(const std::shared_ptr<const FontCollection> &collection);

private:
  std::shared_ptr<const FontAsset> primary_source_;
  std::shared_ptr<const FontAsset> text_source_;
  std::shared_ptr<const FontAsset> symbols_source_;
  std::shared_ptr<ChromeFonts> chrome_;
  std::shared_ptr<const FontCollection> collection_;
  fonts::Face primary_;
  fonts::Face text_;
  fonts::Face symbols_;
  std::array<std::optional<fonts::Face>, fonts::maximum_fallback_faces> fallbacks_;
};

}
