import std;
import telar.testing;
import telar.gui.features.explorer;

namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::gui::features::explorer;

  void testSizesAndAgesReadAsAPersonSaysThem() {
    check(bytes(0).view() == "0B" && bytes(512).view() == "512B" && bytes(7739).view() == "7.6K" && bytes(110592).view() == "108K");
    check(bytes(2621440).view() == "2.5M" && bytes(107374182400).view() == "100G", "one decimal below ten of a unit, none from ten on");
    check(age(100, 130).view() == "1 min" && age(0, 61200).view() == "17 h" && age(0, 3 * 86400).view() == "3 d");
    check(day(1794096000).view() == "2026-11-08");
  }

  const telar::testing::Case case_sizes{"explorer.sizes_and_ages_read_as_a_person_says_them", testSizesAndAgesReadAsAPersonSaysThem};

}
