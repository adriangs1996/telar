module;
#include "tbc/annotations.hpp"

export module telar.gui.foundation.actions:binding;

import std;

import telar.config.client;
import telar.base.ds;

// Interface: input/binding.cppm
export {
  namespace telar::gui::inline foundation::inline actions {

    using runtime::config::KeyChord;

    struct BindingLimits {
      static constexpr std::size_t bindings = 256;
      static constexpr std::size_t keys = 5;
      static constexpr std::size_t physical_keys = 64;
      static constexpr std::uint64_t sequence_timeout_ns = std::uint64_t{1000} * 1000 * 1000;
    };

    int compareChords(KeyChord left, KeyChord right) noexcept;

    template <typename Action>
    struct TBC_GENERIC KeyBinding {
      ds::Array<KeyChord, BindingLimits::keys> keys{};
      std::size_t length = 0;
      Action action{};
      bool prefixed = false;

      [[nodiscard]] inline std::span<const KeyChord> sequence() const noexcept {
        return std::span{keys}.first(length);
      }

      [[nodiscard]] inline bool conflictsWith(const KeyBinding& other) const noexcept {
        const auto shared = std::min(length, other.length);

        return std::equal(keys.begin(), keys.begin() + shared, other.keys.begin());
      }
    };

    template <typename Action>
    class TBC_GENERIC BindingMap {
    public:
      struct Range {
        std::size_t begin = 0;
        std::size_t end = 0;
      };

      inline explicit BindingMap(std::span<const KeyBinding<Action>> bindings = {}) {
        if (bindings.size() > BindingLimits::bindings) {
          throw std::invalid_argument{"Too many key bindings"};
        }

        for (const auto& binding : bindings) {
          if (binding.length == 0 || binding.length > BindingLimits::keys) {
            throw std::invalid_argument{"A binding must contain one to five keys"};
          }

          bindings_.atMut(length_) = binding;
          order_.atMut(length_) = static_cast<std::uint16_t>(length_);
          ++length_;
        }

        const auto ordered = order_.viewMut().first(length_);

        std::ranges::sort(ordered, [this](auto left, auto right) {
          return std::lexicographical_compare(bindings_[left].sequence().begin(), bindings_[left].sequence().end(), bindings_[right].sequence().begin(), bindings_[right].sequence().end(), [](KeyChord first, KeyChord second) {
            return compareChords(first, second) < 0;
          });
        });

        for (std::size_t index = 1; index < length_; ++index) {
          if (at(index - 1).conflictsWith(at(index))) {
            throw std::invalid_argument{"Duplicate or ambiguous binding sequence"};
          }
        }
      }

      [[nodiscard]] inline std::size_t size() const noexcept {
        return length_;
      }

      [[nodiscard]] inline std::span<const KeyBinding<Action>> configured() const noexcept {
        return std::span{bindings_}.first(length_);
      }

      [[nodiscard]] inline const KeyBinding<Action>& at(std::size_t index) const noexcept {
        return bindings_[order_[index]];
      }

      [[nodiscard]] inline Range match(Range candidates, std::size_t depth, KeyChord key) const noexcept {
        const auto first = boundary(candidates, depth, key, false);
        const auto last = boundary({first, candidates.end}, depth, key, true);

        return {first, last};
      }

    private:
      [[nodiscard]] inline std::size_t boundary(Range range, std::size_t depth, KeyChord key, bool inclusive) const noexcept {
        while (range.begin < range.end) {
          const auto middle = range.begin + ((range.end - range.begin) / 2);
          const auto compared = compareChords(at(middle).keys[depth], key);
          if (compared < 0 || (inclusive && compared == 0)) {
            range.begin = middle + 1;
          } else {
            range.end = middle;
          }
        }

        return range.begin;
      }

      ds::Array<KeyBinding<Action>, BindingLimits::bindings> bindings_{};
      ds::Array<std::uint16_t, BindingLimits::bindings> order_{};
      std::size_t length_ = 0;
    };

  }
}
