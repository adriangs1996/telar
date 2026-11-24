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

  void testTheHeadSaysHowFarTheBranchIsFromItsBase() {
    Explorer explorer;

    explorer.disk.base = "main";
    explorer.disk.ahead = 6;
    explorer.start();
    check(header(explorer.view, explorer.state, explorer.context(), 0).distance.view() == "↑6 main");

    // On the base itself there is a distance to say only when it has commits the base lacks.
    Explorer based;

    based.disk.base = "lifetime-speed";
    based.start();
    check(based.view.windows.size() == 1 && header(based.view, based.state, based.context(), 0).distance.view().empty());
    based.disk.ahead = 2;
    invalidate(based.state, {});
    based.answer();
    check(header(based.view, based.state, based.context(), 0).distance.view() == "↑2 lifetime-speed");

    // And none where git names no base.
    Explorer alone;

    alone.start();
    check(header(alone.view, alone.state, alone.context(), 0).distance.view().empty());
  }

  void testTheHintsOfAnEntryNotWrittenYetAreTheKeysThatActOnIt() {
    Explorer explorer;

    explorer.start();
    explorer.type("o");
    explorer.enter("notes/");

    const auto enabled = [&](std::string_view label) {
      const auto shown = hints(explorer.view, explorer.state, explorer.context());

      for (std::size_t index = 0; index < shown.count; ++index) {
        if (shown.items[index].label.view() == label) {
          return shown.items[index].enabled;
        }
      }

      check(false, "the hint shows");
      return false;
    };

    check(look(explorer.view, explorer.state, explorer.context(), {.window = 0, .row = window(explorer.view).cursor}).kind == RowKind::added);
    check(enabled("rename") && enabled("cut") && !enabled("copy"), "it is named again and dropped, and is not there to copy");
    explorer.type("dd");
    check(explorer.view.edits.empty(), "cutting it drops the change, as its preview says");
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
    const auto unfolded = preview(explorer.view, explorer.state, explorer.context(), now);

    check(unfolded.facts[1].label == "Entries" && unfolded.facts[1].value.view() == "4 of 4 visible", "a directory that is listed says how many of its entries the window lists");
    check(unfolded.facts[2].value.view() == "2 changed below" && unfolded.pane_count == 1);
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

    check(shown.heavy_count == 4, "what it holds, the heaviest first, and no more than seven");
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
    check(helpKeys(explorer.view, "down, up; with a count") == "j k <C-n> <C-p>" && helpKeys(explorer.view, "rename: stem, all, at its start, its end") == "cw cc i a" && helpKeys(explorer.view, "the next window, the one that way") == "<C-w>w <C-w>hjkl");
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

    check(helpKeys(explorer.view, "cut: deletes, or moves once pasted") == "x <Del>" && helpKeys(explorer.view, "down, up; with a count") == "j K <C-n> <C-p>");
    check(helpKeys(explorer.view, "stage, unstage") == "gu" && helpKeys(explorer.view, "this help").empty(), "a command no key names shows none");
    check(helpKeys(explorer.view, "copy, cut, paste; Control too") == "<D-x> <D-v>" && helpKeys(explorer.view, "the next window, the one that way") == "<C-w>w <C-w>hkl");
    check(hintKeys(explorer, "cut") == "x" && hintKeys(explorer, "stage") == "<no such hint>" && hintKeys(explorer, "help") == "<no such hint>" && hintKeys(explorer, "unstage") == "gu");

    // The menu of a row teaches the same keys.
    openMenu(explorer.view, explorer.state, explorer.context(), {.window = explorer.view.current, .row = explorer.at("justfile")});
    check(explorer.view.mode == Mode::menu);
    check(menuKeys(explorer, "Cut") == "x" && menuKeys(explorer, "Move to the trash") == "<Del>" && menuKeys(explorer, "Open a shell here") == "s" && menuKeys(explorer, "Copy") == "yy" && menuKeys(explorer, "New directory") == "o …/");
  }

  void testARowThatIsNoFileHasAPreviewOfItsOwn() {
    Explorer explorer;

    explorer.start();
    explorer.type("4gtjj");

    const auto pane = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(pane.shown && pane.kind == RowKind::pane && pane.name.view() == "3 zsh" && pane.path.view() == "/home/dev/telar · macbook");
    check(pane.fact_count == 2 && pane.facts[0].label == "Kind" && pane.facts[0].value.view() == "shell" && pane.facts[1].label == "Directory" && pane.facts[1].value.view() == "/home/dev/telar/docs");
    check(std::string_view{pane.note} == "Enter focuses this pane; a window that follows it goes to its directory." && previewText(explorer.view, explorer.state).empty());

    // An entry a change adds, not written yet.
    explorer.type("1gtggo");
    explorer.enter("notes/");

    const auto added = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(added.shown && added.kind == RowKind::added && added.directory && added.name.view() == "notes" && added.path.view() == "/home/dev/telar/notes");
    check(added.fact_count == 1 && added.facts[0].label == "Pending" && added.facts[0].value.view() == "create a directory");
    check(std::string_view{added.note}.starts_with("It does not exist until :w applies it."));

    // And what a paste brings.
    explorer.type("ggjjjyyggpG");

    const auto pasted = preview(explorer.view, explorer.state, explorer.context(), explorer.now);

    check(pasted.kind == RowKind::added && pasted.name.view() == "justfile" && pasted.facts[0].value.view() == "copy from macbook:/home/dev/telar/justfile" && pasted.facts[1].label == "Size" && pasted.facts[1].value.view() == "8.1K");

    // The question of taking the last plan back has its own hints.
    Explorer asked;

    asked.start();
    asked.view.wrote.push(Explorer::machine);
    asked.type("u");

    const auto asking = hints(asked.view, asked.state, asked.context());

    check(asking.count == 2 && asking.items[0].keys.view() == "y" && asking.items[0].label.view() == "take it back" && asking.items[1].label.view() == "leave it");
  }

  void testThePreviewListsSevenOfTheHeaviest() {
    Explorer explorer;

    explorer.files["/home/dev/telar/src"] = {{"a.cpp", false, 100}, {"b.cpp", false, 200}, {"c.cpp", false, 300}, {"d.cpp", false, 400}, {"e.cpp", false, 500}, {"f.cpp", false, 600}, {"g.cpp", false, 700}, {"h.cpp", false, 800}, {"i.cpp", false, 900}};
    explorer.start();
    explorer.type("jl");
    check(explorer.selected() == "/home/dev/telar/src");

    const auto shown = preview(explorer.view, explorer.state, explorer.context(), 0);

    check(shown.heavy_count == 7 && shown.heavy[0].name.view() == "i.cpp" && shown.heavy[6].name.view() == "c.cpp", "seven of them, the heaviest first");
  }

  // The value of the fact a preview shows under `label`; empty when it shows none.
  std::string factOf(const PreviewLook& look, std::string_view label) {
    for (std::size_t index = 0; index < look.fact_count; ++index) {
      if (std::string_view{look.facts[index].label} == label) {
        return std::string{look.facts[index].value.view()};
      }
    }

    return {};
  }

  void testThePreviewSaysHowManyEntriesTheWindowLists() {
    Explorer explorer;

    explorer.start();
    check(factOf(preview(explorer.view, explorer.state, explorer.context(), 0), "Entries").empty(), "a directory the window never listed says none");

    // From above, the repository is a row whose directory the window has listed: it holds two
    // dotfiles and a directory git ignores.
    explorer.type("-");
    check(explorer.selected() == "/home/dev/telar");
    check(factOf(preview(explorer.view, explorer.state, explorer.context(), 0), "Entries") == "5 of 8 visible");
    explorer.type("g.");
    check(factOf(preview(explorer.view, explorer.state, explorer.context(), 0), "Entries") == "7 of 8 visible", "the dotfiles count once the window lists them");
    explorer.type("gi");
    check(factOf(preview(explorer.view, explorer.state, explorer.context(), 0), "Entries") == "8 of 8 visible");
    explorer.type("g.");
    check(factOf(preview(explorer.view, explorer.state, explorer.context(), 0), "Entries") == "6 of 8 visible", "what git ignores, without the dotfiles");
  }

  const telar::testing::Case case_distance{"presentation.the_head_says_how_far_the_branch_is_from_its_base", testTheHeadSaysHowFarTheBranchIsFromItsBase};
  const telar::testing::Case case_added_hints{"presentation.the_hints_of_an_entry_not_written_yet_are_the_keys_that_act_on_it", testTheHintsOfAnEntryNotWrittenYetAreTheKeysThatActOnIt};
  const telar::testing::Case case_entries{"presentation.the_preview_says_how_many_entries_the_window_lists", testThePreviewSaysHowManyEntriesTheWindowLists};
  const telar::testing::Case case_no_file{"presentation.a_row_that_is_no_file_has_a_preview_of_its_own", testARowThatIsNoFileHasAPreviewOfItsOwn};
  const telar::testing::Case case_seven{"presentation.the_preview_lists_seven_of_the_heaviest", testThePreviewListsSevenOfTheHeaviest};
  const telar::testing::Case case_bound_keys{"presentation.the_help_the_hints_and_the_menu_show_the_keys_that_are_bound", testTheHelpTheHintsAndTheMenuShowTheKeysThatAreBound};

  const telar::testing::Case case_heaviest{"presentation.the_preview_of_a_directory_lists_its_heaviest", testThePreviewOfADirectoryListsItsHeaviest};
  const telar::testing::Case case_plan_note{"presentation.a_line_of_the_plan_says_its_size_and_what_to_know", testALineOfThePlanSaysItsSizeAndWhatToKnow};
  const telar::testing::Case case_sizes{"presentation.sizes_and_ages_read_as_a_person_says_them", testSizesAndAgesReadAsAPersonSaysThem};
  const telar::testing::Case case_typed{"presentation.a_path_is_typed_as_a_person_would", testAPathIsTypedAsAPersonWould};
  const telar::testing::Case case_window{"presentation.the_window_says_where_it_is_and_what_applies_now", testTheWindowSaysWhereItIsAndWhatAppliesNow};
  const telar::testing::Case case_preview{"presentation.the_preview_says_what_is_known_of_the_selection", testThePreviewSaysWhatIsKnownOfTheSelection};

}
