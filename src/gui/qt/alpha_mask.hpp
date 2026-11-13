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
  AlphaMask(QImage alpha, std::unique_ptr<QSGTexture> texture)
      : alpha(std::move(alpha)),
        texture(std::move(texture)) {}

  const QImage alpha;
  const std::unique_ptr<QSGTexture> texture;
};

using AlphaMaskRef = QExplicitlySharedDataPointer<AlphaMask>;

}
