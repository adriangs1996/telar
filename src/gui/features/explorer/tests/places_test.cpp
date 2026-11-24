#include "explorer_fixture.hpp"
#include <cstdint>
#include <string_view>

import telar.base.ds;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using telar::gui::test::Explorer;

  // The runtime answers `next` what `places` gave it, as it does a window that opens its explorer.
  void recallIn(Explorer& next, const ds::Vec<KeptPlace, Memory>& places, std::uint16_t jump) {
    recalling(next.state, 77);
    check(receive(next.state, PlacesKept{.request_id = 77, .places = places.view(), .jump = jump}) && next.state.recall == Recall::answered);
    recall(next.view, next.state, next.context(Explorer::machine));
    check(next.state.recall == Recall::taken && next.state.remembered.empty());
  }

  // An explorer with a mark of each kind and a jump list: `a` on the machine it runs on, `B` on
  // the other one, and the steps that took it there.
  void wander(Explorer& explorer) {
    explorer.start();
    explorer.type("jma");
    explorer.type("gg<CR>");
    check(window(explorer.view).root.view() == "/home/dev/telar/assets");
    explorer.type("-");
    explorer.type("gm");
    explorer.type("jmB");
    check(explorer.here() == Explorer::box && explorer.selected() == "/home/ops/site");
  }

  void testMarksAndJumpsAreReadBackByTheWindowThatComesAfter() {
    Explorer first;

    check(!unkept(first.view), "an explorer nothing was done in has nothing to give");
    wander(first);
    check(unkept(first.view), "a mark set and a place left are places to keep");

    ds::Vec<KeptPlace, Memory> places{first.memory};
    const auto jump = keeping(places, first.view, first.context(Explorer::machine));

    check(places.size() == 2 + first.view.jumps.size() && jump == first.view.jump);
    check(places[0].letter == Byte{'a'} && places[0].machine.empty() && places[0].root == "/home/dev/telar/src" && places[0].selected.empty(), "the machine the window runs on has no label where it is kept, and a directory is marked as the root it becomes");
    check(places[1].letter == Byte{'B'} && places[1].machine == "box" && places[1].root == "/home/ops/site" && places[1].selected.empty());
    check(places[2].letter == Byte{0} && places[2].root == "/home/dev/telar", "the steps follow the marks, from the oldest");

    // The window that comes after it reads them when its explorer opens.
    Explorer next;

    next.start();
    recallIn(next, places, jump);
    check(!unkept(next.view), "what was only read is what the runtime keeps already");
    check(next.view.marks.size() == 2 && next.view.jumps.size() == first.view.jumps.size() && next.view.jump == first.view.jump);
    next.type("gg'a");
    check(window(next.view).root.view() == "/home/dev/telar/src" && next.here() == Explorer::machine, "a mark goes where it was set");
    next.type("'B");
    check(next.here() == Explorer::box && window(next.view).root.view() == "/home/ops/site", "one in upper case with its machine");
    check(unkept(next.view), "a jump is a change to keep");
  }

  void testAMarkTheExplorerHasIsNotReplaced() {
    Explorer first;

    wander(first);

    ds::Vec<KeptPlace, Memory> places{first.memory};
    const auto jump = keeping(places, first.view, first.context(Explorer::machine));
    Explorer next;

    // The person set a mark before the runtime answered: it stays, and the others are added.
    next.start();
    next.type("jjma");

    const auto marked = next.selected();

    recallIn(next, places, jump);
    check(next.view.marks.size() == 2 && unkept(next.view), "what the explorer had is given to the runtime with what it read");
    next.type("gg'a");
    check(next.selected() == marked && marked != places[0].selected);
  }

  void testAPlaceOfAMachineTheWindowDoesNotKeepIsKept() {
    Explorer first;

    wander(first);

    ds::Vec<KeptPlace, Memory> places{first.memory};
    const auto jump = keeping(places, first.view, first.context(Explorer::machine));
    Explorer next;

    // The next window keeps another machine where `box` was.
    next.machines[1].label = "vps";
    next.start();
    recallIn(next, places, jump);
    check(next.view.marks.size() == 2 && next.view.marks[1].machine == 0 && next.view.marks[1].away.view() == "box");
    next.type("'B");
    check(next.view.tone == Tone::error && next.view.message.view() == "Mark B is of box, which is no machine of this window" && next.here() == Explorer::machine);
    next.type(":");
    next.enter("marks");
    check(next.view.message.view() == "'a /home/dev/telar/src · 'B box:/home/ops/site");

    // It is given back as it was read, for a window that keeps the machine again.
    ds::Vec<KeptPlace, Memory> again{next.memory};

    static_cast<void>(keeping(again, next.view, next.context(Explorer::machine)));
    check(again.size() == places.size() && again[1].letter == Byte{'B'} && again[1].machine == "box" && again[1].root == "/home/ops/site");
  }

  void testWhatDoesNotFitIsLeftOut() {
    Explorer explorer;

    explorer.start();
    explorer.type("ma");

    // A step whose texts are longer than a runtime keeps ends the steps that are kept.
    auto& step = explorer.view.jumps.push(Place{explorer.memory});

    step.machine = Explorer::machine;
    step.root.assign(std::string(FileLimits::path_bytes + 1, 'x'));
    explorer.view.jump = explorer.view.jumps.size();

    ds::Vec<KeptPlace, Memory> places{explorer.memory};

    check(keeping(places, explorer.view, explorer.context(Explorer::machine)) == 0 && places.size() == 1 && places[0].letter == Byte{'a'});
  }

  const telar::testing::Case case_read_back{"places.marks_and_jumps_are_read_back_by_the_window_that_comes_after", testMarksAndJumpsAreReadBackByTheWindowThatComesAfter};
  const telar::testing::Case case_kept{"places.a_mark_the_explorer_has_is_not_replaced", testAMarkTheExplorerHasIsNotReplaced};
  const telar::testing::Case case_away{"places.a_place_of_a_machine_the_window_does_not_keep_is_kept", testAPlaceOfAMachineTheWindowDoesNotKeepIsKept};
  const telar::testing::Case case_fits{"places.what_does_not_fit_is_left_out", testWhatDoesNotFitIsLeftOut};

}
