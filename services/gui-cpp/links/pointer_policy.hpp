#pragma once

#include "link_text.hpp"
#include <cstdint>
#include <optional>

namespace telar::gui {

struct LinkModifiers {
  bool native = false;
  bool shift = false;
  bool alt = false;

  bool operator==(const LinkModifiers &) const = default;
};

enum class LinkAffordance : std::uint8_t {
  text,
  pointer,
  link,
};

enum class LinkButton : std::uint8_t {
  left,
  middle,
  right,
};

enum class LinkPress : std::uint8_t {
  passthrough,
  arm_shared,
  arm_exclusive,
  copy,
  discard,
};

struct LinkPressInput {
  LinkButton button = LinkButton::left;
  LinkModifiers modifiers{};
  bool child_tracking = false;
  bool has_link = false;
  bool openable = false;
  bool frame_presented = false;
};

class LinkPointerPolicy {
public:
  [[nodiscard]] static constexpr LinkAffordance hover(std::optional<LinkScheme> scheme, LinkModifiers modifiers, bool eligible = true) noexcept {
    if (!eligible || !scheme) {
      return LinkAffordance::text;
    }

    if (modifiers.alt) {
      return LinkAffordance::pointer;
    }

    return *scheme == LinkScheme::path && !modifiers.native ? LinkAffordance::text : LinkAffordance::link;
  }

  [[nodiscard]] static constexpr LinkPress press(LinkPressInput input) noexcept {
    if (!input.has_link || input.button == LinkButton::middle) {
      return LinkPress::passthrough;
    }

    if (input.button == LinkButton::right) {
      return input.frame_presented ? LinkPress::copy : LinkPress::discard;
    }

    if (input.child_tracking && !input.modifiers.shift) {
      return LinkPress::passthrough;
    }

    if (input.modifiers.native) {
      return input.openable ? LinkPress::arm_exclusive : LinkPress::discard;
    }

    return input.openable ? LinkPress::arm_shared : LinkPress::passthrough;
  }
};

}
