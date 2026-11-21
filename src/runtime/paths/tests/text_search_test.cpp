#include <cstdlib>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.paths.text_search;
import telar.runtime.transport.connection;
import telar.wire.editor;
import telar.wire.vocabulary;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  struct Line {
    std::string path;
    std::uint32_t line = 0;
    std::uint32_t column = 0;
    std::string text;

    bool operator==(const Line&) const = default;
  };

  struct Found {
    std::vector<Line> lines;
    bool truncated = false;
  };

  Found search(ConcurrentMemory& memory, std::string_view root, std::string_view query, std::uint16_t limit = 50) {
    const std::atomic<bool> cancelled{false};
    FileTextSearch search{memory};
    EncodedReply reply{memory};
    std::vector<Byte> scratch(256 * 1024);
    DecodeStorage storage{scratch};

    search.find(FindText{.request_id = 4, .root = root, .query = query, .limit = limit}, cancelled, reply);

    const auto results = Codec::decode<TextResults>(reply.payload(), storage);
    Found found{.truncated = results.truncated};

    check(results.request_id == 4 && results.root == root);
    for (const auto& match : results.matches) {
      found.lines.push_back({std::string{match.path}, match.line, match.column, std::string{match.text}});
    }

    std::ranges::sort(found.lines, {}, [](const Line& line) {
      return std::pair{line.path, line.line};
    });
    return found;
  }

  // What ripgrep and git write of a match differ only in what stands between the fields.
  void testLinesOfBothProgramsAreRead() {
    using namespace std::string_view_literals;

    const auto ripgrep = FileTextLine::parse("src/a b.cpp\0"
                                             "12:5:    int value = 3;"sv);
    const auto git = FileTextLine::parse("src/a b.cpp\0"
                                         "12\0"
                                         "5\0"
                                         "    int value = 3;"sv);

    check(ripgrep && ripgrep->path == "src/a b.cpp" && ripgrep->line == 12 && ripgrep->column == 5 && ripgrep->text == "int value = 3;", "ripgrep's line, without the blanks it starts with");
    check(git && git->path == ripgrep->path && git->line == 12 && git->column == 5 && git->text == ripgrep->text, "git's line says the same");
    check(!FileTextLine::parse("12:5:with:colons"sv), "a line without a path is not a match");
    check(!FileTextLine::parse("a.cpp\0"
                               "x:5:text"sv) &&
              !FileTextLine::parse("a.cpp\0"
                                   "12"sv),
        "nor one whose numbers are not numbers");

    const std::string wide(2000, 'x');
    const auto cut = FileTextLine::parse(std::string{"a.cpp\0", 6} + "1:1:" + wide);

    check(cut && cut->text.size() == TextMatch::maximum_text_bytes, "a long line is cut to what a list shows");
  }

  void testTextIsFoundUnderARoot() {
    if (std::system("command -v git >/dev/null 2>&1") != 0) {
      telar::testing::skip("git is not installed");
    }

    telar::testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    TemporaryDirectory repository{"/tmp/telar-text-XXXXXX"};
    const std::string root{repository.path()};

    std::filesystem::create_directories(root + "/src");
    std::ofstream{root + "/src/one.txt"} << "first line\n  the needle here\nlast\n";
    std::ofstream{root + "/src/two.txt"} << "needle at the start\nand a -needle too\n";
    std::ofstream{root + "/other.txt"} << "nothing to see\n";
    const auto prepare = "cd " + root + " && GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 git init -q && git add . >/dev/null 2>&1";

    check(std::system(prepare.c_str()) == 0);

    const auto found = search(memory, root, "needle");

    check(found.lines.size() == 3 && !found.truncated, "every line that holds the text");
    check(found.lines[0] == Line{"src/one.txt", 2, 7, "the needle here"}, "with its place, and its text without the blanks it starts with");
    check(found.lines[1] == Line{"src/two.txt", 1, 1, "needle at the start"});
    check(search(memory, root, "-needle").lines.size() == 1, "a query that starts as an option is text all the same");
    check(search(memory, root, "no such text anywhere").lines.empty(), "nothing found is an answer, not a failure");

    const auto limited = search(memory, root, "needle", 2);

    check(limited.lines.size() == 2 && limited.truncated, "what passes the limit says there was more");

    bool refused = false;

    try {
      search(memory, "relative/root", "needle");
    } catch (const RequestError& error) {
      refused = error.code() == FailureCode::invalid_request;
    }

    check(refused, "a root that is not absolute is refused");
  }

  const telar::testing::Case case_lines{"text_search.lines_of_both_programs_are_read", testLinesOfBothProgramsAreRead};
  const telar::testing::Case case_found{"text_search.text_is_found_under_a_root", testTextIsFoundUnderARoot};

}
