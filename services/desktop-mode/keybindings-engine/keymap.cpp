#include "keymap.hpp"
#include <algorithm>
#include <stdexcept>

namespace keybindings {
  namespace {
    Chord requireChord(std::string_view text) {
      const auto parsed = parseChord(text);

      if (!parsed) {
        throw std::runtime_error(parsed.error());
      }

      return *parsed;
    }
  } // namespace

  bool Keymap::Range::empty() const noexcept {
    return begin == end;
  }

  std::span<const Chord> Keymap::Entry::sequence() const noexcept {
    return {keys.data(), length};
  }

  Keymap::Keymap(std::string_view prefix, std::span<const Binding> bindings) {
    if (bindings.size() > maxBindings) {
      throw std::runtime_error("Too many shortcuts (maximum 256)");
    }

    const Chord prefix_key = requireChord(prefix);

    if (!prefix_key.hasCommandModifier()) {
      throw std::runtime_error("Shortcut prefix requires Ctrl, Alt or Command/Super");
    }

    entries_.reserve(bindings.size());

    for (const auto &binding : bindings) {
      if (binding.keys.empty() || binding.keys.size() > maxSequenceLength || binding.action == 0) {
        throw std::runtime_error("A shortcut requires 1 to 5 keys and a nonzero action ID");
      }

      Entry entry{.length = binding.keys.size(), .action = binding.action};

      for (std::size_t index = 0; index < binding.keys.size(); ++index) {
        entry.keys[index] = requireChord(binding.keys[index]);
      }

      if (entry.keys.front() == prefix_key) {
        if (entry.length == 1) {
          throw std::runtime_error("Shortcut prefix requires a suffix");
        }
      } else if (entry.length != 1 || !entry.keys.front().hasCommandModifier()) {
        throw std::runtime_error("A global shortcut requires one modified chord");
      }

      entries_.push_back(entry);
    }

    std::ranges::sort(entries_, [](const Entry &left, const Entry &right) {
      return std::ranges::lexicographical_compare(left.sequence(), right.sequence());
    });

    for (std::size_t index = 1; index < entries_.size(); ++index) {
      const auto previous = entries_[index - 1].sequence();
      const auto current = entries_[index].sequence();
      const auto shared = std::min(previous.size(), current.size());

      if (std::ranges::equal(previous.first(shared), current.first(shared))) {
        throw std::runtime_error(previous.size() == current.size() ? "Duplicate shortcut"
                                                                   : "Ambiguous shortcut prefix");
      }
    }
  }

  Keymap::Range Keymap::all() const noexcept {
    return {0, entries_.size()};
  }

  Keymap::Range Keymap::match(Range candidates, std::size_t depth, Chord key) const noexcept {
    const auto first = entries_.begin() + candidates.begin;
    const auto last = entries_.begin() + candidates.end;
    const auto range = std::ranges::equal_range(first, last, key, {}, [depth](const Entry &entry) {
      return entry.keys[depth];
    });

    return {static_cast<std::size_t>(range.begin() - entries_.begin()),
            static_cast<std::size_t>(range.end() - entries_.begin())};
  }

  std::uint64_t Keymap::action(Range candidates, std::size_t depth) const noexcept {
    if (candidates.empty()) {
      return 0;
    }

    const auto &entry = entries_[candidates.begin];
    return entry.length == depth ? entry.action : 0;
  }
} // namespace keybindings
