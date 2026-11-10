#ifdef __clangd__
static_assert(true);
#endif
#include <array>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

#include <gtest/gtest.h>

import telar.ebnf.matcher;
namespace {
  using words = std::vector<std::string_view>;

  // Renders candidates as "text", "prefix|text" for glued values and "@name" for providers.
  struct completion {
    ebnf::match_result result;
    std::vector<std::string> shown;
    std::vector<std::string_view> descriptions;
  };

  class Matcher : public testing::Test {
  protected:
    std::unique_ptr<ebnf::match_scratch> scratch_ = std::make_unique<ebnf::match_scratch>();
    std::array<ebnf::candidate, 64> out_{};

    auto complete(const ebnf::command_spec &spec, const words &line, std::string_view partial) -> completion {
      auto completed = completion{.result = spec.complete(line, partial, *scratch_, out_), .shown = {}, .descriptions = {}};

      for (std::size_t index = 0; index < completed.result.count; ++index) {
        const auto &candidate = out_[index];
        auto text = std::string{candidate.prefix.empty() ? "" : std::string{candidate.prefix} + "|"};
        text += candidate.kind == ebnf::candidate_kind::provider ? "@" + std::string{candidate.text} : std::string{candidate.text};
        completed.shown.push_back(text);
        completed.descriptions.push_back(candidate.description);
      }

      return completed;
    }

    auto check(const ebnf::command_spec &spec, const words &line) -> ebnf::match_result {
      return spec.check(line, *scratch_);
    }

    auto firstInvalid(const ebnf::command_spec &spec, const words &line) -> std::int64_t {
      const auto result = check(spec, line);
      return result.status == ebnf::match_status::invalid ? std::int64_t{result.word} : -1;
    }
  };

  using shown = std::vector<std::string>;

  // A function-local static: compiling may throw, which a namespace-scope initializer could not report.
  auto vcs() -> const ebnf::command_spec & {
    static const auto spec = ebnf::command_spec::compile(R"ebnf(
    (* The first rule is the start symbol. *)
    vcs = { global } , [ command ] ;
    global = "-C" : "Run as if started in a directory" , @directory | "--no-pager" ;
    command = "switch" : "Switch branches" , { switch_option | @branch }
            | "status" : "Show the working tree status" , { "-s" | "--short" }
            | "stash" , [ "pop" | "push" ] ;
    switch_option = "-c" : "Create a branch" , @branch | "--color=" ~ when | "--quiet" | "-q" ;
    when = "always" : "Always color" | "never" | "auto" ;
  )ebnf");
    return spec;
  }

  TEST_F(Matcher, CompletesLiteralsByPrefixInGrammarOrder) {
    const auto all = complete(vcs(), {}, "");

    EXPECT_EQ(all.result.status, ebnf::match_status::valid);
    EXPECT_EQ(all.shown, (shown{"-C", "--no-pager", "switch", "status", "stash"}));
    EXPECT_EQ(all.descriptions[0], "Run as if started in a directory");
    EXPECT_EQ(all.descriptions[2], "Switch branches");
    EXPECT_EQ(all.descriptions[4], "");

    EXPECT_EQ(complete(vcs(), {}, "st").shown, (shown{"status", "stash"}));
    EXPECT_EQ(complete(vcs(), {}, "sta").shown, (shown{"status", "stash"}));
    EXPECT_EQ(complete(vcs(), {}, "stas").shown, (shown{"stash"}));
    EXPECT_TRUE(complete(vcs(), {}, "x").shown.empty());
  }

  TEST_F(Matcher, ProvidersAreOfferedWhereExpected) {
    EXPECT_EQ(complete(vcs(), {"-C"}, "").shown, (shown{"@directory"}));
    EXPECT_EQ(complete(vcs(), {"-C", "src"}, "sw").shown, (shown{"switch"}));
    EXPECT_EQ(complete(vcs(), {"switch", "-c"}, "fe").shown, (shown{"@branch"}));
  }

