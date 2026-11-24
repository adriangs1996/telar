#include "explorer_fixture.hpp"
#include <string>
#include <string_view>

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  std::string typedAt(std::string_view path, std::string_view cwd, bool quote = true) {
    SystemAllocator upstream;
    telar::MemoryAdapter<SystemAllocator> adapter{upstream};
    telar::Memory& memory = adapter;
    ds::String<Memory> text{memory};

    appendTyped(text, path, {.cwd = cwd, .home = "/home/dev", .shell = quote});
    return std::string{text.view()};
  }

  void testSizesAndAgesReadAsAPersonSaysThem() {
    check(bytes(0).view() == "0B" && bytes(512).view() == "512B" && bytes(7739).view() == "7.6K" && bytes(110592).view() == "108K");
    check(bytes(2621440).view() == "2.5M" && bytes(107374182400).view() == "100G", "one decimal below ten of a unit, none from ten on");
    check(age(100, 130).view() == "1 min" && age(0, 61200).view() == "17 h" && age(0, 3 * 86400).view() == "3 d");
    check(day(1794096000).view() == "2026-11-08");
  }

  void testAPathIsTypedAsAPersonWould() {
    check(typedAt("/home/dev/telar/docs/usage.md", "/home/dev/telar/docs") == "usage.md");
    check(typedAt("/home/dev/telar/src/main.cpp", "/home/dev/telar/docs") == "../src/main.cpp", "relative while it is no more than two directories up");
    check(typedAt("/home/dev/telar/docs", "/home/dev/telar/docs") == ".");
    check(typedAt("/home/dev/notes.txt", "/home/dev/telar/docs/images") == "~/notes.txt", "from the home past that");
    check(typedAt("/etc/hosts", "/home/dev/telar") == "/etc/hosts", "and whole outside the home");
    check(typedAt("/home/dev/telar/my notes.md", "/home/dev/telar") == "'my notes.md'", "quoted when a shell would split it");
    check(typedAt("/home/dev/telar/it's.md", "/home/dev/telar") == R"('it'\''s.md')");
    check(typedAt("/home/dev/my notes.md", "/srv") == "~/'my notes.md'", "the home's sign stays outside the quotes, so the shell expands it");
    check(typedAt("/home/dev/telar/my notes.md", "/home/dev/telar", false) == "my notes.md", "a mention is not quoted");
    check(within("/a/b", "/a") && within("/a", "/a") && !within("/ab", "/a") && within("/x", "/"));
    check(parentOf("/a/b") == "/a" && parentOf("/a") == "/" && baseOf("/a/b.md") == "b.md");
  }

  void testTheWindowSaysWhereItIsAndWhatAppliesNow() {
    Explorer explorer;

    explorer.start();

    const auto head = header(explorer.view, explorer.state, explorer.context(), 0);

    check(head.machine.view() == "macbook" && head.local && head.lead.view() == "~/" && head.last.view() == "telar", "the root from the home, its last directory apart");
    check(head.repository && head.branch.view() == "lifetime-speed" && head.staged == 1 && head.unstaged == 1 && head.untracked == 1);

    auto line = status(explorer.view, explorer.state, explorer.context(), 0);

    check(line.mode == "NORMAL" && line.current && line.follows && line.following.view() == "[3 zsh]" && line.root.view() == "~/telar");
    check(line.position == 2 && line.count == 5 && line.total.view() == "20G" && line.flags.view().empty() && !line.pending);

    explorer.type("g.S");
    explorer.type("2");
    explorer.type("d");
    line = status(explorer.view, explorer.state, explorer.context(), 0);
    check(line.flags.view() == "[size↓ .]" && line.keys.view() == "2d", "what is listed and how, and the keys typed toward a command");
    explorer.type("d");
    line = status(explorer.view, explorer.state, explorer.context(), 0);
    check(line.pending && line.keys.view().empty());
    explorer.type("V");
    explorer.type("j");
    line = status(explorer.view, explorer.state, explorer.context(), 0);
    check(line.mode == "VISUAL" && line.chosen == 2);
    explorer.type("<Esc>");

    // The hints say what Enter does now, and offer the plan while changes are pending.
    explorer.type("S");
    explorer.type("S");
    explorer.type("G");

    auto shown = hints(explorer.view, explorer.state, explorer.context());

    check(shown.items[0].keys.view() == "<CR>" && shown.items[0].label.view() == "insert → 3 zsh");
    check(shown.items[1].keys.view() == ":w" && shown.items[1].label.view() == "write 2");
    explorer.focused = 12;
    shown = hints(explorer.view, explorer.state, explorer.context());
    check(shown.items[0].label.view() == "open → 2 nvim");
    explorer.type("gg");
    shown = hints(explorer.view, explorer.state, explorer.context());
    check(shown.items[0].label.view() == "enter", "a directory is entered");

    const auto listed = lenses(explorer.view, explorer.state, explorer.context());

    check(listed[0].current && listed[1].name == "changes" && listed[1].count == 3 && listed[2].name == "touched" && listed[2].counted && listed[2].count == 0 && listed[3].name == "panes" && listed[3].count == 3);
    explorer.type("gt");
    line = status(explorer.view, explorer.state, explorer.context(), 0);
    check(line.total.view().empty() && line.count == 3, "the list of changes says no size");
  }

  void testThePreviewSaysWhatIsKnownOfTheSelection() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");

    constexpr std::uint64_t now = 60 + 17 * 3600;
    const auto shown = preview(explorer.view, explorer.state, explorer.context(), now);

    check(shown.shown && !shown.directory && shown.name.view() == "usage.md" && shown.path.view() == "/home/dev/telar/docs/usage.md");
    check(shown.fact_count == 5 && shown.facts[0].label == "Size" && shown.facts[0].value.view() == "7.6K" && shown.facts[0].detail.view() == "7739 B");
    check(shown.facts[1].label == "Modified" && shown.facts[1].value.view() == "17 h ago");
    check(shown.facts[2].label == "Git" && shown.facts[2].value.view() == "modified, not staged" && shown.facts[2].added == 12 && shown.facts[2].removed == 7);
    check(shown.facts[3].label == "Last commit" && shown.facts[3].value.view() == "31d2299b4 · 2026-11-08" && shown.facts[3].detail.view() == "Describe the usage");
    check(shown.facts[4].label == "Machine" && shown.facts[4].value.view() == "macbook");
    check(shown.diff && previewText(explorer.view, explorer.state).starts_with("@@ -1,2") && !shown.waiting, "its diff, when it has changes not committed");

    explorer.type("k");

    const auto staged = preview(explorer.view, explorer.state, explorer.context(), now);

    check(staged.facts[2].value.view() == "new, staged" && !staged.diff && previewText(explorer.view, explorer.state) == "# Usage\n", "else the head of its text");

    explorer.type("gg");

    const auto directory = preview(explorer.view, explorer.state, explorer.context(), now);

    check(directory.directory && directory.facts[0].value.view() == "6.5M" && directory.facts[0].detail.view().empty() && previewText(explorer.view, explorer.state).empty());
    explorer.type("j");
    check(preview(explorer.view, explorer.state, explorer.context(), now).facts[1].value.view() == "2 changed below" && preview(explorer.view, explorer.state, explorer.context(), now).pane_count == 1);
  }

  void testThePreviewOfADirectoryListsItsHeaviest() {
    Explorer explorer;

    explorer.start();
    explorer.type("l");
    check(explorer.selected() == "/home/dev/telar/docs");
    check(preview(explorer.view, explorer.state, explorer.context(), 0).heavy_count == 0, "a directory in it is not measured: a list would name the wrong ones");
    explorer.type("gg");
    check(preview(explorer.view, explorer.state, explorer.context(), 0).heavy_count == 0, "nor is one the window does not list");

    Explorer measured;

    measured.sizes["/home/dev/telar/docs"] = {{"images", 2500000}};
    measured.start();
    measured.type("l");

    const auto shown = preview(measured.view, measured.state, measured.context(), 0);

    check(shown.heavy_count == 4, "what it holds, the heaviest first, and no more than a handful");
    check(shown.heavy[0].name.view() == "images" && shown.heavy[0].directory && shown.heavy[0].size.view() == "2.4M" && shown.heavy[0].share == 99);
    check(shown.heavy[1].name.view() == "usage.md" && !shown.heavy[1].directory && shown.heavy[1].size.view() == "7.6K" && shown.heavy[1].share == 0);
    check(shown.heavy[2].name.view() == "agents.md" && shown.heavy[3].name.view() == "remote.md");
  }

  void testALineOfThePlanSaysItsSizeAndWhatToKnow() {
    Explorer explorer;

    explorer.start();
    explorer.type("l4j");
    check(explorer.selected() == "/home/dev/telar/docs/usage.md");

    // A copy onto a name that is taken takes another, or replaces it when `:w!` says so.
    explorer.type("yyp");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.mode == Mode::plan && explorer.view.plan.size() == 1 && explorer.view.plan[0].verb == PlanVerb::copy);

    const auto copied = planNote(explorer.view, explorer.state, explorer.view.plan[0], {.touched = false});

    check(copied.size.view() == "7.6K" && copied.warning.view() == "its name is taken: it takes another");
    explorer.type("n");
    explorer.type(":");
    explorer.enter("w!");
    check(planNote(explorer.view, explorer.state, explorer.view.plan[0], {.touched = true}).warning.view() == "replaces what is there, which goes to the trash · an agent touched it since it was listed");
    explorer.type("n");
    explorer.type("u");

    // A directory goes to the trash with what it holds, and a file alone says nothing.
    explorer.type("ggjdd");
    explorer.type("jjjjdd");
    explorer.type(":");
    explorer.enter("w");
    check(explorer.view.plan.size() == 2 && explorer.view.plan[0].verb == PlanVerb::remove);

    const auto& tree = explorer.view.plan[0].directory ? explorer.view.plan[0] : explorer.view.plan[1];
    const auto& file = explorer.view.plan[0].directory ? explorer.view.plan[1] : explorer.view.plan[0];

    check(planNote(explorer.view, explorer.state, tree, {.touched = false}).warning.view() == "with all it holds" && planNote(explorer.view, explorer.state, tree, {.touched = false}).size.view() == "3.6M");
    check(planNote(explorer.view, explorer.state, file, {.touched = false}).warning.view().empty() && !planNote(explorer.view, explorer.state, file, {.touched = false}).size.view().empty());
  }

  // The texts of the help's lines, each `keys|label`, to find one by what it does.
  std::string helpKeys(const View& view, std::string_view label) {
    const auto shown = help(view);

    for (const auto& line : shown.lines.view().first(shown.count)) {
      if (std::string_view{line.label} == label) {
        return std::string{line.keys.view()};
      }
    }

    return "<no such line>";
  }

  std::string hintKeys(const Explorer& explorer, std::string_view label) {
    const auto shown = hints(explorer.view, explorer.state, explorer.context());

    for (const auto& hint : shown.items.view().first(shown.count)) {
      if (hint.label.view() == label) {
        return std::string{hint.keys.view()};
      }
    }

    return "<no such hint>";
  }

  std::string menuKeys(const Explorer& explorer, std::string_view label) {
    const auto shown = menu(explorer.view, explorer.state, explorer.context());

    for (const auto& line : shown.lines.view().first(shown.count)) {
      if (line.label.view() == label) {
        return std::string{line.keys.view()};
      }
    }

    return "<no such line>";
  }

  void testTheHelpTheHintsAndTheMenuShowTheKeysThatAreBound() {
    Explorer explorer;

    explorer.start();
    check(helpKeys(explorer.view, "down, up; with a count") == "j k" && helpKeys(explorer.view, "rename on the row") == "cw i a" && helpKeys(explorer.view, "the next window, the one that way") == "<C-w>w <C-w>hjkl");
    check(helpKeys(explorer.view, "set a mark, jump to it") == "ma 'a" && helpKeys(explorer.view, "copy, cut, paste; Control too") == "<D-c> <D-x> <D-v>" && helpKeys(explorer.view, "show the plan; overwrite what exists") == ":w :w!");
    check(hintKeys(explorer, "cut") == "dd" && hintKeys(explorer, "help") == "?");

    // `x` cuts and `dd` no longer does; staging has no key; `<D-c>` copies nothing; `K` goes up.
    telar::runtime::config::ExplorerKeys changed;
    const auto change = [&](std::string_view sequence, Command command) {
      telar::runtime::config::ExplorerKey key{.command = command};

      key.keys.assign(sequence);
      check(changed.put(key));
    };

    change("x", Command::cut);
    change("dd", Command::none);
    change("ga", Command::none);
    change("<D-c>", Command::none);
    change("K", Command::up);
    change("?", Command::none);
    change("<C-w>j", Command::none);
    check(configure(explorer.view, changed) && !configure(explorer.view, changed), "the keys are built when the configuration changes them, and not again");

    check(helpKeys(explorer.view, "cut: deletes, or moves once pasted") == "x" && helpKeys(explorer.view, "down, up; with a count") == "j K");
    check(helpKeys(explorer.view, "stage, unstage") == "gu" && helpKeys(explorer.view, "this help").empty(), "a command no key names shows none");
    check(helpKeys(explorer.view, "copy, cut, paste; Control too") == "<D-x> <D-v>" && helpKeys(explorer.view, "the next window, the one that way") == "<C-w>w <C-w>hkl");
    check(hintKeys(explorer, "cut") == "x" && hintKeys(explorer, "stage") == "<no such hint>" && hintKeys(explorer, "help") == "<no such hint>" && hintKeys(explorer, "unstage") == "gu");

    // The menu of a row teaches the same keys.
    openMenu(explorer.view, explorer.state, explorer.context(), {.window = explorer.view.current, .row = explorer.at("justfile")});
    check(explorer.view.mode == Mode::menu);
    check(menuKeys(explorer, "Cut") == "x" && menuKeys(explorer, "Move to the trash") == "<Del>" && menuKeys(explorer, "Open a shell here") == "s" && menuKeys(explorer, "Copy") == "yy" && menuKeys(explorer, "New directory") == "o …/");
  }

  const telar::testing::Case case_bound_keys{"presentation.the_help_the_hints_and_the_menu_show_the_keys_that_are_bound", testTheHelpTheHintsAndTheMenuShowTheKeysThatAreBound};

  const telar::testing::Case case_heaviest{"presentation.the_preview_of_a_directory_lists_its_heaviest", testThePreviewOfADirectoryListsItsHeaviest};
  const telar::testing::Case case_plan_note{"presentation.a_line_of_the_plan_says_its_size_and_what_to_know", testALineOfThePlanSaysItsSizeAndWhatToKnow};
  const telar::testing::Case case_sizes{"presentation.sizes_and_ages_read_as_a_person_says_them", testSizesAndAgesReadAsAPersonSaysThem};
  const telar::testing::Case case_typed{"presentation.a_path_is_typed_as_a_person_would", testAPathIsTypedAsAPersonWould};
  const telar::testing::Case case_window{"presentation.the_window_says_where_it_is_and_what_applies_now", testTheWindowSaysWhereItIsAndWhatAppliesNow};
  const telar::testing::Case case_preview{"presentation.the_preview_says_what_is_known_of_the_selection", testThePreviewSaysWhatIsKnownOfTheSelection};

}
