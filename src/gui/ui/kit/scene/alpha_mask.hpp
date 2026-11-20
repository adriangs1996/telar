#pragma once

#include <QExplicitlySharedDataPointer>
#include <QImage>
#include <QSGTexture>
#include <QSharedData>
#include <memory>
#include <utility>

namespace telar::gui::qt {

  class AlphaMask final : public QSharedData {
  public:
    AlphaMask(QImage mask, std::unique_ptr<QSGTexture> mask_texture)
        : alpha(std::move(mask)),
          texture(std::move(mask_texture)) {}

    const QImage alpha;
    const std::unique_ptr<QSGTexture> texture;
  };

  using AlphaMaskRef = QExplicitlySharedDataPointer<AlphaMask>;

}
