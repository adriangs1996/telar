#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "assertions.hpp"
#include "../application/dependencies.hpp"
#include "../qt/attachment_preview.hpp"
#include "../attachments/catalog.hpp"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <stdexcept>
#include "../attachments/sensitive_bytes.hpp"
#include "../attachments/types.hpp"
#include <QBuffer>
#include <QByteArray>
#include <QCoreApplication>
#include <QImage>
#include <QIODevice>
#include <QSize>
#include <QtCore/qnamespace.h>
#include <array>
#include <cstddef>
#include <exception>
#include <iostream>
#include <span>

#include "application/dependencies.hpp"
#include "attachment_preview.hpp"
#include "attachments/catalog.hpp"
#include "attachments/sensitive_bytes.hpp"
#include "attachments/types.hpp"


import telar.gui.attachments.marker_input;

namespace {

using namespace telar::gui;
using telar::gui::test::require;

constexpr std::size_t channels = 4;
constexpr std::uint32_t maximum_channel = 255;
constexpr std::uint32_t half_channel = maximum_channel / 2;
constexpr std::uint32_t thin_width = 70000;
constexpr std::array small_pixels{
    std::uint8_t{255}, std::uint8_t{64}, std::uint8_t{16}, std::uint8_t{128},
    std::uint8_t{0}, std::uint8_t{255}, std::uint8_t{0}, std::uint8_t{255},
    std::uint8_t{255}, std::uint8_t{255}, std::uint8_t{255}, std::uint8_t{0},
    std::uint8_t{32}, std::uint8_t{16}, std::uint8_t{8}, std::uint8_t{64},
    std::uint8_t{16}, std::uint8_t{32}, std::uint8_t{64}, std::uint8_t{255},
    std::uint8_t{255}, std::uint8_t{0}, std::uint8_t{255}, std::uint8_t{255},
};

AttachmentCapture<ApplicationAllocator> captured(ApplicationAllocator &memory, const QImage &image) {
  QByteArray encoded;
  QBuffer buffer{&encoded};
  require(buffer.open(QIODevice::WriteOnly) && image.save(&buffer, "PNG"), "the fixture PNG must encode");
  AttachmentCapture<ApplicationAllocator> result{
      .request = {.capture = {.id = 1, .target = {.pane_id = 1, .pane_generation = 2}}},
      .png = SensitiveBytes{memory},
      .width = static_cast<std::uint32_t>(image.width()),
      .height = static_cast<std::uint32_t>(image.height()),
  };
  result.png.append(std::as_bytes(std::span{encoded.constData(), static_cast<std::size_t>(encoded.size())}), AttachmentLimits::maximum_png_bytes);

  return result;
}

void unchangedExtentsPreservePremultipliedPixels(ApplicationAllocator &memory) {
  constexpr int width = 2;
  constexpr int height = 3;
  const QImage image{small_pixels.data(), width, height, width * channels, QImage::Format_RGBA8888};
  auto capture = captured(memory, image);
  const auto preview = qt::AttachmentPreview::decode(memory, capture);
  require(preview.sequence == capture.request.capture.id && preview.thumbnail.size() == image.size() && preview.full.size() == image.size(), "small previews must keep the source extent and exact sequence");
  for (const auto *pixels : {&preview.thumbnail, &preview.full}) {
    for (std::size_t index = 0; index < small_pixels.size(); ++index) {
      const auto alpha = small_pixels[(index / channels * channels) + channels - 1];
      const auto expected = index % channels == channels - 1 ? small_pixels[index] : ((static_cast<std::uint32_t>(small_pixels[index]) * alpha) + half_channel) / maximum_channel;
      require(pixels->constBits()[index] == expected, "unchanged image extents must preserve exact premultiplied RGBA");
    }
  }

  const QImage retained = preview.full;
  capture.png.clear();
  require(retained.constBits()[0] == half_channel + 1, "the render image must retain its pixels after PNG release");
}

void extremeAspectRatiosRemainBounded(ApplicationAllocator &memory) {
  QImage image{static_cast<int>(thin_width), 1, QImage::Format_RGBA8888};
  require(!image.isNull(), "the thin source must fit the explicit pixel quota");
  image.fill(Qt::red);
  const auto capture = captured(memory, image);
  const auto preview = qt::AttachmentPreview::decode(memory, capture);
  require(preview.thumbnail.size() == QSize{static_cast<int>(AttachmentPreviewSize::thumbnail_side), 1}, "very wide images must retain one thumbnail row");
  require(preview.full.size() == QSize{static_cast<int>(AttachmentPreviewSize::full_side), 1}, "very wide images must retain one modal row");
}

}

int main(int argc, char **argv) try {
  const QCoreApplication application{argc, argv};
  ApplicationAllocator memory;
  unchangedExtentsPreservePremultipliedPixels(memory);
  extremeAspectRatiosRemainBounded(memory);

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
