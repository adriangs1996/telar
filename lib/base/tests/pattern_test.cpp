#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.text.pattern;
import telar.testing;

namespace {

  using telar::testing::check;

  using namespace telar::runtime;

  // A regular expression's search, as a filter of the configuration asks it.
  bool finds(std::string_view pattern, std::string_view text) {
    return Pattern{pattern, PatternOptions{.regex = true}}.matches(text);
  }

  // The match `pattern` finds in `text`, as the text it covers, or "-" for none.
  std::string found(std::string_view pattern, std::string_view text, PatternOptions options = {.regex = true}) {
    const auto compiled = std::make_unique<Pattern>(pattern, options);
    const auto match = compiled->find(text);

    return match ? std::string{text.substr(match->begin, match->end - match->begin)} : std::string{"-"};
  }

  bool rejected(std::string_view pattern) {
    try {
      static_cast<void>(std::make_unique<Pattern>(pattern, PatternOptions{.regex = true}));
    } catch (const PatternError&) {
      return true;
    }

    return false;
  }

  // Text looked for as it is: the case kept or ignored, and none of its bytes read as an operator.
  void literalTextIsFoundAsItIs() {
    check(found("a.b", "xa.bx", {}) == "a.b" && found("a.b", "aXb", {}) == "-", "a literal's dot is a dot");
    check(found("Error", "an error here", {}) == "-", "the case counts by default");
    check(found("Error", "an eRRor here", {.ignore_case = true}) == "eRRor", "and is ignored when asked");
    check(found("", "anything", {}).empty(), "an empty pattern matches at the start");
  }

  // The leftmost match, the longest a greedy quantifier takes and the shortest a lazy one does.
  void regexFindsTheLeftmostMatch() {
    check(found("b+", "abbbc") == "bbb", "+ takes as many as it can");
    check(found("b+?", "abbbc") == "b", "+? as few");
    check(found("a.*c", "xabcabc") == "abcabc" && found("a.*?c", "xabcabc") == "abc", "* and *? across the line");
    check(found("colou?r", "the colour") == "colour" && found("colou?r", "the color") == "color", "? makes a byte optional");
    check(found("cat|dog", "hotdog") == "dog" && found("(a|ab)(c|bcd)", "abcd") == "abcd", "alternatives, in order");
    check(found("x{2,3}", "axxxxb") == "xxx" && found("x{2}", "axb") == "-" && found("x{2,}", "xxxxx") == "xxxxx", "counted repetition");
    check(found("[0-9]+ms", "took 125ms") == "125ms" && found("[^ ]+", "  word ") == "word", "classes and negated classes");
    check(found("\\d+\\.\\d+", "v 1.25 ok") == "1.25" && found("\\w+", "  snake_case1 ") == "snake_case1" && found("\\S+", "  x-y ") == "x-y", "shorthand classes and escaped operators");
    check(found("^warn", "warn: x") == "warn" && found("^warn", "a warn") == "-" && found("done$", "all done") == "done" && found("done$", "done!") == "-", "anchors at the line's ends");
    check(found("\\bcat\\b", "concat cat") == "cat" && found("\\Bcat", "concat") == "cat", "word boundaries");
    check(found("(?:ab)+", "xababx") == "abab" && found("a{1,2}?", "aa") == "a", "groups that capture nothing, and lazy counted repetition");
  }

  // Case is ignored for literals, classes and ranges alike.
  void regexIgnoresCaseWhenAsked() {
    constexpr PatternOptions folded{.regex = true, .ignore_case = true};

    check(found("error: [a-z]+", "ERROR: Disk", folded) == "ERROR: Disk", "letters and a range of them");
    check(found("error", "ERROR") == "-", "and only when asked");
  }

  // `.` and a negated class take whole UTF-8 characters.
  void regexTakesWholeCharacters() {
    check(found("caf.", "café!") == "café" && found("[^a]x", "éx") == "éx", "a character of two bytes is one");
    check(found("^.{4}$", "añob") == "añob" && found("^.{5}$", "añob") == "-", ". counts characters, not bytes");
  }

  // Patterns that would make a backtracking engine run for ever end at once, and a long line
  // takes time in proportion to its length.
  void regexNeverBacktracks() {
    const std::string line(4096, 'a');

    check(found("(a+)+b", line) == "-" && found("(a|a)*b", line) == "-" && found("(a*)*$", line) == line, "nested quantifiers are linear");
    check(found("x{100}", std::string(200, 'x')) == std::string(100, 'x'), "the largest counted repetition compiles");
  }