  TEST_F(Matcher, OperandProvidersRejectOptionLikeWords) {
    // Grammar order is first appearance on a depth-first walk: @branch first appears after "-c".
    EXPECT_EQ(complete(vcs(), {"switch"}, "").shown, (shown{"-c", "@branch", "--color=", "--quiet", "-q"}));
    // An option-like partial cannot become a branch; a lone "-" still can.
    EXPECT_EQ(complete(vcs(), {"switch"}, "--").shown, (shown{"--color=", "--quiet"}));
    EXPECT_EQ(complete(vcs(), {"switch"}, "-").shown, (shown{"-c", "@branch", "--color=", "--quiet", "-q"}));
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--bogus"}), 1);
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "-"}), -1);
  }

  TEST_F(Matcher, OptionsRepeatInAnyOrder) {
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--quiet", "main", "-q", "-c", "topic", "--quiet"}), -1);
    EXPECT_EQ(complete(vcs(), {"switch", "main", "--quiet", "-q"}, "--q").shown, (shown{"--quiet"}));
    EXPECT_EQ(complete(vcs(), {"-C", "a", "-C", "b", "--no-pager"}, "s").shown, (shown{"switch", "status", "stash"}));
  }

  TEST_F(Matcher, GluedValuesCompleteInsideTheWord) {
    EXPECT_EQ(complete(vcs(), {"switch"}, "--co").shown, (shown{"--color="}));
    EXPECT_EQ(complete(vcs(), {"switch"}, "--color").shown, (shown{"--color="}));

    const auto values = complete(vcs(), {"switch"}, "--color=");
    EXPECT_EQ(values.shown, (shown{"--color=|always", "--color=|never", "--color=|auto"}));
    EXPECT_EQ(values.descriptions[0], "Always color");

    EXPECT_EQ(complete(vcs(), {"switch"}, "--color=a").shown, (shown{"--color=|always", "--color=|auto"}));
    EXPECT_TRUE(complete(vcs(), {"switch"}, "--color=x").shown.empty());
  }

  TEST_F(Matcher, GluedValuesMatchTheRestOfTheWord) {
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--color=never", "main"}), -1);
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--color=sometimes"}), 1);
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--color="}), 1);
    EXPECT_EQ(firstInvalid(vcs(), {"switch", "--color", "never"}), 1);
  }

  TEST_F(Matcher, GluedProvidersCarryThePrefix) {
    const auto spec = ebnf::command_spec::compile(R"(git = { "--git-dir=" ~ @directory : "Repository" | "-n" ~ @any } ;)");
    const auto values = complete(spec, {}, "--git-dir=sr");

    EXPECT_EQ(values.shown, (shown{"--git-dir=|@directory"}));
    EXPECT_EQ(values.descriptions[0], "Repository");
    EXPECT_EQ(firstInvalid(spec, {"--git-dir=/tmp/x", "-n5", "-n-1"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"--git-dir="}), 0);
  }

  TEST_F(Matcher, CheckReportsTheFirstInvalidWord) {
    EXPECT_EQ(firstInvalid(vcs(), {}), -1);
    EXPECT_EQ(firstInvalid(vcs(), {"swich"}), 0);
    EXPECT_EQ(firstInvalid(vcs(), {"-C", "src", "stash", "pop", "extra"}), 4);
    EXPECT_EQ(firstInvalid(vcs(), {"status", "-s", "--long"}), 2);
    // A word that would only complete a command later is still a valid prefix.
    EXPECT_EQ(firstInvalid(vcs(), {"-C"}), -1);
  }

  TEST_F(Matcher, CompletionAfterAnInvalidWordReportsIt) {
    const auto completed = complete(vcs(), {"status", "nope"}, "");

    EXPECT_EQ(completed.result.status, ebnf::match_status::invalid);
    EXPECT_EQ(completed.result.word, 1u);
    EXPECT_EQ(completed.result.count, 0u);
  }

  TEST_F(Matcher, DeduplicatesEqualCandidates) {
    const auto spec = ebnf::command_spec::compile(R"(
      c = { "-v" : "first" | "-v" : "second" | a | @file | @file } ;
      a = "-v" | "--x" ;
    )");
    const auto completed = complete(spec, {}, "");

    EXPECT_EQ(completed.shown, (shown{"-v", "--x", "@file"}));
    EXPECT_EQ(completed.descriptions[0], "first");
  }

  TEST_F(Matcher, AnyMatchesOptionLikeWords) {
    const auto spec = ebnf::command_spec::compile(R"(ssh = @ssh_host , [ @command , { @any } ] ;)");

    EXPECT_EQ(firstInvalid(spec, {"host", "ls", "-la", "--color=auto"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"host", "-la"}), 1);
    EXPECT_EQ(complete(spec, {"host", "ls"}, "--").shown, (shown{"@any"}));
  }

  TEST_F(Matcher, ShortOptionClustersAreDecomposed) {
    const auto spec = ebnf::command_spec::compile(R"(
      commit = "commit" , { "-a" | "-v" | "-m" , @any | "-p" , @port } ;
    )");

    EXPECT_EQ(firstInvalid(spec, {"commit", "-am", "message"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"commit", "-vvv"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"commit", "-mmessage"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"commit", "-avmtext", "-p22"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"commit", "-ax"}), 1);
    EXPECT_EQ(firstInvalid(spec, {"commit", "-xa"}), 1);
    // After "-am" the message is still expected.
    EXPECT_EQ(complete(spec, {"commit", "-am"}, "").shown, (shown{"@any"}));
    EXPECT_EQ(complete(spec, {"commit", "-a"}, "").shown, (shown{"-a", "-v", "-m", "-p"}));
  }

  TEST_F(Matcher, OptionalRepetitionAndGroupingCompose) {
    const auto spec = ebnf::command_spec::compile(R"(
      s = ( "a" | "b" ) , [ "c" ] , { "d" , "e" } , "f" + , "g" ? ;
    )");

    EXPECT_EQ(firstInvalid(spec, {"a", "f"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"b", "c", "d", "e", "d", "e", "f", "f", "g"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"a", "d", "f"}), 2);
    EXPECT_EQ(firstInvalid(spec, {"a", "g"}), 1);
    EXPECT_EQ(complete(spec, {"a"}, "").shown, (shown{"c", "d", "f"}));
    EXPECT_EQ(complete(spec, {"a", "f"}, "").shown, (shown{"f", "g"}));
  }

  TEST_F(Matcher, NullableRulesAndRecursionTerminate) {
    const auto spec = ebnf::command_spec::compile(R"(
      s = a , a , "x" ;
      a = [ b ] ;
      b = { "y" } | a ;
    )");

    EXPECT_EQ(firstInvalid(spec, {"x"}), -1);
    EXPECT_EQ(firstInvalid(spec, {"y", "y", "y", "x"}), -1);
    EXPECT_EQ(complete(spec, {}, "").shown, (shown{"y", "x"}));
  }

  TEST_F(Matcher, LiteralEscapesAreDecoded) {
    const auto spec = ebnf::command_spec::compile(R"(s = "a\tb" , 'it\'s' ;)");

    EXPECT_EQ(firstInvalid(spec, {"a\tb", "it's"}), -1);
    EXPECT_EQ(firstInvalid(spec, {R"(a\tb)"}), 0);
  }

  TEST_F(Matcher, LimitsFailClosedAsUnknown) {
    const auto spec = ebnf::command_spec::compile(R"(s = { @any } ;)");
    const auto many = words(ebnf::max_words + 1, "w");

    EXPECT_EQ(check(spec, words(ebnf::max_words, "w")).status, ebnf::match_status::valid);
    EXPECT_EQ(check(spec, many).status, ebnf::match_status::unknown);
    EXPECT_EQ(complete(spec, many, "").result.status, ebnf::match_status::unknown);

    // Every split of the words is a derivation, so Earley sets grow with the line until they overflow.
    const auto ambiguous = ebnf::command_spec::compile(R"(s = { a } ; a = { @any } ;)");
    EXPECT_EQ(check(ambiguous, words(ebnf::max_words, "w")).status, ebnf::match_status::unknown);
  }

  TEST_F(Matcher, OutputSpanBoundsTheCandidates) {
    std::array<ebnf::candidate, 2> small{};
    const auto result = vcs().complete({}, "", *scratch_, small);

    EXPECT_EQ(result.count, 2u);
    EXPECT_TRUE(result.truncated);
    EXPECT_EQ(small[0].text, "-C");
    EXPECT_EQ(small[1].text, "--no-pager");
  }

  TEST_F(Matcher, ScratchIsReusableAcrossSpecs) {
    const auto other = ebnf::command_spec::compile(R"(o = "x" , "y" ;)");

    for (int round = 0; round < 3; ++round) {
      EXPECT_EQ(complete(vcs(), {"switch"}, "-q").shown, (shown{"-q"}));
      EXPECT_EQ(complete(other, {"x"}, "").shown, (shown{"y"}));
    }
  }

  TEST(MatcherCompile, RejectsSemanticErrors) {
    for (const auto source : {
             "",
             "a = b ;",
             R"(a = "x" ; a = "y" ;)",
             R"(a = "x" - "y" ;)",
             R"(a = b ~ @any ; b = "x" ;)",
             R"(a = "-x" ~ ( "p" , "q" ) ;)",
             R"(a = "-x" ~ [ "p" ] ;)",
             R"(a = "-x" ~ b ; b = b ;)",
         }) {
      SCOPED_TRACE(source);
      EXPECT_THROW(ebnf::command_spec::compile(source), std::invalid_argument);
    }
  }

  TEST(MatcherCompile, SyntaxErrorsThrowAtLoadTime) {
    EXPECT_THROW(ebnf::command_spec::compile(R"(a = "x" )"), std::invalid_argument);
    EXPECT_THROW(ebnf::command_spec::compile("a = @ ;"), std::invalid_argument);
  }

  TEST(MatcherCompile, SpecOutlivesItsSource) {
    auto source = std::make_unique<std::string>(R"(s = "keep" : "kept" ;)");
    const auto spec = ebnf::command_spec::compile(*source);
    source.reset();

    auto scratch = std::make_unique<ebnf::match_scratch>();
    std::array<ebnf::candidate, 4> out{};
    const auto result = spec.complete({}, "", *scratch, out);
    ASSERT_EQ(result.count, 1u);
    EXPECT_EQ(out[0].text, "keep");
    EXPECT_EQ(out[0].description, "kept");
  }
}
