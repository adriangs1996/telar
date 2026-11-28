// How the history orders the commands a query matched: the match's score weighed by what the
// runtime knows of each command, and the template that names a command for the context of the
// one before it.
export module telar.base.history:rank;

import std;

export namespace telar::runtime {

  // What the runtime knows of a command besides how well it matched, each a prior on whether it
  // is the one the user wants.
  struct HistoryRankFeatures {
    // Since it last ran.
    std::uint64_t age_seconds = 0;
    // Times it ran.
    std::uint32_t run_count = 0;
    // It ran in the working directory, the workspace, the pane or session of the search.
    bool same_directory = false;
    bool same_workspace = false;
    bool same_session = false;
    // It failed when it last ran.
    bool recent_failure = false;
    // Times it ran right after the command that ran last where the search is: how often its
    // template followed that one's (historyTemplate).
    std::uint32_t follows_previous = 0;
    // Times the user picked it from the history.
    std::uint32_t selected_count = 0;
  };

  // The key a match sorts by, larger first, equal keys in the caller's (recency) order: `score`,
  // from historyMatch, times one factor its priors make together, in fixed point. Each prior
  // pulls by a share of the most they pull together:
  //   age             2^(-age / 1 day): 0.5 just run, 0.25 a day old, nothing from 10 days
  //   run_count       up to 0.5, by the logarithm of the count, full from 512 runs on
  //   follows_previous  up to 0.5, selected_count  up to 0.25, by their logarithms, full from 128
  //   same_directory  0.3           same_workspace, same_session  0.1 each
  // and the pull makes a factor from x1 (none) to x1.2 (every prior at its most), which a
  // recent failure takes to four fifths: x0.8 to x1.2 in all. So a match that scores half again
  // as much as another (each score counted one more than it is) ranks above it whatever their
  // priors, while among matches that score about alike the priors decide. The one added lets
  // priors order the commands of a query that scores none (only inverse terms).
  std::uint64_t historyRank(std::uint32_t score, const HistoryRankFeatures& features) noexcept;

  // mcfly's simplified_command: `command` as the shape of what it does, for counting which
  // command follows which. Its first two words, quoted text a `<str>` and a word with a `/`
  // outside quotes a `<path>`: `git commit -m "fix it"` is `git commit`, `cd ~/src` is
  // `cd <path>`, `echo 'hi there'` is `echo <str>`, quotes that follow each other one `<str>`.
  // Neither placeholder can be a word of a command, as `<` outside quotes is a redirection.
  // Writes at most out.size() bytes, cut between characters, and returns how many;
  // 2 * command.size() + 12 always holds it all.
  std::size_t historyTemplate(std::string_view command, std::span<char> out) noexcept;

}
