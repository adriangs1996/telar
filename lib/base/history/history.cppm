module;
#include "tbc/annotations.hpp"

export module telar.base.history;

import std;
import telar.base.ds;

// Interface: telar_base/history/search_policy.cppm
export {
  namespace telar::runtime {

    inline constexpr unsigned char asciiLower(unsigned char byte) noexcept {
      return byte >= 'A' && byte <= 'Z' ? byte + ('a' - 'A') : byte;
    }

    // The simple case fold the history's search reads text with, the same for a query of any
    // length: ASCII, Latin-1, Latin Extended-A, Greek, Cyrillic, Armenian, Georgian, Latin
    // Extended Additional, the letterlike signs and the fullwidth forms. A character it does not
    // fold is itself. No character folds to a longer UTF-8 sequence than its own.
    std::uint32_t historyFold(std::uint32_t character) noexcept;

    // `text` folded into `out`, UTF-8 in and out, which must hold text.size() bytes; a byte that
    // starts no character is copied. The bytes written.
    std::size_t historyFold(std::string_view text, std::span<char> out) noexcept;

    // How well `query` matches `command` as a subsequence of folded characters; none when it does
    // not.
    ds::Option<std::uint32_t> historyScore(std::string_view command, std::string_view query) noexcept;

    std::string_view historyGroup(std::string_view command) noexcept;

    // A command's output without the shell integration's marks, OSC 133 and OSC 6973, which carry
    // the pane's token: what the history keeps must never hold it. Fed in pieces as the output
    // arrives; the start of a sequence split between pieces is held until it is told apart.
    class IntegrationMarkFilter {
    public:
      // Hands `keep` each run of `bytes`, and of what earlier pieces held, that is not a mark.
      template <typename Keep>
      TBC_GENERIC inline void feed(std::span<const std::uint8_t> bytes, Keep&& keep) {
        std::size_t index = 0;

        while (index < bytes.size()) {
          if (state_ == State::ground) {
            const auto rest = bytes.subspan(index);
            const auto found = std::ranges::find(rest, escape);
            const auto run = static_cast<std::size_t>(found - rest.begin());

            if (run != 0) {
              keep(rest.first(run));
            }

            index += run;
            if (found == rest.end()) {
              return;
            }
          }

          const auto byte = bytes[index];

          switch (step(byte)) {
          case Step::consumed:
            ++index;
            break;
          case Step::release:
            if (held_count_ != 0) {
              keep(std::span<const std::uint8_t>{held_.data(), held_count_});
            }

            held_count_ = 0;
            break;
          }
        }
      }

      // Forgets a sequence that was being read, as the next command's output starts.
      void reset() noexcept;

    private:
      enum class State : std::uint8_t {
        ground,
        escape,
        number,
        mark,
        mark_escape,
      };

      // What a byte did: read, or the bytes held are not a mark, to be kept before it is read.
      enum class Step : std::uint8_t {
        consumed,
        release,
      };

      static constexpr std::uint8_t escape = 0x1b;
      // ESC ] and the four digits of 6973.
      static constexpr std::size_t held_capacity = 6;

      Step step(std::uint8_t byte) noexcept;

      State state_ = State::ground;
      ds::Array<std::uint8_t, held_capacity> held_{};
      std::size_t held_count_ = 0;
      std::uint32_t number_ = 0;
    };

  }
}
