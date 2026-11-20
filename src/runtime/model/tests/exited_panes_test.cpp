import std;
import telar.testing;
import telar.runtime.model.slot_store;
import telar.wire.content;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  // `telar pane read --rows` on a pane that exited reads what the pane last showed.
  void testReadLastRows() {
    auto exited = std::make_unique<ExitedPanes>();

    exited->record({.id = 4, .generation = 1}, PaneText{.request_id = 1, .pane_id = 4, .text = "one\ntwo\nthree\nfour\nfive\n", .exit_code = 3});
    const auto* record = exited->find(4, 1);

    check(record != nullptr);
    const auto last = record->response(ReadPane{.request_id = 2, .pane_id = 4, .rows = 2});

    check(last.text == "four\nfive" && !last.truncated && last.exit_code == 3);
    check(record->response(ReadPane{.request_id = 3, .pane_id = 4, .rows = 5}).text == "one\ntwo\nthree\nfour\nfive");

    // A screen past what an exited pane keeps loses its head, and says so.
    std::string long_text;

    for (int line = 0; long_text.size() <= ExitedPanes::maximum_bytes; ++line) {
      long_text += std::format("line {:05}\n", line);
    }

    long_text += "last line";
    exited->record({.id = 5, .generation = 1}, PaneText{.request_id = 4, .pane_id = 5, .text = long_text});
    const auto whole = exited->find(5, 1)->response(ReadPane{.request_id = 5, .pane_id = 5});

    check(whole.truncated && whole.text.ends_with("last line") && whole.text.size() <= ExitedPanes::maximum_bytes);
    check(!exited->find(5, 1)->response(ReadPane{.request_id = 6, .pane_id = 5, .rows = 2}).truncated);
  }

  const telar::testing::Case case_read_last_rows{"exited_panes.read_last_rows", testReadLastRows};

}
