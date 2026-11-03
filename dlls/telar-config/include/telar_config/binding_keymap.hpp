#pragma once

#include "telar_config/key_chord.hpp"
#include "telar_config/limit_notices.hpp"

namespace telar::runtime::config {

class BindingKeymap {
public:
  struct Sequence {
    std::array<KeyChord, 2> keys{};
    std::size_t length = 0;
    bool prefixed = false;
  };

  void setPrefix(KeyChord prefix) noexcept {
    prefix_ = prefix;
    for (auto &binding : std::span{bindings_}.first(count_)) {
      if (binding.prefixed) {
        binding.keys[0] = prefix;
      }
    }
  }

  KeyChord prefix() const noexcept {
    return prefix_;
  }

  void clear() noexcept {
    count_ = 0;
  }

  void append(Sequence sequence) noexcept {
    bindings_[count_++] = sequence;
  }

  void report(LimitNotices &limits) const noexcept {
    std::size_t wanted = count_;
    for (const auto suffix : defaultSuffixes()) {
      const bool overridden = std::ranges::any_of(std::span{bindings_}.first(count_), [&](const Sequence &binding) {
        return binding.keys[0] == prefix_ && (binding.length == 1 || binding.keys[1] == suffix);
      });
      wanted += !overridden;
    }
    if (wanted > maximum_bindings) {
      limits.add({"config.max_bindings", "key bindings", maximum_bindings, wanted, {}});
    }
  }

  static constexpr std::size_t maximum_bindings = 256;

private:
  static constexpr std::array<KeyChord, 43> defaultSuffixes() noexcept {
    using Key = KeyChord::Key;
    constexpr auto shift = static_cast<unsigned>(KeyChord::Modifier::shift);
    constexpr auto alt = static_cast<unsigned>(KeyChord::Modifier::alt);
    return std::array<KeyChord, 43>{{
        {Key::character, '-'},
        {Key::character, '='},
        {Key::character, '%'},
        {Key::character, '"'},
        {Key::left},
        {Key::right},
        {Key::up},
        {Key::down},
        {Key::left, 0, shift},
        {Key::right, 0, shift},
        {Key::up, 0, shift},
        {Key::down, 0, shift},
        {Key::character, 'z'},
        {Key::character, 's'},
        {Key::left, 0, alt},
        {Key::right, 0, alt},
        {Key::character, 'w'},
        {Key::character, 'u'},
        {Key::character, 'N'},
        {Key::character, 'W'},
        {Key::character, 'x'},
        {Key::character, 'd'},
        {Key::character, '['},
        {Key::character, 'g'},
        {Key::character, '/'},
        {Key::character, 'f'},
        {Key::character, '?'},
        {Key::character, 'c'},
        {Key::character, 'n'},
        {Key::character, 'p'},
        {Key::character, '1'},
        {Key::character, '2'},
        {Key::character, '3'},
        {Key::character, '4'},
        {Key::character, '5'},
        {Key::character, '6'},
        {Key::character, '7'},
        {Key::character, '8'},
        {Key::character, '9'},
        {Key::character, 'T'},
        {Key::character, 'X'},
        {Key::character, ','},
        {Key::character, '.'},
    }};
  }

  KeyChord prefix_{KeyChord::Key::character, 'b', static_cast<unsigned>(KeyChord::Modifier::control)};
  std::array<Sequence, maximum_bindings> bindings_{};
  std::size_t count_ = 0;
};

}
