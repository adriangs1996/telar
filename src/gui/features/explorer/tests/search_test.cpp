#include "explorer_fixture.hpp"

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  using Names = std::vector<std::string>;

  KeyChord key(char character) {
    KeyChord chord{.key = KeyChord::Key::character};

    chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(static_cast<unsigned char>(character)));
    return chord;
  }

  // An explorer whose runtime searches paths, with the filter's field open.
  struct Searching : Explorer {
    Searching() {
      state.finds = true;
      start();
      type("/");
    }

    // What is typed in the filter's field, answered by the runtime.
    void filter(std::string_view text) {
      typed(view, state, context(), text);
      answer();
    }

    [[nodiscard]] std::string line() const {
      return std::string{status(view, state, context(), 0).filter.view()};
    }
  };

  void testTheFilterAsksTheRuntimeBelowTheRoot() {
    Searching explorer;

    check(explorer.view.mode == Mode::search && hints(explorer.view, explorer.state, explorer.context()).items[0].label.view() == "keep the filter", "the hints are of the filter while it is typed");
    explorer.filter("usage");
    check(explorer.names() == Names{"docs/usage.md"}, "a path the window never listed, from the root");
    check(find(explorer.state, "/home/dev/telar/docs") == nullptr, "no directory is listed for it");

    const auto& shown = window(explorer.view);
    const auto found = explorer.row("usage.md");

    check(shown.matching && shown.rows[0].kind == RowKind::match && explorer.selected() == "/home/dev/telar/docs/usage.md");
    check(found.lead.view() == "docs/" && found.unstaged == FileState::modified, "with what git says of it, as in the tree");
    check(explorer.line() == "/usage 1" && status(explorer.view, explorer.state, explorer.context(), 0).total.view().empty(), "the status line says how many match, and no size");
    check(preview(explorer.view, explorer.state, explorer.context(), 0).shown, "and the preview is of the match");

    // The spaces around a filter are not searched for, and nothing is asked for the same text.
    const auto asked_before = explorer.requests;

    explorer.filter(" usage ");
    check(explorer.requests == asked_before && explorer.names() == Names{"docs/usage.md"});

    explorer.filter("zzz");
    check(explorer.names() == Names{"nothing below this directory matches"} && explorer.line() == "/zzz 0");

    // More match than an answer carries: the list says so.
    explorer.search_limit = 2;
    explorer.filter("md");
    check(explorer.names() == Names{"README.md", "docs/agents.md", "… more match: a longer filter narrows them"} && explorer.line() == "/md 2+");
    explorer.search_limit = FindPaths::maximum_limit;

    // Enter keeps the filter, on the list of what matched; Escape drops it, and the tree is back.
    explorer.enter("docs");
    check(explorer.view.mode == Mode::normal && explorer.names().front() == "docs/" && explorer.row("docs").directory && !explorer.row("docs").expanded);
    explorer.type("<Esc>");
    check(window(explorer.view).filter.empty() && !window(explorer.view).matching && explorer.names().front() == "assets/");

    // An empty filter is the tree, and asks for nothing.
    const auto asked_tree = explorer.requests;

    explorer.type("/");
    explorer.filter("  ");
    check(!window(explorer.view).matching && explorer.requests == asked_tree);
  }

  void testAnAnswerComesInPartsAndALaterQueryReplacesIt() {
    Searching explorer;

    // The runtime answers while it still reads its index: what it found so far shows.
    typed(explorer.view, explorer.state, explorer.context(), ".md");

    const auto first = need(explorer.view, explorer.state, Explorer::machine);

    check(first && first->kind == NeedKind::search && first->path == "/home/dev/telar" && first->text == ".md", "the filter is what is asked for first");
    check(search(explorer.state, *first).limit == FindPaths::maximum_limit && !search(explorer.state, *first).refresh);
    asked(explorer.state, *first, 900);
    explorer.settle();
    check(explorer.names() == Names{"searching…"} && explorer.line() == "/.md …");
    check(!need(explorer.view, explorer.state, Explorer::machine) || need(explorer.view, explorer.state, Explorer::machine)->kind != NeedKind::search, "a search in flight is not asked again");
    check(receive(explorer.state, explorer.found(900, "/home/dev/telar", ".md", false)));
    explorer.settle();
    check(explorer.names() == Names{"README.md", "docs/agents.md"} && explorer.line() == "/.md 2 …", "the first of them, while the search runs");
    check(receive(explorer.state, explorer.found(900, "/home/dev/telar", ".md", true)));
    explorer.settle();
    check(explorer.names().size() == 4 && explorer.line() == "/.md 4" && explorer.state.search.waiting == 0);

    // Another letter: the query in flight is replaced, and its answers are no longer taken.
    typed(explorer.view, explorer.state, explorer.context(), "us");

    const auto second = need(explorer.view, explorer.state, Explorer::machine);

    check(second && second->text == "us");
    asked(explorer.state, *second, 901);
    typed(explorer.view, explorer.state, explorer.context(), "usa");

    const auto third = need(explorer.view, explorer.state, Explorer::machine);

    check(third && third->text == "usa", "what is typed now is asked for, whatever is in flight");
    asked(explorer.state, *third, 902);
    explorer.settle();
    check(!receive(explorer.state, explorer.found(901, "/home/dev/telar", "us", true)), "the answer to the older query is not the explorer's");
    explorer.settle();
    check(explorer.names() == Names{"searching…"}, "and nothing of it shows");
    check(receive(explorer.state, explorer.found(902, "/home/dev/telar", "usa", true)));
    explorer.settle();
    check(explorer.names() == Names{"docs/usage.md"});

    // A search the runtime refuses found nothing, and is not asked again as it is.
    typed(explorer.view, explorer.state, explorer.context(), "doc");

    const auto fourth = need(explorer.view, explorer.state, Explorer::machine);

    asked(explorer.state, *fourth, 903);
    check(fail(explorer.state, RequestFailed{.request_id = 903, .code = FailureCode::invalid_request, .message = "no index"}));
    explorer.settle();
    check(explorer.names() == Names{"nothing below this directory matches"});
    check(!need(explorer.view, explorer.state, Explorer::machine) || need(explorer.view, explorer.state, Explorer::machine)->kind != NeedKind::search);
  }

  void testNAndNGoAroundTheMatches() {
    Searching explorer;

    explorer.filter(".md");
    explorer.enter(".md");
    check(explorer.names() == Names{"README.md", "docs/agents.md", "docs/remote.md", "docs/usage.md"} && explorer.selected() == "/home/dev/telar/README.md");
    explorer.type("n");
    check(explorer.selected() == "/home/dev/telar/docs/agents.md");
    explorer.type("N");
    explorer.type("N");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md", "N before the first is the last");
    explorer.type("n");
    check(explorer.selected() == "/home/dev/telar/README.md", "and n past the last is the first");
    explorer.type("2n");
    check(explorer.selected() == "/home/dev/telar/docs/remote.md", "a count goes that many");
  }

  void testAMatchIsHandedAndChangedAsAnEntryIs() {
    Searching explorer;

    explorer.filter("usage");
    explorer.enter("usage");

    // Enter hands it to the focused pane, whose shell is in its directory.
    auto action = explorer.type("<CR>");

    check(action.kind == ActionKind::insert && explorer.view.text.view() == "usage.md ");

    // A rename starts from its name, not from its path.
    explorer.type("cw");
    check(explorer.view.mode == Mode::insert && explorer.view.draft.view() == "usage.md");
    explorer.enter("guide.md");

    const auto renamed = explorer.row("guide.md");

    check(renamed.renamed && renamed.note.view() == "was usage.md" && renamed.lead.view() == "docs/");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].path.view() == "/home/dev/telar/docs/usage.md");
    check(!explorer.view.edits[0].unidentified && explorer.view.edits[0].identity.inode == explorer.inspected_inode, "the runtime said which file it is, as no listing did");
    explorer.type("u");

    // A cut before the runtime said which file it is: the plan waits for it.
    static_cast<void>(press(explorer.view, explorer.state, explorer.context(), key('d')));
    static_cast<void>(press(explorer.view, explorer.state, explorer.context(), key('d')));
    check(explorer.view.edits.size() == 1 && explorer.row("usage.md").removed);
    invalidate(explorer.state, {});
    explorer.view.edits.atMut(0).unidentified = true;
    explorer.view.edits.atMut(0).identity = {};
    static_cast<void>(press(explorer.view, explorer.state, explorer.context(), key(':')));
    static_cast<void>(submit(explorer.view, explorer.state, explorer.context(), "w"));
    check(explorer.view.mode == Mode::normal && explorer.view.message.view().starts_with("Reading 1 of the files to change"), "a plan names no file the runtime has not read");
    explorer.answer();
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan);

    Operations operations{};

    check(features::explorer::operations(explorer.view, Explorer::machine, operations) == 1 && operations[0].kind == FileOperationKind::trash && operations[0].identity.inode == explorer.inspected_inode);
    explorer.type("n");

    // Cut and put: the match moves into a directory the filter found.
    explorer.type("u");
    explorer.type("yy");
    explorer.type("/");
    explorer.filter("assets");
    explorer.enter("assets");
    explorer.type("p");
    check(explorer.view.edits.size() == 1 && explorer.view.edits[0].kind == EditKind::paste && explorer.view.edits[0].path.view() == "/home/dev/telar/assets" && explorer.view.edits[0].source.view() == "/home/dev/telar/docs/usage.md");
    check(explorer.view.edits[0].identity.inode == explorer.inspected_inode, "what a paste brings is known the same way");
  }

  void testAFilterNarrowsTheListWhereTheRuntimeDoesNotSearch() {
    Explorer explorer;

    explorer.start();
    explorer.type("l/");
    typed(explorer.view, explorer.state, explorer.context(), "usage");
    explorer.answer();
    check(!window(explorer.view).matching && explorer.names() == Names{"docs/", "usage.md"}, "the rows the window holds, narrowed");
    check(status(explorer.view, explorer.state, explorer.context(), 0).filter.view() == "/usage" && explorer.state.search.waiting == 0);
  }

  void testTabCompletesTheDirectoryACommandGoesTo() {
    Explorer explorer;

    explorer.files["/home/dev/telar/docs"].insert(explorer.files["/home/dev/telar/docs"].begin() + 1, {"imports", true});
    explorer.start();
    explorer.type(":");

    const auto shown = hints(explorer.view, explorer.state, explorer.context());

    check(shown.count == 7 && shown.items[3].keys.view() == ":e LABEL:PATH" && shown.items[6].keys.view() == "<Tab>", "the line of hints says what Tab does there, and how another machine is named");

    const auto completes = [&](std::string_view line) {
      complete(explorer.view, explorer.state, explorer.context(), line);
      explorer.answer();
      return std::string{explorer.view.completion.view()};
    };

    check(completes("e do") == "e docs/" && explorer.view.completed == 1 && explorer.view.message.view().empty(), "one directory completes, with its slash");

    // The directory was never listed: the runtime is asked, and the line completes when it answers.
    complete(explorer.view, explorer.state, explorer.context(), "vs docs/i");
    check(explorer.view.completed == 1 && explorer.view.completing.view() == "vs docs/i");

    const auto wanted = need(explorer.view, explorer.state, Explorer::machine);

    check(wanted && wanted->kind == NeedKind::listing && wanted->path == "/home/dev/telar/docs");
    explorer.answer();
    check(explorer.view.completion.view() == "vs docs/im" && explorer.view.completed == 2 && explorer.view.completing.empty(), "several complete what they share");
    check(explorer.view.message.view() == "images/  imports/  ", "and are listed");
    check(completes("vs docs/im") == "vs docs/im" && explorer.view.completed == 3);
    check(completes("cd ~/te") == "cd ~/telar/", "from the home");
    check(completes("sp /home/dev/telar/s") == "sp /home/dev/telar/src/", "or from the root of the machine");
    check(completes("e ") == "e " && explorer.view.message.view() == "assets/  docs/  out/  src/  ", "a dotted name is listed for a stem that starts with a dot");
    check(completes("e .") == "e .github/");

    const auto before = explorer.view.completed;

    check(completes("e docs/zz") == "e .github/" && explorer.view.completed == before && explorer.view.tone == Tone::error && explorer.view.message.view() == "No directory there starts with that");
    check(completes("e README") == "e .github/" && explorer.view.completed == before, "a file is nowhere to go");
    complete(explorer.view, explorer.state, explorer.context(), "w do");
    complete(explorer.view, explorer.state, explorer.context(), "e");
    check(explorer.view.completed == before && explorer.view.completing.empty(), "a command that goes nowhere, or names nothing yet, completes nothing");

    // Leaving the line forgets a completion that waits.
    complete(explorer.view, explorer.state, explorer.context(), "e assets/l");
    check(!explorer.view.completing.empty());
    cancel(explorer.view, explorer.state, explorer.context());
    check(explorer.view.completing.empty() && !need(explorer.view, explorer.state, Explorer::machine));
  }

  const telar::testing::Case case_asks{"search.the_filter_asks_the_runtime_below_the_root", testTheFilterAsksTheRuntimeBelowTheRoot};
  const telar::testing::Case case_parts{"search.an_answer_comes_in_parts_and_a_later_query_replaces_it", testAnAnswerComesInPartsAndALaterQueryReplacesIt};
  const telar::testing::Case case_around{"search.n_and_N_go_around_the_matches", testNAndNGoAroundTheMatches};
  const telar::testing::Case case_match{"search.a_match_is_handed_and_changed_as_an_entry_is", testAMatchIsHandedAndChangedAsAnEntryIs};
  const telar::testing::Case case_fallback{"search.a_filter_narrows_the_list_where_the_runtime_does_not_search", testAFilterNarrowsTheListWhereTheRuntimeDoesNotSearch};
  const telar::testing::Case case_tab{"search.tab_completes_the_directory_a_command_goes_to", testTabCompletesTheDirectoryACommandGoesTo};

}
