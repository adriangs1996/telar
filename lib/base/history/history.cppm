export module telar.base.history;

import std;

// Interface: telar_base/history/search_policy.cppm
export {
  namespace telar::runtime {

    inline constexpr unsigned char asciiLower(unsigned char byte) noexcept {
      return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
    }

    std::optional<std::uint32_t> historyScore(std::string_view command, std::string_view query) noexcept;

    std::string_view historyGroup(std::string_view command) noexcept;

  }
}