  // A pattern that does not compile says so, instead of matching something else.
  void badRegexIsRejected() {
    for (const auto pattern : {"(a", "a)", "[ab", "*a", "a**", "x{3,1}", "\\q", "a\\", "x{101}", "((((((((((((((((((((((((((((((((((a))))))))))))))))))))))))))))))))))"}) {
      check(rejected(pattern), "an invalid pattern is refused");
    }

    check(rejected("^*") && rejected("\\b+"), "an assertion is not repeated");
    check(rejected("[\\q]") && rejected("[b-a]"), "a class names what it holds");
    check(!rejected("a{") && found("a{", "a{") == "a{" && found("a{x}", "a{x}") == "a{x}", "a brace that starts no count is a literal");
    check(rejected(std::string(Pattern::maximum_pattern_bytes + 1, 'a')), "a pattern past its limit is refused");
    check(rejected("(x{100}){100}"), "a pattern whose program would be too large is refused");
  }

  // Each match after the last: every one in a line, without the search allocating.
  void searchesResumeAfterAMatch() {
    auto pattern = std::make_unique<Pattern>("[0-9]+", PatternOptions{.regex = true});
    constexpr std::string_view text = "1 22 333";
    std::vector<std::string_view> matches;

    for (auto match = pattern->find(text); match; match = pattern->find(text, match->end)) {
      matches.push_back(text.substr(match->begin, match->end - match->begin));
    }

    check(matches == std::vector<std::string_view>{"1", "22", "333"}, "the matches of a line one after another");
    check(!pattern->find(text, text.size() + 1), "a search past the line's end finds nothing");
  }

  // A pattern is found anywhere in the text unless `^` or `$` anchor it to a line's end.
  void patternIsFoundAnywhereUnlessAnchored() {
    check(finds("vault login", "sudo vault login -method=oidc"), "anywhere in the text");
    check(finds("^ssh ", "ssh prod-1") && !finds("^ssh ", "echo ssh prod-1"), "^ at the start");
    check(finds("prod$", "ssh prod") && !finds("prod$", "ssh prod-1"), "$ at the end");
    check(finds("^$", "") && !finds("x", ""), "an empty text");
    check(finds("^done$", "make\ndone") && !finds("^make$", "make all\ndone"), "the anchors take each line's ends");
  }

  void classesQuantifiersAndGroupsMatchAsWritten() {
    check(finds("^curl .*-u [a-z]+:", "curl https://x -u admin:pw") && !finds("^curl .*-u [a-z]+:", "curl https://x -u ADMIN:pw"), "a range keeps its case");
    check(finds("^(git|hg) push", "hg push origin") && !finds("^(git|hg) push", "svn push"), "alternatives in a group");
    check(finds("^x{2,3}$", "xx") && finds("^x{2,3}$", "xxx") && !finds("^x{2,3}$", "x") && !finds("^x{2,3}$", "xxxx"), "a counted repetition");
    check(finds("^\\d+\\.\\d+$", "3.14") && !finds("^\\d+\\.\\d+$", "3x14"), "digits and an escaped dot");
    check(finds("\\s--force", "git push\t--force"), "a tab is a space");
    check(finds("a?b", "b") && finds("ab+c", "abbbc") && !finds("ab+c", "ac"), "? and +");
    check(finds("^[a-z_-]+$", "snake-case_x") && finds("(?:x)", "x"), "a dash last in a class, and a group that captures nothing");
  }

  // A class holds any characters, each whole, and a text of bytes UTF-8 does not read is matched
  // byte by byte, never read past.
  void classesHoldAnyCharacter() {
    check(finds("^[\xc3\xa9\xc3\xa8]+$", "\xc3\xa9\xc3\xa8\xc3\xa9") && !finds("^[\xc3\xa9]$", "\xc3\xa8"), "a class of accented letters");
    check(finds("^[\xce\xb1-\xcf\x89]+$", "\xce\xbb\xce\xbf\xce\xb3\xce\xbf\xcf\x82") && !finds("^[\xce\xb1-\xcf\x89]+$", "logos"), "a range of Greek letters");
    check(finds("^\xc3\xa9+$", "\xc3\xa9\xc3\xa9"), "a character of two bytes repeats whole");
    check(finds("^a.b$", "a\xff"
                         "b") &&
              !finds("^a\xc3\xa9$", "a\xc3"),
        "a byte no character starts is one of its own, and a character cut short is no character");
    check(!finds("^a.b$", "a\nb"), ". takes no line's end");
  }

