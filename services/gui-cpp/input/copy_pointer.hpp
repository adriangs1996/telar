#pragma once

#include "terminal/copy_grid.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

enum class CopyPointerKind : std::uint8_t {
  press,
  drag,
  release,
  wheel,
  move,
};

struct CopyPress {
  std::uint64_t pane_id = 0;
  CopyPoint position{};
  std::uint64_t now_ns = 0;
};

struct CopyPointerInput {
  std::uint64_t pane_id = 0;
  CopyPoint position{};
  CopyPointerKind kind = CopyPointerKind::press;
  bool left_button = true;
  bool inside = true;
  std::int32_t rows = 0;
};

struct CopyPointerOwner {
  std::uint64_t pane_id = 0;
  bool dragging = false;
};

struct CopyPointerAuthority {
  enum class Kind : std::uint8_t {
    unowned,
    missing,
    selection,
    keyboard,
  };

  Kind kind = Kind::unowned;
  bool dragging = false;
  bool inside = false;
  std::optional<CopyPoint> position = std::nullopt;
};

struct CopyPointerDecision {
  enum class Outcome : std::uint8_t {
    unowned,
    consumed,
    moved,
    exited,
  };

  Outcome outcome = Outcome::unowned;
  bool cancel = false;
  bool leave = false;
  std::optional<CopyPoint> motion = std::nullopt;
  std::optional<std::int32_t> vertical = std::nullopt;
};

inline CopyPointerDecision routeCopyPointer(const CopyPointerInput &input, const CopyPointerAuthority &authority) noexcept {
  using Kind = CopyPointerAuthority::Kind;
  using Outcome = CopyPointerDecision::Outcome;

  switch (authority.kind) {
  case Kind::unowned:
    return {};
  case Kind::missing:
    return {.outcome = Outcome::exited, .leave = true};
  case Kind::selection:
    if (authority.dragging && input.kind == CopyPointerKind::press && input.left_button) {
      return {.cancel = true};
    }

    if (!authority.dragging) {
      return {.cancel = input.kind == CopyPointerKind::press || input.kind == CopyPointerKind::wheel};
    }

    if (!input.left_button || (input.kind != CopyPointerKind::drag && input.kind != CopyPointerKind::release)) {
      return {.outcome = Outcome::consumed};
    }

    if (!authority.position) {
      return {.outcome = Outcome::consumed, .cancel = input.kind == CopyPointerKind::release};
    }

    return {.outcome = Outcome::moved, .motion = authority.position};
  case Kind::keyboard:
    if (input.kind == CopyPointerKind::wheel && authority.inside) {
      return {.outcome = Outcome::moved, .vertical = input.rows};
    }

    return {.outcome = Outcome::consumed};
  }

  return {};
}

}
