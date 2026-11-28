module telar.gui.features.prompt;

import std;

import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  ds::Option<std::size_t> typoDistance(std::string_view typed, std::string_view known, std::size_t most) noexcept {
    if (typed.size() > longest_correction || known.size() > longest_correction) {
      return ds::none;
    }

    if ((typed.size() > known.size() ? typed.size() - known.size() : known.size() - typed.size()) > most) {
      return ds::none;
    }

    // Three rows of the table: two back for a swap, the one before, and the one being filled.
    using Row = ds::Array<std::size_t, longest_correction + 1>;
    Row before_last{};
    Row last{};
    Row current{};

    for (std::size_t column = 0; column <= known.size(); ++column) {
      last.atMut(column) = column;
    }

    for (std::size_t row = 1; row <= typed.size(); ++row) {
      current.atMut(0) = row;
      auto smallest = row;

      for (std::size_t column = 1; column <= known.size(); ++column) {
        const std::size_t cost = typed[row - 1] == known[column - 1] ? 0 : 1;
        auto value = std::min({last[column] + 1, current[column - 1] + 1, last[column - 1] + cost});

        if (row > 1 && column > 1 && typed[row - 1] == known[column - 2] && typed[row - 2] == known[column - 1]) {
          value = std::min(value, before_last[column - 2] + 1);
        }

        current.atMut(column) = value;
        smallest = std::min(smallest, value);
      }

      // Every way on is already further than allowed.
      if (smallest > most) {
        return ds::none;
      }

      before_last = last;
      last = current;
    }

    const auto distance = last[known.size()];

    return distance <= most ? ds::Option{distance} : ds::none;
  }

  Closest::Closest(tbc::val_a<std::string_view> typed) noexcept
      : typed_(typed) {
    // Past four characters a word holds two typos before it reads as another word.
    constexpr std::size_t short_word = 4;

    most_ = typed.size() <= short_word ? 1 : 2;
  }

  void Closest::offer(tbc::val_a<std::string_view> command) noexcept {
    if (command.empty() || command == typed_) {
      return;
    }

    const auto distance = typoDistance(typed_, command, most_);
    if (distance && (best_.empty() || *distance < distance_)) {
      best_ = command;
      distance_ = *distance;
    }
  }

  tbc::val_a<std::string_view> Closest::best() const noexcept {
    return best_;
  }

}
