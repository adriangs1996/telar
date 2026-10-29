#pragma once

#include <QMatrix4x4>
#include <QRect>
#include <QSGMaterialShader>
#include <cmath>

namespace telar::gui::qt {

inline QMatrix4x4 physicalPixelMatrix(const QSGMaterialShader::RenderState &state) {
  const auto projection = state.projectionMatrix();
  const auto viewport = state.viewportRect();
  constexpr float clip_span = 2;
  const auto horizontal_scale = std::abs(projection(0, 0)) * static_cast<float>(viewport.width()) / clip_span;
  const auto vertical_scale = std::abs(projection(1, 1)) * static_cast<float>(viewport.height()) / clip_span;
  if (!projection.isAffine() || horizontal_scale <= 0 || vertical_scale <= 0) {
    return state.combinedMatrix();
  }

  const auto density = state.devicePixelRatio();
  const auto horizontal_correction = density / horizontal_scale;
  const auto vertical_correction = density / vertical_scale;
  QMatrix4x4 correction;
  correction(0, 0) = horizontal_correction;
  correction(1, 1) = vertical_correction;
  correction(0, 3) = projection(0, 3) * (1 - horizontal_correction);
  correction(1, 3) = projection(1, 3) * (1 - vertical_correction);

  return correction * state.combinedMatrix();
}

}
