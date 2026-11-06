#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QtQuick/qsgmaterialtype.h>

#pragma once


import telar.gui.core.metrics;

namespace telar::gui::qt {

enum class AlphaMaskSampling : unsigned char {
  standard,
  stable_nearest,
};

enum class AlphaMaskBlend : unsigned char {
  premultiplied,
  straight,
};

class AlphaMaskMaterial final : public QSGMaterial {
public:
  AlphaMaskMaterial(QSGTexture &texture, Color foreground, AlphaMaskSampling sampling = AlphaMaskSampling::standard, AlphaMaskBlend blend = AlphaMaskBlend::premultiplied) noexcept;
  [[nodiscard]] QSGMaterialType *type() const override;
  [[nodiscard]] QSGMaterialShader *createShader(QSGRendererInterface::RenderMode render_mode) const override;
  [[nodiscard]] int compare(const QSGMaterial *other) const override;
  [[nodiscard]] QSGTexture &texture() const noexcept;
  [[nodiscard]] Color foreground() const noexcept;
  [[nodiscard]] AlphaMaskBlend blend() const noexcept;
  void setForeground(Color foreground) noexcept;

private:
  QSGTexture &texture_;
  Color foreground_;
  AlphaMaskSampling sampling_ = AlphaMaskSampling::standard;
  AlphaMaskBlend blend_ = AlphaMaskBlend::premultiplied;
};

}
