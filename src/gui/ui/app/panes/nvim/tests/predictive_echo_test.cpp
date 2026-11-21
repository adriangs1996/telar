#include "ui/app/panes/nvim/predictive_echo.hpp"
#include <array>
#include <string_view>

import telar.testing;

namespace {

  using telar::gui::PredictiveEcho;
  using telar::testing::check;

  constexpr PredictiveEcho::Place start{.grid = 2, .row = 4, .column = 10};

  // A row of cells with `text` from column ten on.
  std::array<char32_t, 40> row(std::u32string_view text) {
    std::array<char32_t, 40> cells{};

    cells.fill(U' ');
    std::ranges::copy(text, cells.begin() + start.column);
    return cells;
  }

  // An echo that has seen one round trip of `link_ms`.
  PredictiveEcho measured(double link_ms) {
    PredictiveEcho echo;

    echo.sent(0);
    echo.confirm(link_ms, start, row(U""));
    return echo;
  }

  void localLinkShowsNothingAhead() {
    auto echo = measured(0.3);

    check(!echo.active() && !echo.predict(U'a', start, true) && echo.pending().empty(), "a key answered within a refresh is not guessed");
  }

  void slowLinkShowsLettersUntilTheirFrame() {
    auto echo = measured(80);

    check(echo.active() && echo.linkMs() == 80);
    check(!echo.predict(U'a', start, false), "only insert mode types what its keys say");
    check(!echo.predict(U'\t', start, true) && !echo.predict(U'\x1b', start, true) && !echo.predict(U'語', start, true), "only a letter that takes one cell");
    check(echo.predict(U'h', start, true) && echo.predict(U'o', start, true) && echo.predict(U'l', start, true));
    check(echo.pending() == U"hol" && echo.origin() == start, "the letters wait from where the cursor was");

    // The frame of the first two keys: they are the editor's now, the third still ahead.
    echo.confirm(160, {.grid = 2, .row = 4, .column = 12}, row(U"ho"));
    check(echo.pending() == U"l" && echo.origin().column == 12);
    check(echo.predict(U'a', {.grid = 2, .row = 4, .column = 12}, true) && echo.pending() == U"la");
    echo.confirm(240, {.grid = 2, .row = 4, .column = 14}, row(U"hola"));
    check(echo.pending().empty() && echo.active(), "what the frames carried is no longer ahead");
  }

  void frameThatSaysOtherwiseWins() {
    auto echo = measured(80);

    check(echo.predict(U'(', start, true));
    // The editor closed the pair and the frame shows both: the guess was right as far as it went.
    echo.confirm(160, {.grid = 2, .row = 4, .column = 11}, row(U"()"));
    check(echo.pending().empty() && echo.active());
    check(echo.predict(U'j', {.grid = 2, .row = 4, .column = 11}, true) && echo.predict(U'k', {.grid = 2, .row = 4, .column = 11}, true));
    // `jk` left insert mode: the cursor went back and nothing was typed.
    echo.confirm(240, {.grid = 2, .row = 4, .column = 10}, row(U"()"));
    check(echo.pending().empty(), "a frame that says otherwise drops the guess");
    check(echo.predict(U'x', start, true));
    echo.confirm(320, {.grid = 2, .row = 5, .column = 0}, row(U""));
    check(echo.pending().empty(), "as one with the cursor on another row does");
  }

  void wrongGuessesStopTheGuessing() {
    auto echo = measured(80);

    for (int miss = 0; miss < 3; ++miss) {
      check(echo.active() && echo.predict(U'a', start, true));
      echo.confirm(100, {.grid = 2, .row = 4, .column = 11}, row(U"z"));
    }

    check(!echo.active() && !echo.predict(U'a', start, true), "a pane whose guesses fail stops guessing");
  }

  void unrelatedFramesKeepTheLettersAWhile() {
    auto echo = measured(80);

    check(echo.predict(U'a', start, true));
    echo.confirm(100, start, row(U""));
    echo.confirm(110, start, row(U""));
    check(echo.pending() == U"a", "a frame drawn before the key was read confirms nothing and drops nothing");
    echo.confirm(120, start, row(U""));
    check(echo.pending().empty(), "but letters no frame ever carries do not stay");
    check(echo.predict(U'b', start, true));
    echo.clear();
    check(echo.pending().empty());
  }

  const telar::testing::Case case_local{"predictive_echo.local_link_shows_nothing_ahead", localLinkShowsNothingAhead};
  const telar::testing::Case case_slow{"predictive_echo.slow_link_shows_letters_until_their_frame", slowLinkShowsLettersUntilTheirFrame};
  const telar::testing::Case case_otherwise{"predictive_echo.frame_that_says_otherwise_wins", frameThatSaysOtherwiseWins};
  const telar::testing::Case case_wrong{"predictive_echo.wrong_guesses_stop_the_guessing", wrongGuessesStopTheGuessing};
  const telar::testing::Case case_unrelated{"predictive_echo.unrelated_frames_keep_the_letters_a_while", unrelatedFramesKeepTheLettersAWhile};

}
