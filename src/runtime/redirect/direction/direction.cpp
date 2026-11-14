module telar.runtime.redirect.direction;

namespace telar::runtime::redirect {

  bool allowsIncoming(Direction direction) noexcept {
    return direction == Direction::inbound || direction == Direction::both;
  }

  bool allowsOutgoing(Direction direction) noexcept {
    return direction == Direction::outbound || direction == Direction::both;
  }

  std::string_view directionName(Direction direction) {
    switch (direction) {
    case Direction::outbound:
      return "outbound";
    case Direction::inbound:
      return "inbound";
    case Direction::both:
      return "both";
    }

    throw std::invalid_argument{"Invalid redirect direction"};
  }

  Direction parseDirection(std::string_view name) {
    if (name == "outbound") {
      return Direction::outbound;
    }

    if (name == "inbound") {
      return Direction::inbound;
    }

    if (name == "both") {
      return Direction::both;
    }

    throw std::invalid_argument{"Redirect direction must be outbound, inbound or both"};
  }
}
