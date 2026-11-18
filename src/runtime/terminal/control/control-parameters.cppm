export module telar.runtime.terminal.control:parameters;

import std;
import telar.base.ds;

export namespace telar::runtime::control {

  std::string_view takeField(std::string_view& remaining, char separator = ';') noexcept;

  struct Parameters {
    static constexpr std::size_t capacity = 24;
    static constexpr std::size_t intermediate_capacity = 4;
    static constexpr unsigned maximum_digits = 255;
    static constexpr std::uint32_t maximum_value = std::numeric_limits<std::uint16_t>::max();

    std::array<std::uint16_t, capacity> values{};
    std::array<char, intermediate_capacity> intermediate{};
    std::size_t count = 0;
    std::size_t intermediate_count = 0;
    bool colon = false;
    char final = 0;

    constexpr std::string_view modifiers() const noexcept {
      return {intermediate.data(), intermediate_count};
    }

    static ds::Option<Parameters> parse(std::string_view body) noexcept;
  };

}
