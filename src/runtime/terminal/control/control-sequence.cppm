export module telar.runtime.terminal.control:sequence;

import std;

export namespace telar::runtime::control {

  enum class Kind : std::uint8_t {
    escape,
    csi,
    dcs,
    osc,
    apc,
  };

  enum class Ending : std::uint8_t {
    final_byte,
    escape,
    bell,
    c1,
  };

  struct Sequence {
    Kind kind;
    std::span<const std::uint8_t> bytes;
    Ending ending;

    std::string_view body() const noexcept;

    constexpr std::string_view terminator() const noexcept {
      return ending == Ending::bell ? "\a" : "\x1b\\";
    }
  };

}
