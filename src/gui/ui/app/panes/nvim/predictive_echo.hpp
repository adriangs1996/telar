#pragma once

#include "telar_base/ds/values.hpp"
#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <span>
#include <string_view>

namespace telar::gui {

  // Letters typed in insert mode, shown at once where the way to the editor and back is slow,
  // each until the frame that carries it arrives. A frame that says otherwise wins: an
  // abbreviation, a mapping or a pair the editor closed is not what was guessed, and the
  // guess goes. Too many wrong guesses and the pane stops guessing.
  //
  // It keeps no clock and draws nothing: its owner says when a key left and when a frame
  // arrived, and shows `pending()` from `origin()`.
  class PredictiveEcho {
  public:
    // A cell of a grid of the editor.
    struct Place {
      std::uint32_t grid = 0;
      std::uint16_t row = 0;
      std::uint16_t column = 0;

      bool operator==(const Place&) const = default;
    };

    // The letters shown ahead at most: more than a slow link holds back is not typing.
    static constexpr std::size_t capacity = 48;
    // A screen refresh at sixty a second: a round trip shorter than this is not seen.
    static constexpr double default_refresh_ms = 1000.0 / 60.0;

    explicit constexpr PredictiveEcho(double refresh_ms = default_refresh_ms) noexcept
        : refresh_ms_(refresh_ms) {}

    // A key left for the editor at `now_ms`.
    constexpr void sent(double now_ms) noexcept {
      if (!awaiting_) {
        awaiting_ = now_ms;
      }
    }

    // Shows `character` ahead at `cursor` when it is one a slow link holds back: a letter that
    // takes one cell, typed in insert mode. Whether it is now shown.
    constexpr bool predict(char32_t character, Place cursor, bool insert_mode) noexcept {
      if (!active() || !insert_mode || !plain(character) || count_ == capacity) {
        return false;
      }

      if (count_ == 0) {
        origin_ = cursor;
        stalled_ = 0;
      }

      letters_.atMut(count_++) = character;
      return true;
    }

    // A frame arrived at `now_ms` with the cursor at `cursor`; `cells` is the row the letters
    // were shown on, one code point for each cell, as the frame left it.
    constexpr void confirm(double now_ms, Place cursor, std::span<const char32_t> cells) noexcept {
      if (awaiting_) {
        const auto sample = std::max(0.0, now_ms - *awaiting_);

        // The same smoothing the runtime gives a remote shell's link.
        link_ms_ = link_ms_ == 0 ? sample : (link_ms_ * kept) + (sample * (1 - kept));
        awaiting_ = ds::none;
      }

      if (count_ == 0) {
        return;
      }

      if (cursor.grid != origin_.grid || cursor.row != origin_.row || cursor.column < origin_.column) {
        miss();
        return;
      }

      const auto applied = std::min<std::size_t>(cursor.column - origin_.column, count_);

      // The frame is of something else, as one drawn before the keys were read is.
      if (applied == 0) {
        if (++stalled_ == most_stalled) {
          miss();
        }

        return;
      }

      for (std::size_t index = 0; index < applied; ++index) {
        const auto column = static_cast<std::size_t>(origin_.column) + index;
        if (column >= cells.size() || cells[column] != letters_[index]) {
          miss();
          return;
        }
      }

      hits_ += applied;
      std::ranges::copy(letters_.view().subspan(applied, count_ - applied), letters_.viewMut().begin());
      count_ -= applied;
      origin_.column = static_cast<std::uint16_t>(origin_.column + applied);
      stalled_ = 0;
    }

    // Insert mode ended, or the pane lost the keys: nothing is ahead of the editor any more.
    constexpr void clear() noexcept {
      count_ = 0;
      stalled_ = 0;
    }

    // The letters shown ahead, from `origin()` on, one cell each.
    [[nodiscard]] constexpr std::u32string_view pending() const noexcept {
      return {letters_.data(), count_};
    }

    [[nodiscard]] constexpr Place origin() const noexcept {
      return origin_;
    }

    // The round trip of a key, smoothed; zero before the first.
    [[nodiscard]] constexpr double linkMs() const noexcept {
      return link_ms_;
    }

    // Whether letters are shown ahead now: the link is slower than a refresh, and the guesses
    // have mostly been right.
    [[nodiscard]] constexpr bool active() const noexcept {
      return !disabled_ && link_ms_ > refresh_ms_;
    }

  private:
    static constexpr double kept = 0.7;
    static constexpr unsigned most_stalled = 3;
    static constexpr std::size_t fewest_misses = 3;
    // A guess in four wrong is too many to keep guessing.
    static constexpr std::size_t tolerated = 4;

    // A letter that takes one cell and that no editor reads as a command: printable ASCII and
    // the Latin letters after it.
    [[nodiscard]] static constexpr bool plain(char32_t character) noexcept {
      constexpr char32_t first_ascii = 0x20;
      constexpr char32_t last_ascii = 0x7e;
      constexpr char32_t first_latin = 0xa1;
      constexpr char32_t last_latin = 0x24f;

      return (character >= first_ascii && character <= last_ascii) || (character >= first_latin && character <= last_latin);
    }

    constexpr void miss() noexcept {
      ++misses_;
      clear();
      disabled_ = misses_ >= fewest_misses && misses_ * tolerated >= hits_ + misses_;
    }

    double refresh_ms_;
    double link_ms_ = 0;
    ds::Option<double> awaiting_;
    ds::Array<char32_t, capacity> letters_{};
    std::size_t count_ = 0;
    Place origin_;
    unsigned stalled_ = 0;
    std::size_t hits_ = 0;
    std::size_t misses_ = 0;
    bool disabled_ = false;
  };

}
