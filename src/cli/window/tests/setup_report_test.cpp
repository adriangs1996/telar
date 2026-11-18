#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

import std;
import telar.base.memory.allocators;
import telar.testing;
import telar.cli.window;

namespace {

  using telar::testing::check;

  using namespace telar;
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

  int finished(std::initializer_list<std::pair<Step, Status>> steps) {
    SystemAllocator system;
    MemoryAdapter adapter{system};
    SetupReport report{.json = false};

    for (const auto& [step, status] : steps) {
      report.end(step, status, "fixture");
    }

    return report.finish(adapter, "box", "box.example.invalid");
  }

  // An interactive setup with a failed step exits non-zero, so a script that chains it stops;
  // a login still to do or a change is not a failure.
  void textVerdictExit() {
    check(finished({{Step::ssh, Status::ok}, {Step::telar, Status::failed}}) == 1);
    check(finished({{Step::ssh, Status::ok}, {Step::logins, Status::pending}}) == 0);
    check(finished({{Step::ssh, Status::ok}, {Step::telar, Status::changed}}) == 0);
  }

  const telar::testing::Case case_bounded_strips_controls{"setup_report.bounded_strips_controls", boundedStripsControls};
  const telar::testing::Case case_text_verdict_exit{"setup_report.text_verdict_exit", textVerdictExit};

}
