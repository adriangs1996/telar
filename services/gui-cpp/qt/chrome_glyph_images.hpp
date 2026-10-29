#pragma once

#include "alpha_mask.hpp"
#include "fonts/font_role.hpp"
#include "fonts/glyph_bitmap_view.hpp"
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
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <memory>
#include <stdexcept>
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

template <fonts::FontProvider FontSet>
class ChromeGlyphImages {
public:
  ChromeGlyphImages(QQuickWindow &window, std::shared_ptr<FontSet> fonts)
      : window_(window),
        fonts_(std::move(fonts)),
        software_(window.rendererInterface()->graphicsApi() == QSGRendererInterface::Software) {}

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

    const auto bitmap = fonts_->face(role).rasterize({.index = index, .pixel_height = pixel_height, .style = style});
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
    const auto inserted = images_.insert(key, std::move(created));
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

  [[nodiscard]] static std::shared_ptr<ChromeGlyphImages> shared(QQuickWindow &window, const std::shared_ptr<FontSet> &fonts) {
    thread_local QHash<QPair<QQuickWindow *, const FontSet *>, std::weak_ptr<ChromeGlyphImages>> caches;
    for (auto entry = caches.begin(); entry != caches.end();) {
      if (entry.value().expired()) {
        entry = caches.erase(entry);
      } else {
        ++entry;
      }
    }

    const QPair<QQuickWindow *, const FontSet *> key{&window, fonts.get()};
    auto cached = caches.value(key).lock();
    if (!cached) {
      cached = std::make_shared<ChromeGlyphImages>(window, fonts);
      caches.insert(key, cached);
    }

    return cached;
  }

private:
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
};

}
