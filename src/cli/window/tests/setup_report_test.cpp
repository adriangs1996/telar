#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.testing;
import telar.cli.window;

namespace {

  using telar::testing::check;

  using namespace telar::runtime::cli::machine;

  // A remote host's text reaches the user's terminal through the setup report: it
  // carries no terminal control and no more than the report's bound.
  void boundedStripsControls() {
    std::string text{"a\x1b]0;x\x07"
                     "b\x7f\r\n"};

    text.append(600, 'c');
    const auto shown = SetupReport::bounded(text);

    check(shown.size() <= SetupReport::max_text_bytes);
    check(shown.starts_with('a'));
    check(std::ranges::none_of(shown, [](unsigned char byte) {
      return (byte < 0x20 && byte != '\t') || byte == 0x7f;
    }));
  }

  const telar::testing::Case case_bounded_strips_controls{"setup_report.bounded_strips_controls", boundedStripsControls};

}
