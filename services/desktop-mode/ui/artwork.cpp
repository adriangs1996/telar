#include "artwork.hpp"
#include <QBuffer>
#include <QCache>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QFontMetricsF>
#include <QImageReader>
#include <QPainter>
#include <QQuickImageProvider>
#include <QUrl>
#include <algorithm>
#include <array>
#include <cmath>
#include <mutex>
#include <limits>

namespace {
  constexpr int provider_source_side = 64, provider_count = 5, maximum_sprite_side = 96,
                minimum_sprite_side = 8, favicon_cache_size = 128, maximum_favicon_side = 2048,
                maximum_glyph_side = 2048, maximum_glyph_bytes = 96, maximum_path_bytes = 4096;
  constexpr qint64 maximum_favicon_bytes = 1024 * 1024;
  constexpr std::array providers{"claude", "codex", "pi", "cursor", "opencode"};
  constexpr int icon_header_bytes = 6, icon_entry_bytes = 16, icon_maximum_side = 256;

  bool selectIconFrame(QImageReader &reader, const QByteArray &bytes, int side) {
    if (!bytes.startsWith(QByteArray("\0\0\1\0", 4))) {
      return bytes.startsWith("\x89PNG\r\n\x1a\n");
    }

    if (bytes.size() < icon_header_bytes) {
      return false;
    }

    const int count = uchar(bytes[4]) | (uchar(bytes[5]) << 8);
    if (!count || icon_header_bytes + count * icon_entry_bytes > bytes.size()) {
      return false;
    }

    int best = 0, above = std::numeric_limits<int>::max(), below = 0;
    for (int frame = 0; frame < count; ++frame) {
      const int offset = icon_header_bytes + frame * icon_entry_bytes;
      const int width = uchar(bytes[offset]) ? uchar(bytes[offset]) : icon_maximum_side;
      const int height = uchar(bytes[offset + 1]) ? uchar(bytes[offset + 1]) : icon_maximum_side;
      const int extent = std::min(width, height);
      if (extent >= side && extent < above) {
        best = frame;
        above = extent;
      } else if (above == std::numeric_limits<int>::max() && extent > below) {
        best = frame;
        below = extent;
      }
    }

    return reader.jumpToImage(best);
  }

  // Average in premultiplied space so transparent pixels never fringe an icon.
  QImage square(const QImage &source, int side) {
    if (source.width() < side || source.height() < side) {
      return source.scaled(side, side, Qt::IgnoreAspectRatio, Qt::SmoothTransformation);
    }

    const auto rgba = source.convertToFormat(QImage::Format_RGBA8888);
    QImage output(side, side, QImage::Format_RGBA8888);
    for (int y = 0; y < side; ++y) {
      const float top = float(y) * rgba.height() / side;
      const float bottom = float(y + 1) * rgba.height() / side;
      for (int x = 0; x < side; ++x) {
        const float left = float(x) * rgba.width() / side;
        const float right = float(x + 1) * rgba.width() / side;
        std::array<float, 3> rgb{};
        float alpha = 0, total = 0;
        for (int sy = int(std::floor(top)); sy < int(std::ceil(bottom)); ++sy) {
          for (int sx = int(std::floor(left)); sx < int(std::ceil(right)); ++sx) {
            const auto weight = (std::min(bottom, float(sy + 1)) - std::max(top, float(sy))) *
                                (std::min(right, float(sx + 1)) - std::max(left, float(sx)));
            const auto *pixel = rgba.constScanLine(sy) + sx * 4;
            const auto a = pixel[3] * weight;
            alpha += a;
            total += weight;
            for (std::size_t channel = 0; channel < rgb.size(); ++channel) {
              rgb[channel] += pixel[channel] * a;
            }
          }
        }

        auto *pixel = output.scanLine(y) + x * 4;
        for (std::size_t channel = 0; channel < rgb.size(); ++channel) {
          pixel[channel] =
              alpha > 0 ? std::clamp(int(std::round(rgb[channel] / alpha)), 0, 255) : 0;
        }

        pixel[3] = total > 0 ? std::clamp(int(std::round(alpha / total)), 0, 255) : 0;
      }
    }

    return output.convertToFormat(QImage::Format_ARGB32_Premultiplied);
  }

  QImage providerImage(const QString &provider, int side, QColor tint) {
    static const auto sheet = [] {
      QFile file(QStringLiteral(":/telar/fonts/provider-symbols-320x64.rgba"));
      if (!file.open(QIODevice::ReadOnly)) {
        return QImage{};
      }

      const auto bytes = file.readAll();
      if (bytes.size() != provider_count * provider_source_side * provider_source_side * 4) {
        return QImage{};
      }

      return QImage(reinterpret_cast<const uchar *>(bytes.constData()),
                    provider_count * provider_source_side,
                    provider_source_side,
                    QImage::Format_RGBA8888)
          .copy();
    }();
    const auto found = std::ranges::find_if(providers, [&](const char *name) {
      return provider == QLatin1StringView(name);
    });
    if (found == providers.end() || sheet.isNull()) {
      return {};
    }

    auto image = square(sheet.copy(int(found - providers.begin()) * provider_source_side,
                                   0,
                                   provider_source_side,
                                   provider_source_side),
                        side);
    if (provider == QStringLiteral("codex") || provider == QStringLiteral("cursor") ||
        provider == QStringLiteral("opencode")) {
      QPainter painter(&image);
      painter.setCompositionMode(QPainter::CompositionMode_SourceIn);
      painter.fillRect(image.rect(), tint);
    }

    return image;
  }

