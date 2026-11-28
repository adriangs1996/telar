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

  constexpr std::uint64_t hour = 3600;
  constexpr std::uint64_t day = 24 * hour;

  // A command that last ran a week ago, once, nowhere near the search.
  constexpr HistoryRankFeatures plain{.age_seconds = 7 * day, .run_count = 1};

  constexpr HistoryRankFeatures best{
      .age_seconds = 0,
      .run_count = std::numeric_limits<std::uint32_t>::max(),
      .same_directory = true,
      .same_workspace = true,
      .same_session = true,
      .follows_previous = std::numeric_limits<std::uint32_t>::max(),
      .selected_count = std::numeric_limits<std::uint32_t>::max(),
  };

  constexpr HistoryRankFeatures worst{.age_seconds = std::numeric_limits<std::uint64_t>::max(), .recent_failure = true};

  void aCommandRanksLowerAsItAges() {
    constexpr std::array<std::uint64_t, 8> ages{0, hour, 6 * hour, day, day + 1, 3 * day, 9 * day, 30 * day};
    const auto rank = [](std::uint64_t age) {
      auto features = plain;

      features.age_seconds = age;
      return historyRank(100, features);
    };

    for (std::size_t index = 1; index < ages.size(); ++index) {
      check(rank(ages[index - 1]) >= rank(ages[index]), "an older command never ranks above");
    }

    check(rank(0) > rank(hour) && rank(hour) > rank(day) && rank(day) > rank(3 * day), "hours and days apart rank apart");
    check(rank(30 * day) == rank(365 * day), "a month old is as old as it gets");
  }

  void eachPriorMovesTheKeyItsWay() {
    const auto base = historyRank(100, plain);
    const auto with = [](auto change) {
      auto features = plain;

      change(features);
      return historyRank(100, features);
    };

    check(with([](auto& features) {
      features.same_directory = true;
    }) > base,
        "the same directory raises it");
    check(with([](auto& features) {
      features.same_workspace = true;
    }) > base,
        "the same workspace raises it");
    check(with([](auto& features) {
      features.same_session = true;
    }) > base,
        "the same session raises it");
    check(with([](auto& features) {
      features.recent_failure = true;
    }) < base,
        "a failure lowers it");
    check(with([](auto& features) {
      features.run_count = 20;
    }) > base,
        "running more raises it");
    check(with([](auto& features) {
      features.follows_previous = 3;
    }) > base,
        "following the previous command raises it");
    check(with([](auto& features) {
      features.selected_count = 3;
    }) > base,
        "being picked raises it");
    check(with([](auto& features) {
      features.same_directory = true;
    }) > with([](auto& features) {
      features.same_workspace = true;
    }),
        "the directory weighs more than the workspace");
  }

  // Priors weigh x0.8 to x1.2 together, so a clearly better match, one that scores half again as
  // much, ranks first however much the priors favour the other; among matches that score about
  // alike the priors decide; and among equal priors the better match ranks first.
  void priorsNeverOvertakeAClearlyBetterMatch() {
    for (const std::uint32_t weaker : {0U, 1U, 10U, 99U, 1000U, 65535U, 1'000'000U}) {
      const auto better = static_cast<std::uint32_t>(((std::uint64_t{weaker} + 1) * 3 / 2) + 1);

      check(historyRank(better, worst) > historyRank(weaker, best), "a clearly better match wins over every prior");
    }

    check(historyRank(100, best) > historyRank(115, plain), "the priors decide between matches that score alike");
    check(historyRank(100, best) > historyRank(110, worst), "the priors decide between matches that score alike");
    check(historyRank(100, plain) > historyRank(110, worst), "a failure lowers a close match below another");
    check(historyRank(101, plain) > historyRank(100, plain) && historyRank(101, best) > historyRank(100, best), "a better match ranks first among equal priors");
  }

  // A query of inverse terms scores every command 0: priors alone order them.
  void priorsOrderCommandsThatScoreNothing() {
    auto recent = plain;

    recent.age_seconds = 0;
    check(historyRank(0, recent) > historyRank(0, plain));
    check(historyRank(0, plain) == historyRank(0, plain), "equal priors leave the caller's order");
  }

  std::string shape(std::string_view command, std::size_t capacity = 256) {
    std::string out(capacity, '\0');

    out.resize(historyTemplate(command, std::span{out}));
    return out;
  }

  void templatesKeepTheFirstTwoWords() {
    check(shape("git commit -m \"fix it\"") == "git commit");
    check(shape("  kubectl   get pods -n kube-system") == "kubectl get", "spaces between words are one");
    check(shape("ls") == "ls" && shape("") == "" && shape("   ") == "");
  }

  void templatesReplaceQuotesAndPaths() {
    check(shape("echo 'hi there' x") == "echo <str>");
    check(shape("git commit --message=\"a b\"") == "git commit");
    check(shape("grep --file=\"a b\" x") == "grep --file=<str>", "a quote inside a word");
    check(shape("echo \"a\"'b'\"c\"") == "echo <str>", "quotes that follow each other are one");
    check(shape("cd ~/src/telar") == "cd <path>" && shape("./build.sh --fast") == "<path> --fast");
    check(shape("echo \"a/b\"") == "echo <str>", "a slash in quotes is quoted text");
    check(shape("echo a\\ b c") == "echo a\\ b", "an escaped space stays in its word");
    check(shape("echo \"unterminated quote") == "echo <str>");
    check(shape("echo 'it\\'s") == "echo <str>s", "a backslash escapes nothing in single quotes");
  }

  void templatesFitWhereTheyAreWritten() {
    check(shape("déjà vu", 4) == "déj" && shape("déjà vu", 2) == "d", "cut between characters");
    check(shape("déjà vu", 6) == "déjà" && shape("déjà vu", 7) == "déjà", "never ending on a space");

    const std::string quotes = "\"\"x\"\"x\"\"x\"\" \"\"x\"\"x\"\"";

    check(shape(quotes, (2 * quotes.size()) + 12) == shape(quotes, 1024), "twice the command and twelve hold it");
  }

  const telar::testing::Case case_ages{"history_rank.a_command_ranks_lower_as_it_ages", aCommandRanksLowerAsItAges};
  const telar::testing::Case case_priors{"history_rank.each_prior_moves_the_key_its_way", eachPriorMovesTheKeyItsWay};
  const telar::testing::Case case_bounded{"history_rank.priors_never_overtake_a_clearly_better_match", priorsNeverOvertakeAClearlyBetterMatch};
  const telar::testing::Case case_nothing{"history_rank.priors_order_commands_that_score_nothing", priorsOrderCommandsThatScoreNothing};
  const telar::testing::Case case_two_words{"history_rank.templates_keep_the_first_two_words", templatesKeepTheFirstTwoWords};
  const telar::testing::Case case_placeholders{"history_rank.templates_replace_quotes_and_paths", templatesReplaceQuotesAndPaths};
  const telar::testing::Case case_fit{"history_rank.templates_fit_where_they_are_written", templatesFitWhereTheyAreWritten};

}
