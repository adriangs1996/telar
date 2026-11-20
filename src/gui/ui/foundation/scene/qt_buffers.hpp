#pragma once

#include <QByteArray>
#include <QImage>
#include <QMatrix4x4>
#include <QSGGeometry>
#include <algorithm>
#include <cstddef>
#include <span>

// Spans over the buffers Qt hands out as raw pointers: the one place the two meet.
namespace telar::gui::qt {

  inline constexpr std::size_t matrix_values = 16;

  inline std::span<const float, matrix_values> matrixValues(const QMatrix4x4& matrix) noexcept {
#pragma clang unsafe_buffer_usage begin
    return std::span<const float, matrix_values>{matrix.constData(), matrix_values};
#pragma clang unsafe_buffer_usage end
  }

  // The first `count` vertices of a geometry whose vertices are `Vertex`.
  template <typename Vertex>
  std::span<Vertex> geometryVertices(QSGGeometry& geometry, std::size_t count) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {static_cast<Vertex*>(geometry.vertexData()), count};
#pragma clang unsafe_buffer_usage end
  }

  inline std::span<uchar> imageBytes(QImage& image) {
#pragma clang unsafe_buffer_usage begin
    return {image.bits(), static_cast<std::size_t>(image.sizeInBytes())};
#pragma clang unsafe_buffer_usage end
  }

  // The pixels of an image that stays shared: constBits() never detaches it, as bits() would.
  inline std::span<const uchar> imageBytes(const QImage& image) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {image.constBits(), static_cast<std::size_t>(image.sizeInBytes())};
#pragma clang unsafe_buffer_usage end
  }

  inline std::span<uchar> imageLine(QImage& image, int row) {
#pragma clang unsafe_buffer_usage begin
    return {image.scanLine(row), static_cast<std::size_t>(image.bytesPerLine())};
#pragma clang unsafe_buffer_usage end
  }

  // Copies bytes to a fixed place of a shader's uniform buffer, which the caller checked is large enough.
  template <std::size_t Offset, std::size_t Size>
  void writeUniform(QByteArray& buffer, std::span<const std::byte, Size> bytes) noexcept {
    std::ranges::copy(bytes, std::as_writable_bytes(std::span<char>{buffer}.subspan<Offset, Size>()).begin());
  }

}
