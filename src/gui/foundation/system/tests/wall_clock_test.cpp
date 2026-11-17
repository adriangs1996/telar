#ifdef __clangd__
// Keep textual ABI declarations and module imports in one clangd parse.
static_assert(true);
#endif

#include <cstdint>
#include <cstdlib>
#include <ctime>

import std;
import telar.testing;
import telar.gui.foundation.system;

namespace {

  using telar::testing::check;

  std::int64_t epochMilliseconds() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count();
  }

  // The UTC offsets, in minutes, of the zones the cases sample in.
  constexpr std::int16_t nepal_offset = 345;
  constexpr std::int16_t newfoundland_offset = -210;
  constexpr std::int16_t line_islands_offset = 840;
  constexpr std::int16_t baker_island_offset = -720;

  // Each case runs in a process of its own, so the zone it sets is the one the clock reads.
  void sampleIn(const char* zone, std::int16_t offset) {
    // NOLINTNEXTLINE(concurrency-mt-unsafe): the case is the only thread of its process.
    check(::setenv("TZ", zone, 1) == 0, "the case must set its time zone");
    tzset();

    const auto before = epochMilliseconds();
    const auto sampled = telar::gui::system::WallClock::sample();
    const auto after = epochMilliseconds();

    check(sampled.now_ms >= before && sampled.now_ms <= after && sampled.utc_offset_min == offset, "Wall clock must sample epoch milliseconds and the native UTC offset");
  }

  void utc() {
    sampleIn("UTC0", 0);
  }

  void nepal() {
    sampleIn("NPT-5:45", nepal_offset);
  }

  void newfoundland() {
    sampleIn("NST3:30", newfoundland_offset);
  }

  void lineIslands() {
    sampleIn("LINT-14", line_islands_offset);
  }

  void bakerIsland() {
    sampleIn("IDLW12", baker_island_offset);
  }

  const telar::testing::Case case_utc{"wall_clock.utc", utc};
  const telar::testing::Case case_nepal{"wall_clock.nepal", nepal};
  const telar::testing::Case case_newfoundland{"wall_clock.newfoundland", newfoundland};
  const telar::testing::Case case_line_islands{"wall_clock.line_islands", lineIslands};
  const telar::testing::Case case_baker_island{"wall_clock.baker_island", bakerIsland};

}
