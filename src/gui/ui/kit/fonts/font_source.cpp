module telar.gui.ui.kit.fonts;

import std;
import telar.gui.qt;
import telar.gui.foundation.fonts;
import telar.wire.vocabulary;
import telar.base.ds;

namespace telar::gui::qt {
  using Qt::StringLiterals::operator""_s;

  namespace {

    struct FallbackRequest {
      const fonts::FontQuery& query;
      ds::Option<FontData> candidate;
    };

    int acceptFallbackFont(const fonts::FontMatch* match, void* context) noexcept {
      auto& request = *static_cast<FallbackRequest*>(context);

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
      } catch (const std::exception&) {
        return telar_font_family_not_found;
      }
    }

  }

  FontData loadFontData(const FontConfiguration& font) {
    const auto family = font.family.view().empty() ? u"Telar Forma"_s : QString::fromUtf8(font.family.view());
    const auto style = QString::fromUtf8(font.style.view());
    const auto regular_style = style.isEmpty() || style.compare(u"Regular"_s, Qt::CaseInsensitive) == 0;
    FontData data;
    QString path;

    if (family.compare(u"JetBrains Mono"_s, Qt::CaseInsensitive) == 0 && regular_style) {
      path = u":/telar/fonts/JetBrainsMono-Regular.ttf"_s;
    } else if (family.compare(u"Telar Forma"_s, Qt::CaseInsensitive) == 0) {
      if (!regular_style) {
        throw std::runtime_error{"FontStyleNotFound"};
      }

      path = u":/telar/fonts/TelarForma-Regular.ttf"_s;
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

  ds::Option<FontData> loadFallbackFontData(const fonts::FontQuery& query) {
    const auto* codepoints = query.codepoints();
    FallbackRequest request{.query = query, .candidate = {}};
    fonts::FontMatch match{};
    if (telarGuiFindValidatedFallbackFont(codepoints, &match, acceptFallbackFont, &request) != telar_font_found) {
      return ds::none;
    }

    return std::move(request.candidate);
  }

  QByteArray loadFontBytes(const QString& path) {
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
