// "Did you mean": the known command closest to one the shell did not find, as a typo goes. Nothing
// here is exported: only the feature's own units name it.
export module telar.gui.features.prompt:correction;

import std;

import telar.base.ds;
import telar.tbc;

namespace telar::gui::features::prompt {

  // Longer words are not commands anyone mistypes: they are not compared.
  inline constexpr std::size_t longest_correction = 64;

  // How far `typed` is from `known` as typos go: a character added, dropped, replaced, or two
  // neighbours swapped each count one (the optimal string alignment distance). None past `most`.
  [[nodiscard]] ds::Option<std::size_t> typoDistance(std::string_view typed, std::string_view known, std::size_t most) noexcept;

  // The closest of the commands offered to a word the shell did not find: one typo away for a
  // word of up to four characters, two for a longer one, the first offered among equals.
  class Closest {
  public:
    explicit Closest(tbc::val_a<std::string_view> typed) noexcept;

    void offer(tbc::val_a<std::string_view> command) noexcept;

    // The command, while the ones offered live; empty when none was close.
    [[nodiscard]] tbc::val_a<std::string_view> best() const noexcept;

  private:
    tbc::val_a<std::string_view> typed_;
    std::size_t most_ = 0;
    tbc::val_a<std::string_view> best_;
    std::size_t distance_ = 0;
  };

}