  QImage favicon(const QString &root, int side) {
    static std::mutex mutex;
    static QCache<QString, QImage> cache(favicon_cache_size);
    const auto key = root + QLatin1Char(':') + QString::number(side);
    {
      const std::lock_guard lock(mutex);
      if (const auto *image = cache.object(key)) {
        return *image;
      }
    }

    QImage image;
    for (const auto *name : {"favicon.png", "favicon.ico", ".telar/icon.png"}) {
      const QFileInfo file(QDir(root).filePath(QString::fromLatin1(name)));
      if (!file.isFile() || file.size() > maximum_favicon_bytes) {
        continue;
      }

      QFile source_file(file.absoluteFilePath());
      if (!source_file.open(QIODevice::ReadOnly)) {
        continue;
      }
      auto bytes = source_file.read(maximum_favicon_bytes + 1);
      if (bytes.size() > maximum_favicon_bytes) {
        continue;
      }
      QBuffer buffer(&bytes);
      buffer.open(QIODevice::ReadOnly);
      QImageReader reader(&buffer);
      if (!selectIconFrame(reader, bytes, side)) {
        break;
      }
      const auto size = reader.size();
      if (size.isEmpty() || size.width() > maximum_favicon_side ||
          size.height() > maximum_favicon_side) {
        break;
      }

      const auto source = reader.read();
      if (!source.isNull()) {
        image = square(source, side);
      }

      break;
    }

    const std::lock_guard lock(mutex);
    cache.insert(key, new QImage(image));
    return image;
  }

  QImage glyphImage(const QStringList &parts) {
    if (parts.size() != 5) {
      return {};
    }

    const auto text = QUrl::fromPercentEncoding(parts[1].toUtf8());
    const auto family = QUrl::fromPercentEncoding(parts[2].toUtf8());
    const auto pixels = parts[3].toInt();
    const QColor ink(QLatin1Char('#') + parts[4]);
    if (text.toUtf8().size() > maximum_glyph_bytes || pixels < 6 || pixels > maximum_glyph_side ||
        !ink.isValid()) {
      return {};
    }

    QFont font;
    font.setFamilies(
        {family, QStringLiteral("Symbols Nerd Font Mono"), QStringLiteral("JetBrains Mono")});
    font.setPixelSize(pixels);
    font.setHintingPreference(QFont::PreferNoHinting);
    const auto bounds = QFontMetricsF(font).tightBoundingRect(text);
    if (bounds.isEmpty() || bounds.width() > maximum_glyph_side ||
        bounds.height() > maximum_glyph_side) {
      return {};
    }

    QImage image(
        QSize(int(std::ceil(bounds.width())), int(std::ceil(bounds.height()))).expandedTo({1, 1}),
        QImage::Format_ARGB32_Premultiplied);
    image.fill(Qt::transparent);
    QPainter painter(&image);
    painter.setFont(font);
    painter.setPen(ink);
    painter.drawText(-bounds.topLeft(), text);
    return image;
  }

  class Artwork final : public QQuickImageProvider {
  public:
    Artwork()
        : QQuickImageProvider(QQuickImageProvider::Image, ForceAsynchronousImageLoading) {}

    QImage requestImage(const QString &id, QSize *size, const QSize &) override {
      const auto parts = id.split(QLatin1Char('/'));
      QImage image;
      if (parts.size() == 4 && parts[0] == QStringLiteral("provider")) {
        const auto side = parts[3].toInt();
        const QColor tint(QLatin1Char('#') + parts[2]);
        if (side >= minimum_sprite_side && side <= maximum_sprite_side && tint.isValid()) {
          image = providerImage(parts[1], side, tint);
        }
      } else if (parts.size() == 3 && parts[0] == QStringLiteral("favicon")) {
        const auto side = parts[2].toInt();
        const auto path = QUrl::fromPercentEncoding(parts[1].toUtf8());
        if (side >= minimum_sprite_side && side <= maximum_sprite_side &&
            path.toUtf8().size() <= maximum_path_bytes && QDir::isAbsolutePath(path)) {
          image = favicon(path, side);
        }
      } else if (!parts.isEmpty() && parts[0] == QStringLiteral("glyph")) {
        image = glyphImage(parts);
      }

      if (image.isNull()) {
        image = QImage(1, 1, QImage::Format_ARGB32_Premultiplied);
        image.fill(Qt::transparent);
      }

      if (size) {
        *size = image.size();
      }

      return image;
    }
  };
} // namespace

namespace ui {
  QQuickImageProvider *artwork() {
    return new Artwork;
  }
} // namespace ui
