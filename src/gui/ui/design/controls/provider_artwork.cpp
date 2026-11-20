#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include "provider_artwork.hpp"
#include "telar_wire/serializers/telar_messages.hpp"
#include "ui/foundation/scene/qt_buffers.hpp"
#include <QByteArray>
#include <QFile>
#include <QIODevice>
#include <QImage>
#include <QPainter>
#include <QSvgRenderer>
#include <QtCore/qnamespace.h>
#include <QtCore/qstring.h>
#include <QtCore/qstringliteral.h>
#include <QtCore/qtypes.h>
#include <algorithm>
#include <array>
#include <cstddef>
#include <iterator>
#include <span>

import telar.gui.foundation.core;
import telar.gui.application;
import telar.base.ds;

namespace telar::gui::qt {

  namespace {

    constexpr int source_side = 64;
    constexpr ds::Array providers{AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode};
    constexpr auto source_stride = providers.size() * source_side * application::terminal::graphics::RgbaImageView::channels;
    constexpr auto sheet_bytes = source_stride * source_side;

    const QByteArray& providerSheet() {
      [[clang::no_destroy]] static const auto pixels = [] {
        QFile source{QStringLiteral(":/telar/fonts/provider-symbols-320x64.rgba")};
        if (!source.open(QIODevice::ReadOnly)) {
          return QByteArray{};
        }

        const auto bytes = source.read(static_cast<qint64>(sheet_bytes) + 1);

        return bytes.size() == static_cast<qsizetype>(sheet_bytes) ? bytes : QByteArray{};
      }();

      return pixels;
    }

    // The default mark wears Zenburn, Telar's default theme and brand colors; every other preset has its own.
    QString telarSource(bool monochrome, int theme) {
      if (monochrome) {
        return QStringLiteral(":/telar/fonts/telar-mark-mono.svg");
      }

      struct ThemedMark {
        ThemeName theme;
        QStringView source;
      };

      static constexpr ds::Array marks{
          ThemedMark{.theme = ThemeName::shade, .source = u":/telar/fonts/telar-mark-shade.svg"},
          ThemedMark{.theme = ThemeName::vesper, .source = u":/telar/fonts/telar-mark-vesper.svg"},
          ThemedMark{.theme = ThemeName::catppuccin, .source = u":/telar/fonts/telar-mark-catppuccin.svg"},
          ThemedMark{.theme = ThemeName::tokyo_night, .source = u":/telar/fonts/telar-mark-tokyo-night.svg"},
          ThemedMark{.theme = ThemeName::pierre_dark, .source = u":/telar/fonts/telar-mark-pierre-dark.svg"},
          ThemedMark{.theme = ThemeName::pierre_dark_soft, .source = u":/telar/fonts/telar-mark-pierre-dark-soft.svg"},
          ThemedMark{.theme = ThemeName::kanagawa, .source = u":/telar/fonts/telar-mark-kanagawa.svg"},
          ThemedMark{.theme = ThemeName::kanagawa_dragon, .source = u":/telar/fonts/telar-mark-kanagawa-dragon.svg"},
          ThemedMark{.theme = ThemeName::terminal, .source = u":/telar/fonts/telar-mark-terminal.svg"},
          ThemedMark{.theme = ThemeName::cybervenom, .source = u":/telar/fonts/telar-mark-cybervenom.svg"},
          ThemedMark{.theme = ThemeName::zenburn, .source = u":/telar/fonts/telar-mark-zenburn.svg"},
      };

      const auto* const found = std::ranges::find_if(marks, [theme](const ThemedMark& mark) {
        return static_cast<int>(mark.theme) == theme;
      });

      return found == marks.end() ? QStringLiteral(":/telar/fonts/telar-mark.svg") : found->source.toString();
    }

  }

  QImage ProviderArtwork::image(AgentProvider provider, int side) {
    const auto* const found = std::ranges::find(providers, provider);
    if (found == providers.end() || side < application::activity::ApplicationMark::minimum_cell || side > application::activity::ApplicationMark::maximum_cell) {
      return {};
    }

    const auto& sheet = providerSheet();
    if (sheet.isEmpty()) {
      return {};
    }

    const auto offset = static_cast<std::size_t>(std::distance(providers.begin(), found)) * source_side * application::terminal::graphics::RgbaImageView::channels;
    const application::terminal::graphics::RgbaImageView source{.pixels = std::as_bytes(std::span<const char>{sheet}).subspan(offset), .stride = source_stride, .width = source_side, .height = source_side};
    // A failed allocation leaves the image null.
    QImage output{side, side, QImage::Format_RGBA8888_Premultiplied};
    if (!output.isNull()) {
      const auto destination = imageBytes(output);

      if (application::terminal::graphics::ArtworkResize::square(source, destination, static_cast<std::size_t>(side))) {
        application::terminal::graphics::ArtworkResize::premultiply(destination);
      } else {
        output = QImage{};
      }
    }

    return output;
  }

  QImage ProviderArtwork::telar(int side, bool monochrome, int theme) {
    return vector(telarSource(monochrome, theme), side);
  }

  QImage ProviderArtwork::symbol(QStringView name, int side) {
    static constexpr ds::Array<QStringView, 6> names{u"bot", u"chevron-down", u"chevron-right", u"git-branch", u"server", u"square-terminal"};
    const auto* const found = std::ranges::find(names, name);

    return found == names.end() ? QImage{} : vector(QStringLiteral(":/telar/icons/%1.svg").arg(name), side);
  }

  QImage ProviderArtwork::vector(const QString& source, int side) {
    if (side < application::activity::ApplicationMark::minimum_cell || side > application::activity::ApplicationMark::maximum_cell) {
      return {};
    }

    QSvgRenderer renderer{source};
    if (!renderer.isValid()) {
      return {};
    }

    // A failed allocation leaves the image null.
    QImage output{side, side, QImage::Format_ARGB32_Premultiplied};
    if (!output.isNull()) {
      output.fill(Qt::transparent);
      QPainter painter{&output};

      painter.setRenderHint(QPainter::Antialiasing);
      renderer.render(&painter);
    }

    return output;
  }

}
