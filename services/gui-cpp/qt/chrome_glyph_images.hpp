#pragma once

#include "alpha_mask.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
#include "fonts/glyph_rasterization.hpp"
#include <QColor>
#include <QHash>
#include <QImage>
#include <QPainter>
#include <QPair>
#include <QQuickWindow>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QtCore/qcontainerfwd.h>
#include <QtCore/qnamespace.h>
#include <QtCore/qtypes.h>
#ifdef Q_OS_MACOS
#include "core/memory.hpp"
#include "platform/macos/glyph_rasterizer.hpp"
#endif
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>
#include <memory>
#include <stdexcept>
#include <type_traits>
#include <utility>

namespace telar::gui::qt {

struct ColoredGlyph {
  QColor color;
  AlphaMaskRef mask;
};

struct CachedGlyph {
  AlphaMaskRef mask;
  std::int32_t left = 0;
  std::int32_t top = 0;
  std::array<ColoredGlyph, 2> colors;
  std::size_t next_color = 0;
};

struct OpticalGlyphRasterizers {
  std::uint8_t strength = std::numeric_limits<std::uint8_t>::max();
#ifdef Q_OS_MACOS
  static constexpr auto font_roles = static_cast<std::size_t>(fonts::FontRole::fallback_7) + 1;
  SystemAllocator memory;
  Vector<std::uint8_t, SystemAllocator> pixels{AllocatorRef<std::uint8_t, SystemAllocator>{memory}};
  std::array<std::unique_ptr<platform::GlyphRasterizer>, font_roles> fonts{};
#endif
};

struct StandardGlyphRasterizers {};

template <fonts::FontProvider FontSet, bool optical = false>
class ChromeGlyphImages {
public:
  ChromeGlyphImages(QQuickWindow &window, std::shared_ptr<FontSet> fonts, [[maybe_unused]] fonts::GlyphRasterization rasterization = {})
      : window_(window),
        fonts_(std::move(fonts)),
        software_(window.rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {
    if constexpr (optical) {
      rasterization_.strength = rasterization.strength;
    }
  }

  [[nodiscard]] bool software() const noexcept {
    return software_;
  }

  [[nodiscard]] CachedGlyph &glyph(std::uint32_t index, std::uint16_t pixel_height, fonts::FontRole role, fonts::GlyphStyle style = {}) {
    constexpr unsigned height_shift = 32;
    constexpr unsigned role_shift = 48;
    constexpr unsigned bold_shift = 56;
    constexpr unsigned italic_shift = 57;
    const auto key = static_cast<quint64>(index) | (static_cast<quint64>(pixel_height) << height_shift) | (static_cast<quint64>(role) << role_shift) | (static_cast<quint64>(style.bold) << bold_shift) | (static_cast<quint64>(style.italic) << italic_shift);
    const auto found = images_.find(key);
    if (found != images_.end()) {
      return found.value();
    }

    if (images_.size() == maximum_glyphs) {
      throw std::runtime_error{"ChromeGlyphCacheFull"};
    }

    const auto bitmap = rasterize({.index = index, .pixel_height = pixel_height, .style = style}, role);
    if (bitmap.width > maximum_side || bitmap.height > maximum_side) {
      throw std::runtime_error{"ChromeGlyphTooLarge"};
    }

    constexpr std::size_t row_alignment = 4;
    const auto row_bytes = ((static_cast<std::size_t>(bitmap.width) + row_alignment - 1) / row_alignment) * row_alignment;
    const auto mask_bytes = row_bytes * bitmap.height;
    if (mask_bytes > maximum_mask_bytes - mask_bytes_) {
      throw std::runtime_error{"ChromeGlyphBudgetExceeded"};
    }

    QImage alpha;
    if (mask_bytes != 0) {
      alpha = QImage{static_cast<int>(bitmap.width), static_cast<int>(bitmap.height), QImage::Format_Alpha8};
      if (alpha.isNull()) {
        throw std::bad_alloc{};
      }

      alpha.fill(0);
      for (std::uint32_t row = 0; row < bitmap.height; ++row) {
        const auto coverage = bitmap.row(row);
        std::memcpy(alpha.scanLine(static_cast<int>(row)), coverage.data(), coverage.size());
      }
    }

    std::unique_ptr<QSGTexture> texture;
    if (!software_ && !alpha.isNull()) {
      texture = createTexture(alpha.convertToFormat(QImage::Format_RGBA8888_Premultiplied));
    }

    const auto mask = AlphaMaskRef{new AlphaMask{std::move(alpha), std::move(texture)}};
    CachedGlyph created;
    created.mask = mask;
    created.left = bitmap.left;
    created.top = bitmap.top;
    const auto inserted = images_.emplace(key, std::move(created));
    mask_bytes_ += mask_bytes;

    return inserted.value();
  }

  [[nodiscard]] AlphaMaskRef colored(CachedGlyph &glyph, const QColor &color) {
    for (const auto &entry : glyph.colors) {
      if (entry.mask && entry.color == color) {
        return entry.mask;
      }
    }

    auto image = glyph.mask->alpha.convertToFormat(QImage::Format_RGBA8888_Premultiplied);
    {
      QPainter painter{&image};
      painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
      painter.fillRect(image.rect(), color);
    }

    auto mask = AlphaMaskRef{new AlphaMask{glyph.mask->alpha, createTexture(image)}};
    glyph.colors[glyph.next_color] = {.color = color, .mask = mask};
    glyph.next_color = (glyph.next_color + 1) % glyph.colors.size();

    return mask;
  }

  [[nodiscard]] static std::shared_ptr<ChromeGlyphImages> shared(QQuickWindow &window, const std::shared_ptr<FontSet> &fonts, fonts::GlyphRasterization rasterization = {}) {
    using Source = QPair<QQuickWindow *, const FontSet *>;
    using Key = std::conditional_t<optical, std::pair<Source, std::uint16_t>, Source>;
    thread_local QHash<Key, std::weak_ptr<ChromeGlyphImages>> caches;
    for (auto entry = caches.begin(); entry != caches.end();) {
      if (entry.value().expired()) {
        entry = caches.erase(entry);
      } else {
        ++entry;
      }
    }

    const Key key = [&] -> Key {
      if constexpr (optical) {
        return {{&window, fonts.get()}, rasterization.key()};
      } else {
        return {&window, fonts.get()};
      }
    }();
    auto cached = caches.value(key).lock();
    if (!cached) {
      cached = std::make_shared<ChromeGlyphImages>(window, fonts, rasterization);
      caches.insert(key, cached);
    }

    return cached;
  }

private:
  [[nodiscard]] fonts::GlyphBitmapView rasterize(fonts::GlyphRasterRequest request, fonts::FontRole role) {
#ifdef Q_OS_MACOS
    if constexpr (optical) {
      if constexpr (requires { fonts_->asset(role); }) {
        return rasterizeOptical(request, role);
      } else {
        throw std::invalid_argument{"OpticalFontAssetsUnavailable"};
      }
    }
#endif

    return fonts_->face(role).rasterize(request);
  }

#ifdef Q_OS_MACOS
  [[nodiscard]] fonts::GlyphBitmapView rasterizeOptical(fonts::GlyphRasterRequest request, fonts::FontRole role) {
    auto &rasterizer = rasterization_.fonts.at(static_cast<std::size_t>(role));
    if (!rasterizer) {
      if (rasterization_.pixels.empty()) {
        rasterization_.pixels.resize(platform::GlyphRasterizer::requiredBytes());
      }

      const auto &asset = fonts_->asset(role);
      rasterizer = std::make_unique<platform::GlyphRasterizer>(rasterization_.pixels, asset.bytes(), asset.match(), rasterization_.strength);
    }

    return rasterizer->rasterize(request);
  }
#endif

  [[nodiscard]] std::unique_ptr<QSGTexture> createTexture(const QImage &image) {
    std::unique_ptr<QSGTexture> texture{window_.createTextureFromImage(image, QQuickWindow::TextureCanUseAtlas)};
    if (!texture) {
      throw std::runtime_error{"ChromeTextureUnavailable"};
    }

    texture->setFiltering(QSGTexture::Nearest);

    return texture;
  }

  static constexpr qsizetype maximum_glyphs = 4096;
  static constexpr std::uint32_t maximum_side = 2048;
  static constexpr std::size_t maximum_mask_bytes = static_cast<std::size_t>(maximum_side) * maximum_side;

  QQuickWindow &window_;
  std::shared_ptr<FontSet> fonts_;
  QHash<quint64, CachedGlyph> images_;
  std::size_t mask_bytes_ = 0;
  bool software_ = false;
  [[no_unique_address]] std::conditional_t<optical, OpticalGlyphRasterizers, StandardGlyphRasterizers> rasterization_;
};

}
