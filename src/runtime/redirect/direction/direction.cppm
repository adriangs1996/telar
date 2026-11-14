module;

export module telar.runtime.redirect.direction;

import std;

import telar.vocabulary;

// Interface: redirect/direction.cppm
export {
  namespace telar::runtime::redirect {

    enum class Direction : Byte {
      outbound,
      inbound,
      both,
    };

    bool allowsIncoming(Direction direction) noexcept;

    bool allowsOutgoing(Direction direction) noexcept;

    std::string_view directionName(Direction direction);

    Direction parseDirection(std::string_view name);

  }
}
