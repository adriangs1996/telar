#include "font_source.hpp"
#include "core/configuration.hpp"
#include "fonts/font_query.hpp"
#include "fonts/native_match.hpp"
#include <QByteArray>
#include <QFile>
#include <QFileDevice>
#include <QFileInfo>
#include <QString>
#include <QtCore/qiodevicebase.h>
#include <QtCore/qnamespace.h>
#include <native/font.h>
#include <optional>
#include <stdexcept>

namespace telar::gui::qt {

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
  FontData data;
  if (telar_gui_find_fallback_font(query.codepoints(), &data.match) != TELAR_FONT_FOUND) {
    return std::nullopt;
  }

  data.bytes = loadFontBytes(QString::fromUtf8(data.match.path));

  return data;
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
