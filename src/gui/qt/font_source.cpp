#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "font_source.hpp"
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
#include <bit>
#include "telar_client/codecs/telar_wire.hpp"
#include <QByteArray>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QString>
#include <QStringLiteral>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qnamespace.h>
#include <exception>
#include <utility>

#include "platform/font.h"


import telar.gui.core.metrics;
import telar.gui.fonts.face;
import telar.gui.fonts.font_requests;

namespace telar::gui::qt {

namespace {

struct FallbackRequest {
  const fonts::FontQuery &query;
  std::optional<FontData> candidate;
};

int acceptFallbackFont(const fonts::FontMatch *match, void *context) noexcept {
  auto &request = *static_cast<FallbackRequest *>(context);
  try {
    FontData data;
    data.match = *match;
    data.bytes = loadFontBytes(QString::fromUtf8(match->path));
    const auto bytes = telar::byteView({data.bytes.constData(), static_cast<std::size_t>(data.bytes.size())});
    const fonts::Face face{bytes, *match};
    if (!face.monochrome() || !fonts::FontCoverage::covers(face, request.query.text())) {
      return telar_font_family_not_found;
    }

    request.candidate = std::move(data);

    return telar_font_found;
  } catch (const std::exception &) {
    return telar_font_family_not_found;
  }
}

}

FontData loadFontData(const FontConfiguration &font) {
  const auto family = font.family.view().empty() ? QStringLiteral("Telar Forma") : QString::fromUtf8(font.family.view());
  const auto style = QString::fromUtf8(font.style.view());
  const auto regular_style = style.isEmpty() || style.compare(QStringLiteral("Regular"), Qt::CaseInsensitive) == 0;
  FontData data;
  QString path;
  if (family.compare(QStringLiteral("JetBrains Mono"), Qt::CaseInsensitive) == 0 && regular_style) {
    path = QStringLiteral(":/telar/fonts/JetBrainsMono-Regular.ttf");
  } else if (family.compare(QStringLiteral("Telar Forma"), Qt::CaseInsensitive) == 0) {
    if (!regular_style) {
      throw std::runtime_error{"FontStyleNotFound"};
    }

    path = QStringLiteral(":/telar/fonts/TelarForma-Regular.ttf");
  } else {
    const auto family_bytes = family.toUtf8();
    const auto style_bytes = style.toUtf8();
    const auto status = telarGuiFindFont(family_bytes.constData(), style_bytes.constData(), &data.match);
    if (status != telar_font_found) {
      throw std::runtime_error{status == telar_font_style_not_found ? "FontStyleNotFound" : "FontFamilyNotFound"};
    }

    path = QString::fromUtf8(data.match.path);
  }

  data.bytes = loadFontBytes(path);

  return data;
}

std::optional<FontData> loadFallbackFontData(const fonts::FontQuery &query) {
  FallbackRequest request{.query = query, .candidate = {}};
  fonts::FontMatch match{};
  if (telarGuiFindValidatedFallbackFont(query.codepoints(), &match, acceptFallbackFont, &request) != telar_font_found) {
    return std::nullopt;
  }

  return std::move(request.candidate);
}

QByteArray loadFontBytes(const QString &path) {
  const QFileInfo info{path};
  if (!info.isFile() || info.size() > telar_font_max_bytes) {
    throw std::runtime_error{"FontFileUnavailable"};
  }

  QFile file{path};
  if (!file.open(QIODeviceBase::ReadOnly)) {
    throw std::runtime_error{"FontFileUnavailable"};
  }

  auto bytes = file.read(telar_font_max_bytes + 1);
  if (bytes.isEmpty() || bytes.size() > telar_font_max_bytes || file.error() != QFileDevice::NoError) {
    throw std::runtime_error{"InvalidFontData"};
  }

  return bytes;
}

}