  // With the case ignored, letters beyond ASCII match in either case too, and the match lies on
  // the text as it was written.
  void ignoredCaseFoldsEveryLetter() {
    const PatternOptions folded{.regex = true, .ignore_case = true};
    const Pattern greek{"\xce\xbb\xcf\x8c\xce\xb3", folded};
    constexpr std::string_view text = "the \xce\x9b\xce\x8c\xce\x93OS";
    const auto match = greek.find(text);

    check(match && text.substr(match->begin, match->end - match->begin) == "\xce\x9b\xce\x8c\xce\x93", "capitals beyond ASCII match, and the match is where they were written");
    check(found("[A-Z]+", "\xc3\xa9"
                          "COLE",
              folded) == "COLE" &&
              found("CAF\xc3\x89", "a caf\xc3\xa9", folded) == "caf\xc3\xa9",
        "classes and literals fold alike");
    check(found("\xc3\x89"
                "COLE",
              "\xc3\xa9"
              "cole",
              {.ignore_case = true}) == "\xc3\xa9"
                                        "cole",
        "text looked for as it is folds too");
  }

  // One pattern is looked for by many threads at once, each with its buffers, and a copy finds
  // what the pattern finds.
  void threadsShareAPattern() {
    const Pattern pattern{"(\\d+)ms", PatternOptions{.regex = true}};
    const Pattern copy = pattern;
    std::atomic<int> found{0};
    std::vector<std::thread> threads;

    for (int index = 0; index < 4; ++index) {
      threads.emplace_back([&pattern, &found] {
        auto scratch = std::make_unique<PatternScratch>();
        const std::string text = "took 125ms then 7ms";

        for (int round = 0; round < 200; ++round) {
          const auto match = pattern.find(text, 0, *scratch);
          if (match && text.substr(match->begin, match->end - match->begin) == "125ms") {
            found.fetch_add(1);
          }
        }
      });
    }

    for (auto& thread : threads) {
      thread.join();
    }

    check(found.load() == 800, "every thread finds every match");
    check(copy.find("x 9ms")->begin == 2 && Pattern{}.empty() && !Pattern{}.matches("x"), "a copy finds the same, and no pattern matches nothing");
  }

  const telar::testing::Case case_literal_text_is_found_as_it_is{"pattern.literal_text_is_found_as_it_is", literalTextIsFoundAsItIs};
  const telar::testing::Case case_regex_finds_the_leftmost_match{"pattern.regex_finds_the_leftmost_match", regexFindsTheLeftmostMatch};
  const telar::testing::Case case_regex_ignores_case_when_asked{"pattern.regex_ignores_case_when_asked", regexIgnoresCaseWhenAsked};
  const telar::testing::Case case_regex_takes_whole_characters{"pattern.regex_takes_whole_characters", regexTakesWholeCharacters};
  const telar::testing::Case case_regex_never_backtracks{"pattern.regex_never_backtracks", regexNeverBacktracks};
  const telar::testing::Case case_bad_regex_is_rejected{"pattern.bad_regex_is_rejected", badRegexIsRejected};
  const telar::testing::Case case_searches_resume_after_a_match{"pattern.searches_resume_after_a_match", searchesResumeAfterAMatch};
  const telar::testing::Case case_anywhere{"pattern.pattern_is_found_anywhere_unless_anchored", patternIsFoundAnywhereUnlessAnchored};
  const telar::testing::Case case_constructs{"pattern.classes_quantifiers_and_groups_match_as_written", classesQuantifiersAndGroupsMatchAsWritten};
  const telar::testing::Case case_any_character{"pattern.classes_hold_any_character", classesHoldAnyCharacter};
  const telar::testing::Case case_folding{"pattern.ignored_case_folds_every_letter", ignoredCaseFoldsEveryLetter};
  const telar::testing::Case case_threads{"pattern.threads_share_a_pattern", threadsShareAPattern};

}
