#include "font_source.hpp"
#include "core/configuration.hpp"
#include "fonts/face.hpp"
#include "fonts/font_coverage.hpp"
#include "fonts/font_query.hpp"
#include "fonts/native_match.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include <QByteArray>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QString>
#include <QStringLiteral>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qnamespace.h>
#include <cstddef>
#include <exception>
#include <native/font.h>
#include <optional>
#include <stdexcept>
#include <utility>

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
      return TELAR_FONT_FAMILY_NOT_FOUND;
    }

    request.candidate = std::move(data);

    return TELAR_FONT_FOUND;
  } catch (const std::exception &) {
    return TELAR_FONT_FAMILY_NOT_FOUND;
  }
}

}

FontData loadFontData(const FontConfiguration &font) {
  const auto family = font.family.view().empty() ? QStringLiteral("JetBrains Mono") : QString::fromUtf8(font.family.view());
  const auto style = QString::fromUtf8(font.style.view());
  FontData data;
  QString path;
  if (family.compare(QStringLiteral("JetBrains Mono"), Qt::CaseInsensitive) == 0 && (style.isEmpty() || style.compare(QStringLiteral("Regular"), Qt::CaseInsensitive) == 0)) {
    path = QStringLiteral(":/telar/fonts/JetBrainsMono-Regular.ttf");
  } else {
    const auto family_bytes = family.toUtf8();
    const auto style_bytes = style.toUtf8();
    const auto status = telar_gui_find_font(family_bytes.constData(), style_bytes.constData(), &data.match);
    if (status != TELAR_FONT_FOUND) {
      throw std::runtime_error{status == TELAR_FONT_STYLE_NOT_FOUND ? "FontStyleNotFound" : "FontFamilyNotFound"};
    }

    path = QString::fromUtf8(data.match.path);
  }

  data.bytes = loadFontBytes(path);

  return data;
}

std::optional<FontData> loadFallbackFontData(const fonts::FontQuery &query) {
  FallbackRequest request{.query = query, .candidate = {}};
  fonts::FontMatch match{};
  if (telar_gui_find_validated_fallback_font(query.codepoints(), &match, acceptFallbackFont, &request) != TELAR_FONT_FOUND) {
    return std::nullopt;
  }

  return std::move(request.candidate);
}

QByteArray loadFontBytes(const QString &path) {
  const QFileInfo info{path};
  if (!info.isFile() || info.size() > TELAR_FONT_MAX_BYTES) {
    throw std::runtime_error{"FontFileUnavailable"};
  }

  QFile file{path};
  if (!file.open(QIODeviceBase::ReadOnly)) {
    throw std::runtime_error{"FontFileUnavailable"};
  }

  auto bytes = file.read(TELAR_FONT_MAX_BYTES + 1);
  if (bytes.isEmpty() || bytes.size() > TELAR_FONT_MAX_BYTES || file.error() != QFileDevice::NoError) {
    throw std::runtime_error{"InvalidFontData"};
  }

  return bytes;
}

}
