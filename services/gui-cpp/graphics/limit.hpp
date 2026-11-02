#pragma once

#include <cstdint>
#include <exception>

namespace telar::gui {

enum class GraphicsLimitKind : std::uint8_t {
  images,
  placements,
  chunks,
  bytes,
};

class GraphicsLimitError final : public std::exception {
public:
  explicit GraphicsLimitError(GraphicsLimitKind kind)
      : kind_(kind) {}

  [[nodiscard]] const char *what() const noexcept override {
    return name(kind_);
  }

  [[nodiscard]] GraphicsLimitKind kind() const noexcept {
    return kind_;
  }

  [[nodiscard]] static const char *name(GraphicsLimitKind kind) noexcept {
    switch (kind) {
    case GraphicsLimitKind::images:
      return "GraphicsImageLimitExceeded";
    case GraphicsLimitKind::placements:
      return "GraphicsPlacementLimitExceeded";
    case GraphicsLimitKind::chunks:
      return "GraphicsChunkLimitExceeded";
    case GraphicsLimitKind::bytes:
      return "GraphicsQuotaExceeded";
    }

    return "GraphicsQuotaExceeded";
  }

private:
  GraphicsLimitKind kind_;
};

}
