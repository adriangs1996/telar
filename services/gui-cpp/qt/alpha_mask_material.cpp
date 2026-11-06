#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif


#include "alpha_mask_material.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include <array>
#include <cstddef>
#include <cstdint>
#include <optional>
#include <string_view>
#include "physical_pixel_matrix.hpp"
#include <QByteArray>
#include <QSGMaterial>
#include <QSGMaterialShader>
#include <QSGRendererInterface>
#include <QSGTexture>
#include <QString>
#include <QtCore/qlogging.h>
#include <QtCore/qtypes.h>
#include <QtQuick/qsgmaterialtype.h>
#include <cstring>
#include <memory>
#include <tuple>



import telar.gui.core.metrics;

namespace telar::gui::qt {
namespace {
struct MaskUniforms {
  static constexpr std::size_t matrix_side = 4;
  std::array<float, matrix_side * matrix_side> matrix{};
  std::array<float, 4> foreground{};
  float opacity = 1;
};

class MaskShader final : public QSGMaterialShader {
public:
  MaskShader(AlphaMaskSampling sampling, AlphaMaskBlend blend) {
    setShaderFileName(VertexStage, QStringLiteral(":/telar/shaders/alpha_mask.vert.qsb"));
    const auto prefix = blend == AlphaMaskBlend::straight ? QStringLiteral(":/telar/shaders/straight/") : QStringLiteral(":/telar/shaders/");
    setShaderFileName(FragmentStage, prefix + (sampling == AlphaMaskSampling::stable_nearest ? QStringLiteral("nearest_alpha_mask.frag.qsb") : QStringLiteral("alpha_mask.frag.qsb")));
    if (blend == AlphaMaskBlend::straight) {
      setFlag(UpdatesGraphicsPipelineState);
    }
  }

  bool updateUniformData(RenderState &state, QSGMaterial *new_material, QSGMaterial *old_material) override;
  void updateSampledImage(RenderState &state, int binding, QSGTexture **texture, QSGMaterial *new_material, QSGMaterial *old_material) override;
  bool updateGraphicsPipelineState(RenderState &state, GraphicsPipelineState *pipeline, QSGMaterial *material, QSGMaterial *last) override;
};

bool MaskShader::updateUniformData(RenderState &state, QSGMaterial *new_material, QSGMaterial *old_material) {
  auto &buffer = *state.uniformData();
  if (buffer.size() < static_cast<qsizetype>(sizeof(MaskUniforms))) {
    qFatal("Curve mask uniform buffer is too small");
  }

  bool changed = false;
  if (state.isMatrixDirty() || old_material == nullptr) {
    const auto matrix = physicalPixelMatrix(state);
    std::memcpy(buffer.data() + offsetof(MaskUniforms, matrix), matrix.constData(), sizeof(MaskUniforms::matrix));
    changed = true;
  }

  if (state.isOpacityDirty() || old_material == nullptr) {
    const auto opacity = state.opacity();
    std::memcpy(buffer.data() + offsetof(MaskUniforms, opacity), &opacity, sizeof(opacity));
    changed = true;
  }

  const auto &material = dynamic_cast<const AlphaMaskMaterial &>(*new_material);
  const auto color = material.foreground();
  const auto alpha = material.blend() == AlphaMaskBlend::straight ? 1 : color.a;
  const std::array<float, 4> foreground{color.r * alpha, color.g * alpha, color.b * alpha, color.a};
  std::array<float, 4> previous_foreground{};
  const auto material_changed = new_material != old_material || state.dirtyStates().testFlag(RenderState::DirtyCachedMaterialData);
  if (!material_changed) {
    std::memcpy(previous_foreground.data(), buffer.constData() + offsetof(MaskUniforms, foreground), sizeof(previous_foreground));
  }

  if (material_changed || previous_foreground != foreground) {
    std::memcpy(buffer.data() + offsetof(MaskUniforms, foreground), foreground.data(), sizeof(foreground));
    changed = true;
  }

  return changed;
}

void MaskShader::updateSampledImage(RenderState &state, int binding, QSGTexture **texture, QSGMaterial *new_material, QSGMaterial *old_material) {
  constexpr int alpha_binding = 1;
  if (binding == alpha_binding) {
    auto &image = dynamic_cast<const AlphaMaskMaterial &>(*new_material).texture();
    if (new_material != old_material || image.isAtlasTexture()) {
      image.commitTextureOperations(state.rhi(), state.resourceUpdateBatch());
    }

    *texture = &image;
  }
}

bool MaskShader::updateGraphicsPipelineState([[maybe_unused]] RenderState &state, GraphicsPipelineState *pipeline, [[maybe_unused]] QSGMaterial *material, [[maybe_unused]] QSGMaterial *last) {
  pipeline->blendEnable = true;
  pipeline->srcColor = GraphicsPipelineState::SrcAlpha;
  pipeline->dstColor = GraphicsPipelineState::OneMinusSrcAlpha;
  pipeline->separateBlendFactors = true;
  pipeline->srcAlpha = GraphicsPipelineState::One;
  pipeline->dstAlpha = GraphicsPipelineState::OneMinusSrcAlpha;

  return true;
}

}

AlphaMaskMaterial::AlphaMaskMaterial(QSGTexture &texture, Color foreground, AlphaMaskSampling sampling, AlphaMaskBlend blend) noexcept
    : texture_(texture),
      foreground_(foreground),
      sampling_(sampling),
      blend_(blend) {
  setFlag(Blending);
}

QSGMaterialType *AlphaMaskMaterial::type() const {
  constexpr std::size_t sampling_modes = 2;
  constexpr std::size_t blend_modes = 2;
  static std::array<QSGMaterialType, sampling_modes * blend_modes> material_types;

  return &material_types[(static_cast<std::size_t>(blend_) * sampling_modes) + static_cast<std::size_t>(sampling_)];
}

QSGMaterialShader *AlphaMaskMaterial::createShader([[maybe_unused]] QSGRendererInterface::RenderMode render_mode) const {
  return std::make_unique<MaskShader>(sampling_, blend_).release();
}

int AlphaMaskMaterial::compare(const QSGMaterial *other) const {
  const auto &right = dynamic_cast<const AlphaMaskMaterial &>(*other);
  const auto left_key = std::tuple{blend_, sampling_, texture_.comparisonKey(), texture_.filtering(), foreground_.r, foreground_.g, foreground_.b, foreground_.a};
  const auto right_key = std::tuple{right.blend_, right.sampling_, right.texture_.comparisonKey(), right.texture_.filtering(), right.foreground_.r, right.foreground_.g, right.foreground_.b, right.foreground_.a};
  if (left_key < right_key) {
    return -1;
  }
  return left_key == right_key ? 0 : 1;
}

QSGTexture &AlphaMaskMaterial::texture() const noexcept {
  return texture_;
}

Color AlphaMaskMaterial::foreground() const noexcept {
  return foreground_;
}

AlphaMaskBlend AlphaMaskMaterial::blend() const noexcept {
  return blend_;
}

void AlphaMaskMaterial::setForeground(Color foreground) noexcept {
  foreground_ = foreground;
}

}
