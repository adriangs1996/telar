#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.history;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  // One arena for a test, as a thread of the runtime keeps one.
  std::unique_ptr<HistoryMatchArena> makeArena(HistorySearchPath path = HistorySearchPath::fast) {
    return std::make_unique<HistoryMatchArena>(path);
  }

  bool matches(std::string_view query, std::string_view command, HistoryMatchMode mode = HistoryMatchMode::fuzzy) {
    const auto arena = makeArena();
    return historyMatch(HistoryPattern{query, mode}, command, *arena).hasValue();
  }

  // `command` with what the match covers in brackets, as a client highlights it; empty when it
  // does not match.
  std::string highlighted(std::string_view query, std::string_view command, HistoryMatchMode mode = HistoryMatchMode::fuzzy) {
    const auto arena = makeArena();
    HistoryMatchRanges ranges;

    if (!historyMatch(HistoryPattern{query, mode}, command, *arena, &ranges)) {
      return {};
    }

    std::string out;
    std::size_t at = 0;

    for (const auto range : ranges.view()) {
      out.append(command.substr(at, range.begin - at));
      out += '[';
      out.append(command.substr(range.begin, range.end - range.begin));
      out += ']';
      at = range.end;
    }

    out.append(command.substr(at));
    return out;
  }

  // The commands that match, best first, the earlier of equal scores first, as the history
  // lists them.
  std::vector<std::string_view> ranked(std::string_view query, std::initializer_list<std::string_view> commands, HistoryMatchMode mode = HistoryMatchMode::fuzzy) {
    const auto arena = makeArena();
    const HistoryPattern pattern{query, mode};
    std::vector<std::pair<std::uint32_t, std::string_view>> scored;

    for (const auto command : commands) {
      if (const auto score = historyMatch(pattern, command, *arena)) {
        scored.emplace_back(*score, command);
      }
    }

    std::ranges::stable_sort(scored, std::ranges::greater{}, &std::pair<std::uint32_t, std::string_view>::first);

    std::vector<std::string_view> out;

    for (const auto& [score, command] : scored) {
      out.push_back(command);
    }

    return out;
  }

  // fzf's V2 finds the contiguous `ab` that a greedy scan, taking the first `a`, misses.
  void prefersTheContiguousRunOverTheFirstCharacter() {
    check(highlighted("ab", "a-xxxx-ab") == "a-xxxx-[ab]", "the match covers the contiguous pair");
    check(ranked("ab", {"axxxxxxb", "a-xxxx-ab"}) == std::vector<std::string_view>{"a-xxxx-ab", "axxxxxxb"}, "the contiguous pair ranks first");
    check(historyScore("a-xxxx-ab", "ab").valueOr(0) > historyScore("axxxxxxb", "ab").valueOr(0), "historyScore ranks it first too");
  }

  // A query of word starts finds the command whose words they start, above one that holds the
  // same letters in a row inside a word.
  void abbreviationsOfWordStartsRankAboveAnInnerRun() {
    check(highlighted("gcm", "git commit -m fix") == "[g]it [c]ommit -[m] fix");
    check(ranked("gcm", {"xgcmx", "git commit -m fix"}) == std::vector<std::string_view>{"git commit -m fix", "xgcmx"});
    check(highlighted("kgp", "kubectl get pods") == "[k]ubectl [g]et [p]ods");
  }

  // Equal scores keep the caller's order, the history's recency, as fzf's history scheme does.
  void equalScoresKeepTheCallersOrder() {
    check(ranked("make", {"make test", "make build", "make all"}) == std::vector<std::string_view>{"make test", "make build", "make all"});
    check(!HistoryPattern{"!wip"}.ranks() && HistoryPattern{"!wip git"}.ranks(), "only inverse terms leave the order alone");
    check(ranked("!wip", {"git b", "git a", "git wip"}) == std::vector<std::string_view>{"git b", "git a"});
  }

  // Every term must match, in any order; a fuzzy term is a subsequence, its characters in order.
  void spacesSeparateTermsThatMustAllMatch() {
    check(matches("push git", "git push origin"), "terms match in any order");
    check(!matches("git pull", "git push origin"), "every term must match");
    check(!matches("tig", "git"), "a fuzzy term keeps its order");
    check(matches("", "anything") && HistoryPattern{""}.empty(), "an empty query matches every command");
    check(highlighted("git push", "git push") == "[git] [push]");
    check(highlighted("gi t", "git") == "[git]", "ranges of adjacent terms join");
  }

  void quotedTermsMatchExactly() {
    check(matches("'push", "git push") && !matches("'push", "git pull --stash-h"), "'term is a substring");
    check(highlighted("'push", "git push --push") == "git [push] --push", "the occurrence on a word's start is taken");
    check(matches("'push'", "git push origin") && !matches("'push'", "git pushed"), "'term' is a word");
    check(matches("'it\\ pu", "git push") && !matches("'it\\ pu", "git stash pull"), "\\  is a space inside a term");
    check(matches("git\\ push", "git push") && !matches("git\\ push", "gitpush"), "an escaped space is a character to match");
  }

  void caretAndDollarAnchorTerms() {
    check(matches("^git", "  git status") && !matches("^git", "sudo git status"), "^term starts the command, past its spaces");
    check(matches(".rs$", "vim main.rs") && !matches(".rs$", "vim main.rs.bak"), "term$ ends it");
    check(matches("^ls$", "ls") && matches("^ls$", " ls ") && !matches("^ls$", "ls -la"), "^term$ is all of it");
    check(highlighted("^ls$", "ls") == "[ls]");
    check(matches("$", "echo $HOME") && !matches("$", "echo HOME"), "a lone $ is a character");
  }

  void bangInvertsATerm() {
    check(!matches("!wip", "git commit -m wip") && matches("!wip", "git commit"), "!term rejects what contains it");
    check(matches("git !^sudo", "git push") && !matches("git !^sudo", "sudo git push"), "!^term rejects what starts with it");
    check(matches("!.bak$", "main.rs") && !matches("!.bak$", "main.rs.bak"), "!term$ rejects what ends with it");
    check(highlighted("git !wip", "git push") == "[git] push", "an inverse term covers nothing");
  }

  void barMakesAlternatives() {
    check(matches("docker | podman", "podman ps") && matches("docker | podman", "docker ps") && !matches("docker | podman", "kubectl get"));
    check(matches("ps docker | podman", "podman ps") && !matches("ps docker | podman", "podman run"), "alternatives are one term of the and");
    check(matches("|", "a | b") && !matches("|", "a b"), "a bar with no term before it is a character");
  }

  // A term with a capital matches case for case; one without matches either case.
  void aCapitalMakesATermCaseSensitive() {
    check(matches("make", "Makefile") && matches("make", "make all"));
    check(matches("Make", "Makefile") && !matches("Make", "make all"));
    check(matches("Make file", "Makefile") && matches("file Make", "Makefile"), "each term decides for itself");
    check(matches("école", "ÉCOLE") && !matches("École", "école"), "past ASCII too");
  }

  // A term without diacritics matches the letters of a command without theirs; one with a
  // diacritic matches only it.
  void aTermWithoutDiacriticsMatchesAccentedLetters() {
    check(matches("cafe", "un café au lait") && matches("ecole", "ÉCOLE"));
    check(matches("café", "un café") && !matches("café", "un cafe"));
    check(matches("Cafe", "CAFÉ Cafè") && matches("dvorak", "dvořák"), "case and diacritics fold apart");
    check(highlighted("cafe", "un café") == "un [café]", "the range is the accented letter's bytes");
  }

  // A fuzzy term whose characters lie far apart, none on a word's start, is noise and no match.
  void scatteredCharactersAreNoMatch() {
    const std::string scattered = "a" + std::string(20, 'x') + "b" + std::string(20, 'x') + "c" + std::string(20, 'x') + "d";

    check(!matches("abcd", scattered), "characters twenty apart do not match");
    check(matches("abcd", "a-b-c-d") && matches("abcd", "xaxbxcxdx"), "characters close together do");
    check(historyScore(scattered, "abcd").hasValue(), "historyScore keeps every subsequence, as its pickers did");
  }

  void substringModeMatchesKeywordsAndRanksPrefixesFirst() {
    constexpr auto mode = HistoryMatchMode::substring;

    check(matches("push git", "git push", mode) && !matches("gp", "git push", mode), "keywords are substrings in any order");
    check(matches("'gp", "git push", mode), "'term is fuzzy");
    check(ranked("git", {"cd ~/git", "git status"}, mode) == std::vector<std::string_view>{"git status", "cd ~/git"}, "the command a keyword starts ranks first");
    check(ranked("status", {"git status --short -b", "status"}, mode).front() == "status");
  }

  void prefixAndExactModesTakeTheWholeQuery() {
    check(matches("git p", "git push", HistoryMatchMode::prefix) && matches("git p", "  git push", HistoryMatchMode::prefix));
    check(!matches("git p", "sudo git push", HistoryMatchMode::prefix) && !matches("p", "git push", HistoryMatchMode::prefix));
    check(matches("it pu", "git push", HistoryMatchMode::exact) && !matches("it pu", "git stash pull", HistoryMatchMode::exact));
    check(matches("'x", "a 'x", HistoryMatchMode::exact) && !matches("!x", "x", HistoryMatchMode::prefix), "no syntax");
    check(highlighted("t pu", "git push", HistoryMatchMode::exact) == "gi[t pu]sh");
  }

  // A single character takes its occurrence on a word's start, two take their best pair.
  void shortQueriesTakeTheBestOccurrence() {
    check(highlighted("p", "cp -r src dst push") == "cp -r src dst [p]ush");
    check(highlighted("st", "test start") == "test [st]art");
    check(ranked("st", {"test", "git status"}) == std::vector<std::string_view>{"git status", "test"});
  }

  // A window past what the arena holds is scored greedily, and still matches.
  void longCommandsStillMatch() {
    // An `a` at the start and the pair at the end: the window is the whole command.
    const auto far = "a " + std::string(20000, 'x') + " ab";

    check(highlighted("ab", far).ends_with(" [ab]"), "a window past the arena's characters");

    // Every letter forty times over: each row of the matrix spans the whole window.
    std::string wide;
    std::string alphabet;

    for (char letter = 'a'; letter <= 'z'; ++letter) {
      alphabet += letter;
    }

    for (int repeat = 0; repeat < 40; ++repeat) {
      for (const auto letter : alphabet) {
        wide += ' ';
        wide += letter;
        wide += '.';
      }
    }

    check(matches(alphabet, wide), "a window past the arena's cells");
    check(highlighted(alphabet, wide).starts_with(" [a]. [b]. [c]."), "scored greedily where it starts");
  }

  // The fast path (SIMD search, the short patterns' one pass) scores and covers what the
  // reference path does, for every kind of term.
  void theFastPathAgreesWithTheReference() {
    const auto fast = makeArena(HistorySearchPath::fast);
    const auto reference = makeArena(HistorySearchPath::reference);
    std::uint64_t state = 0x9e3779b97f4a7c15ULL;

    const auto next = [&](std::size_t bound) {
      state ^= state << 13U;
      state ^= state >> 7U;
      state ^= state << 17U;
      return static_cast<std::size_t>(state % bound);
    };

    constexpr std::array<std::string_view, 12> pieces{"git", " ", "push", "-", "Origin", "/", "src", "é", "main.rs", "x", "ab", "  "};
    constexpr std::array<std::string_view, 14> queries{"g", "x", "é", "gp", "ab", "Or", "gsr", "pushm", "e", "'push", "^git", "rs$", "srcab | gx", "!x git"};

    for (int round = 0; round < 400; ++round) {
      std::string command;

      for (auto count = next(40); count-- > 0;) {
        command += pieces[next(pieces.size())];
      }

      for (const auto query : queries) {
        const HistoryPattern pattern{query};
        HistoryMatchRanges fast_ranges;
        HistoryMatchRanges reference_ranges;
        const auto fast_score = historyMatch(pattern, command, *fast, &fast_ranges);
        const auto reference_score = historyMatch(pattern, command, *reference, &reference_ranges);
        const auto bare = historyMatch(pattern, command, *fast);

        check(fast_score == reference_score && bare == reference_score, "the same score");
        check(std::ranges::equal(fast_ranges.view(), reference_ranges.view(), {}, &HistoryMatchRange::begin, &HistoryMatchRange::begin), "the same ranges");
        check(std::ranges::equal(fast_ranges.view(), reference_ranges.view(), {}, &HistoryMatchRange::end, &HistoryMatchRange::end), "the same ranges");
      }
    }
  }

  // historyScore, which the pickers call, matches what it matched before: the query whole, as a
  // case insensitive subsequence.
  void historyScoreMatchesTheQueryWhole() {
    check(historyScore("anything", "") == 1U, "an empty query keeps every row with the same score");
    check(historyScore("alpha beta", "ALPHA") && historyScore("alpha", "lph") && !historyScore("alpha", "pa l"));
    check(historyScore("a | b", "a | b") && !historyScore("x", "!a"), "no syntax");
    check(!historyScore("cargo build", "xyz"));
  }

  const telar::testing::Case case_prefers_the_contiguous_run{"history_match.prefers_the_contiguous_run_over_the_first_character", prefersTheContiguousRunOverTheFirstCharacter};
  const telar::testing::Case case_abbreviations{"history_match.abbreviations_of_word_starts_rank_above_an_inner_run", abbreviationsOfWordStartsRankAboveAnInnerRun};
  const telar::testing::Case case_equal_scores{"history_match.equal_scores_keep_the_callers_order", equalScoresKeepTheCallersOrder};
  const telar::testing::Case case_spaces{"history_match.spaces_separate_terms_that_must_all_match", spacesSeparateTermsThatMustAllMatch};
  const telar::testing::Case case_quoted{"history_match.quoted_terms_match_exactly", quotedTermsMatchExactly};
  const telar::testing::Case case_anchors{"history_match.caret_and_dollar_anchor_terms", caretAndDollarAnchorTerms};
  const telar::testing::Case case_bang{"history_match.bang_inverts_a_term", bangInvertsATerm};
  const telar::testing::Case case_bar{"history_match.bar_makes_alternatives", barMakesAlternatives};
  const telar::testing::Case case_smart_case{"history_match.a_capital_makes_a_term_case_sensitive", aCapitalMakesATermCaseSensitive};
  const telar::testing::Case case_diacritics{"history_match.a_term_without_diacritics_matches_accented_letters", aTermWithoutDiacriticsMatchesAccentedLetters};
  const telar::testing::Case case_floor{"history_match.scattered_characters_are_no_match", scatteredCharactersAreNoMatch};
  const telar::testing::Case case_substring{"history_match.substring_mode_matches_keywords_and_ranks_prefixes_first", substringModeMatchesKeywordsAndRanksPrefixesFirst};
  const telar::testing::Case case_whole{"history_match.prefix_and_exact_modes_take_the_whole_query", prefixAndExactModesTakeTheWholeQuery};
  const telar::testing::Case case_short{"history_match.short_queries_take_the_best_occurrence", shortQueriesTakeTheBestOccurrence};
  const telar::testing::Case case_long{"history_match.long_commands_still_match", longCommandsStillMatch};
  const telar::testing::Case case_fast{"history_match.the_fast_path_agrees_with_the_reference", theFastPathAgreesWithTheReference};
  const telar::testing::Case case_history_score{"history_match.history_score_matches_the_query_whole", historyScoreMatchesTheQueryWhole};

}
