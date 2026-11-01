#include "provider_artwork.hpp"
#include "graphics/artwork_resize.hpp"
#include "presentation/application_mark.hpp"
#include "telar_client/serializers/telar_messages.hpp"
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

namespace telar::gui::qt {

namespace {

constexpr int source_side = 64;
constexpr std::array providers{AgentProvider::claude, AgentProvider::codex, AgentProvider::pi, AgentProvider::cursor, AgentProvider::opencode};
constexpr auto source_stride = providers.size() * source_side * RgbaImageView::channels;
constexpr auto sheet_bytes = source_stride * source_side;

const QByteArray &providerSheet() {
  static const auto pixels = [] {
    QFile source{QStringLiteral(":/telar/fonts/provider-symbols-320x64.rgba")};
    if (!source.open(QIODevice::ReadOnly)) {
      return QByteArray{};
    }

    const auto bytes = source.read(static_cast<qint64>(sheet_bytes) + 1);
    return bytes.size() == static_cast<qsizetype>(sheet_bytes) ? bytes : QByteArray{};
  }();

  return pixels;
}

}

QImage ProviderArtwork::image(AgentProvider provider, int side) {
  const auto *const found = std::ranges::find(providers, provider);
  if (found == providers.end() || side < ApplicationMark::minimum_cell || side > ApplicationMark::maximum_cell) {
    return {};
  }

  const auto &sheet = providerSheet();
  if (sheet.isEmpty()) {
    return {};
  }

  const auto offset = static_cast<std::size_t>(std::distance(providers.begin(), found)) * source_side * RgbaImageView::channels;
  const RgbaImageView source{.pixels = std::as_bytes(std::span{sheet.constData(), static_cast<std::size_t>(sheet.size())}).subspan(offset), .stride = source_stride, .width = source_side, .height = source_side};
  QImage output{side, side, QImage::Format_RGBA8888_Premultiplied};
  if (output.isNull()) {
    return {};
  }

  const auto destination = std::span{output.bits(), static_cast<std::size_t>(output.sizeInBytes())};
  if (!ArtworkResize::square(source, destination, static_cast<std::size_t>(side))) {
    return {};
  }

  ArtworkResize::premultiply(destination);

  return output;
}

QImage ProviderArtwork::telar(int side) {
  if (side < ApplicationMark::minimum_cell || side > ApplicationMark::maximum_cell) {
    return {};
  }

  QSvgRenderer renderer{QStringLiteral(":/telar/fonts/telar-mark-mono.svg")};
  if (!renderer.isValid()) {
    return {};
  }

  QImage output{side, side, QImage::Format_ARGB32_Premultiplied};
  if (output.isNull()) {
    return {};
  }

  output.fill(Qt::transparent);
  {
    QPainter painter{&output};
    painter.setRenderHint(QPainter::Antialiasing);
    renderer.render(&painter);
  }

  return output;
}

}
