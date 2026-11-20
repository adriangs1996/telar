#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.cli.commands.history;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli;

  // The milliseconds `prune --before` keeps up to, or the name of the error the text is
  // refused with.
  std::string before(std::string_view text) {
    try {
      return std::to_string(HistoryOptions::parseBefore(text));
    } catch (const std::invalid_argument& error) {
      return error.what();
    }
  }

  // A UTC date is its midnight and Unix seconds scale to milliseconds: the bound
  // `prune --before` deletes up to.
  void parseBefore() {
    check(before("2024-02-29") == "1709164800000");
    check(before("2024-03-01") == "1709251200000");
    check(before("2024-01-01") == "1704067200000");
    check(before("2023-12-31") == "1703980800000");
    check(before("2000-02-29") == "951782400000");
    check(before("1700000000") == "1700000000000");

    check(before("0") == "InvalidHistoryBefore");
    check(before("2024-13-01") == "InvalidHistoryBefore");
    check(before("2024-01") == "InvalidHistoryBefore");
  }

  const telar::testing::Case case_parse_before{"history_options.parse_before", parseBefore};

}
