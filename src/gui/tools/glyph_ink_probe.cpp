// Draws the block, straight box and Braille glyphs as ui/kit/scene/cell_glyphs.hpp does (draw, then
// coverage() and rectangles()) and prints the time per frame of them as one JSON row, with a
// checksum of the ink that must match between builds. `--dump` prints every rectangle exactly
// instead, over a range of cell sizes, as the oracle of a change to the glyph geometry.
import std;

import telar.gui.foundation.core;
import telar.gui.foundation.fonts;
import telar.base.ds;

namespace {

  using namespace telar::gui;
  using namespace telar::gui::glyphs;

  constexpr telar::ds::Array<std::string_view, 6> workloads{"block", "quadrant", "slab", "box", "braille", "all"};
  constexpr std::uint32_t first_quadrant = 0x2596;
  constexpr std::uint64_t maximum_iterations = 100'000'000;
  constexpr float box_thickness = 1.5F;

  struct Options {
    std::string_view workload = "all";
    std::uint64_t iterations = 20'000;
    std::uint64_t warmup = 2'000;
    bool dump = false;
  };

  std::uint64_t number(std::string_view value) {
    std::uint64_t result = 0;
    const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
    if (std::make_error_code(parsed.ec) || parsed.ptr != value.data() + value.size() || result > maximum_iterations) {
      throw std::invalid_argument{"Expected an iteration count up to 100000000"};
    }

    return result;
  }

  Options parseOptions(std::span<char*> arguments) {
    Options options;

    for (std::size_t index = 1; index < arguments.size(); ++index) {
      const std::string_view name = arguments[index];
      if (name == "--dump") {
        options.dump = true;
        continue;
      }

      if (index + 1 == arguments.size()) {
        throw std::invalid_argument{"Missing value after an option"};
      }

      const std::string_view value = arguments[++index];
      if (name == "--workload" && std::ranges::contains(workloads, value)) {
        options.workload = value;
      } else if (name == "--iterations") {
        options.iterations = number(value);
      } else if (name == "--warmup") {
        options.warmup = number(value);
      } else {
        throw std::invalid_argument{"Usage: gui-glyph-ink-probe [--workload block|quadrant|slab|box|braille|all] [--iterations N] [--warmup N] [--dump]"};
      }
    }

    return options;
  }

  template <std::size_t Capacity>
  double consume(const Ink<Capacity>& ink) {
    // Each field weighs differently, so the checksum tells swapped fields apart.
    constexpr float y_weight = 2;
    constexpr float width_weight = 3;
    constexpr float height_weight = 5;
    double sum = ink.coverage();

    for (const auto rectangle : ink.rectangles()) {
      sum += rectangle.x + (y_weight * rectangle.y) + (width_weight * rectangle.width) + (height_weight * rectangle.height);
    }

    return sum;
  }

  bool straightBox(std::uint32_t codepoint) noexcept {
    return codepoint < Symbol::first_box_curve || codepoint > Symbol::last_box_curve;
  }

  // One frame of the workload, in a cell that moves over an 80x24 grid of 9x18 cells.
  double frame(std::uint64_t step, std::string_view workload) {
    const Rect cell{.x = static_cast<float>(step % 80) * 9, .y = static_cast<float>(step % 24) * 18, .width = 9, .height = 18};
    const auto all = workload == "all";
    double sum = 0;

    if (all || workload == "block" || workload == "quadrant" || workload == "slab") {
      for (auto codepoint = Symbol::first_block; codepoint <= Symbol::last_block; ++codepoint) {
        const auto quadrant = codepoint >= first_quadrant;
        if ((workload == "quadrant" && !quadrant) || (workload == "slab" && quadrant)) {
          continue;
        }

        sum += consume(Block::draw(cell, codepoint));
      }
    }

    if (all || workload == "box") {
      for (auto codepoint = Symbol::first_box; codepoint <= Symbol::last_box; ++codepoint) {
        if (straightBox(codepoint)) {
          sum += consume(Box::draw(codepoint, cell, box_thickness));
        }
      }
    }

    if (all || workload == "braille") {
      for (unsigned dots = 0; dots <= std::numeric_limits<std::uint8_t>::max(); ++dots) {
        sum += consume(Braille::draw(cell, static_cast<std::uint8_t>(dots)));
      }
    }

    return sum;
  }

  template <std::size_t Capacity>
  void print(const Ink<Capacity>& ink) {
    std::print("{:a}", ink.coverage());

    for (const auto rectangle : ink.rectangles()) {
      std::print(" {:a},{:a},{:a},{:a}", rectangle.x, rectangle.y, rectangle.width, rectangle.height);
    }

    std::println();
  }

  void dumpCell(const Rect& cell) {
    for (auto codepoint = Symbol::first_block; codepoint <= Symbol::last_block; ++codepoint) {
      print(Block::draw(cell, codepoint));
    }

    for (auto codepoint = Symbol::first_box; codepoint <= Symbol::last_box; ++codepoint) {
      if (straightBox(codepoint)) {
        print(Box::draw(codepoint, cell, box_thickness));
      }
    }

    for (unsigned dots = 0; dots <= std::numeric_limits<std::uint8_t>::max(); ++dots) {
      print(Braille::draw(cell, static_cast<std::uint8_t>(dots)));
    }
  }

  // Every glyph in cells from 0x0 to 40x80, by quarter pixels across and three quarters down.
  void dump() {
    constexpr int widest_quarters = 160;
    constexpr int tallest_quarters = 320;

    for (int width = 0; width <= widest_quarters; ++width) {
      for (int height = 0; height <= tallest_quarters; height += 3) {
        const Rect cell{.x = 1.25F, .y = 2.5F, .width = static_cast<float>(width) / 4, .height = static_cast<float>(height) / 4};

        dumpCell(cell);
      }
    }
  }

}

int main(int argc, char** argv) {
  try {
    const auto options = parseOptions(std::span{argv, static_cast<std::size_t>(argc)});
    if (options.dump) {
      dump();
      return 0;
    }

    double checksum = 0;

    for (std::uint64_t step = 0; step < options.warmup; ++step) {
      checksum += frame(step, options.workload);
    }

    checksum = 0;
    const auto start = std::chrono::steady_clock::now();

    for (std::uint64_t step = 0; step < options.iterations; ++step) {
      checksum += frame(step, options.workload);
    }

    const auto elapsed = std::chrono::steady_clock::now() - start;

    std::println(R"({{"workload":"{}","iterations":{},"warmup":{},"elapsed_ns":{},"checksum":"{:a}"}})", options.workload, options.iterations, options.warmup, std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count(), checksum);
  } catch (const std::exception& error) {
    std::cerr << error.what() << '\n';
    return 1;
  }
}
