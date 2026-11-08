#include "core/memory.hpp"
#include "core/terminal_size.hpp"
#include "telar_client/codecs/telar_cells.hpp"
#include "telar_client/codecs/telar_wire.hpp"
#include "telar_client/serializers/telar_cells.hpp"
#include "telar_client/serializers/telar_frame.hpp"
#include "terminal/screen.hpp"
#include <algorithm>
#include <array>
#include <charconv>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <exception>
#include <iostream>
#include <limits>
#include <span>
#include <stdexcept>
#include <string_view>
#include <system_error>
#include <vector>

namespace {

using namespace telar;
using namespace telar::gui;

enum class Workload : std::uint8_t {
  empty,
  cell,
  row,
  grid,
  snapshot,
  retained,
};

constexpr std::array<std::string_view, 6> workload_names{"delta-empty", "delta-one", "delta-row", "delta-full", "snapshot-full", "snapshot-retained"};
constexpr std::uint64_t maximum_iterations = 10'000'000;
constexpr std::size_t screen_budget = std::size_t{16} * 1024 * 1024;

struct Options {
  Workload workload = Workload::grid;
  std::uint64_t iterations = 10'000;
  std::uint64_t warmup = 5'000;
  std::uint16_t columns = 82;
  std::uint16_t rows = 21;
};

std::uint64_t number(std::string_view value) {
  std::uint64_t result = 0;
  const auto parsed = std::from_chars(value.data(), value.data() + value.size(), result);
  if (parsed.ec != std::errc{} || parsed.ptr != value.data() + value.size()) {
    throw std::invalid_argument{"Expected an unsigned integer"};
  }

  return result;
}

Options parseOptions(int argc, const char *const *argv) {
  Options result;
  for (int index = 1; index < argc; index += 2) {
    if (index + 1 >= argc) {
      throw std::invalid_argument{"Options require a value"};
    }

    const std::string_view key{argv[index]};
    const std::string_view value{argv[index + 1]};
    if (key == "--case") {
      const auto *found = std::ranges::find(workload_names, value);
      if (found == workload_names.end()) {
        throw std::invalid_argument{"Unknown screen workload"};
      }

      result.workload = static_cast<Workload>(found - workload_names.begin());
    } else if (key == "--iterations") {
      result.iterations = number(value);
    } else if (key == "--warmup") {
      result.warmup = number(value);
    } else if (key == "--columns" || key == "--rows") {
      const auto dimension = number(value);
      if (dimension == 0 || dimension > std::numeric_limits<std::uint16_t>::max()) {
        throw std::invalid_argument{"Invalid screen dimension"};
      }

      (key == "--columns" ? result.columns : result.rows) = static_cast<std::uint16_t>(dimension);
    } else {
      throw std::invalid_argument{"Unknown screen probe option"};
    }
  }

  if (result.iterations == 0 || result.iterations > maximum_iterations || result.warmup > maximum_iterations || static_cast<std::size_t>(result.columns) * result.rows > TerminalGrid::maximum_cells) {
    throw std::invalid_argument{"Screen probe exceeds iteration or grid limits"};
  }

  return result;
}

class ScreenProbe {
public:
  ScreenProbe(const ScreenProbe &) = delete;
  ScreenProbe &operator=(const ScreenProbe &) = delete;

  explicit ScreenProbe(Options options)
      : options_(options),
        memory_(upstream_, screen_budget),
        screen_(memory_),
        flags_(options.rows) {
    const auto count = static_cast<std::size_t>(options.columns) * options.rows;
    switch (options.workload) {
    case Workload::empty:
      changed_ = 0;
      break;
    case Workload::cell:
      changed_ = 1;
      break;
    case Workload::row:
      changed_ = options.columns;
      break;
    case Workload::grid:
    case Workload::snapshot:
    case Workload::retained:
      changed_ = count;
      break;
    }

    for (std::size_t variant = 0; variant < text_.size(); ++variant) {
      std::vector<Cell> cells(count);
      for (auto &cell : cells) {
        cell.text = std::span{text_}.subspan(variant, 1);
      }

      full_bytes_[variant].resize(CellRunCodec::encodedSize(cells));
      CellRunCodec::encode(cells, full_bytes_[variant]);
      const auto subset = std::span{cells}.first(changed_);
      delta_bytes_[variant].resize(CellRunCodec::encodedSize(subset));
      CellRunCodec::encode(subset, delta_bytes_[variant]);
    }

    frame_.pane_id = 1;
    frame_.frame_id = 1;
    frame_.cols = options.columns;
    frame_.rows = options.rows;
    frame_.scroll.total_rows = options.rows;
    frame_.text_metadata = TextMetadata{.row_flags = flags_};
    spans_[0] = {.start = 0, .count = static_cast<std::uint32_t>(count), .cells = full_bytes_[0]};
    frame_.spans = spans_;
    apply();
  }

  void run() {
    for (std::uint64_t index = 0; index < options_.warmup; ++index) {
      advance(index);
    }

    const auto allocations = memory_.allocations();
    const auto started = std::chrono::steady_clock::now();
    for (std::uint64_t index = 0; index < options_.iterations; ++index) {
      advance(options_.warmup + index);
    }

    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    verify(allocations);
    std::cout << R"({"case":")" << workload_names[static_cast<std::size_t>(options_.workload)]
              << R"(","columns":)" << options_.columns << ",\"rows\":" << options_.rows
              << ",\"iterations\":" << options_.iterations << ",\"warmup\":" << options_.warmup
              << ",\"elapsed_ns\":" << elapsed << ",\"screen_live_bytes\":" << memory_.liveBytes()
              << ",\"screen_peak_bytes\":" << memory_.peakBytes() << ",\"screen_allocations\":" << allocations
              << ",\"cell_bytes\":" << sizeof(CellValue) << "}\n";
  }

private:
  void advance(std::uint64_t index) {
    const auto snapshot = options_.workload == Workload::snapshot || options_.workload == Workload::retained;
    const auto variant = options_.workload == Workload::retained ? 0 : index % text_.size();
    frame_.base_frame_id = snapshot ? 0 : frame_.frame_id;
    ++frame_.frame_id;
    if (!snapshot) {
      frame_.text_metadata.reset();
    }

    spans_[0] = {.start = 0, .count = static_cast<std::uint32_t>(changed_), .cells = snapshot ? std::span<const Byte>{full_bytes_[variant]} : std::span<const Byte>{delta_bytes_[variant]}};
    frame_.spans = changed_ == 0 ? std::span<const FrameSpan>{} : spans_;
    apply();
  }

  void apply() {
    if (screen_.apply(frame_) != FrameApplication::applied) {
      throw std::runtime_error{"Screen probe frame was not applied"};
    }
  }

  void verify(std::size_t allocations) const {
    const auto last = options_.warmup + options_.iterations - 1;
    const auto variant = options_.workload == Workload::retained ? 0 : last % text_.size();
    if (screen_.frameId() != last + 2 || memory_.allocations() != allocations) {
      throw std::runtime_error{"Screen identity or warm allocation count changed unexpectedly"};
    }

    for (std::size_t index = 0; index < screen_.cells().size(); ++index) {
      const auto expected = index < changed_ ? text_[variant] : text_[0];
      const auto &cell = screen_.cells()[index];
      if (cell.width != CellWidth::single || cell.style != CellStyle{} || cell.length != 1 || cell.text[0] != expected) {
        throw std::runtime_error{"Screen probe final cells differ from the input"};
      }
    }
  }

  Options options_;
  SystemAllocator upstream_;
  BudgetAllocator<SystemAllocator> memory_;
  Screen<BudgetAllocator<SystemAllocator>> screen_;
  std::vector<Byte> flags_;
  std::array<Byte, 2> text_{'a', 'b'};
  std::array<std::vector<Byte>, 2> full_bytes_;
  std::array<std::vector<Byte>, 2> delta_bytes_;
  std::array<FrameSpan, 1> spans_;
  PaneFrame frame_;
  std::size_t changed_ = 0;
};

}

int main(int argc, char *const *argv) try {
  if (argc == 2 && std::string_view{argv[1]} == "--help") {
    std::cout << "gui-screen-probe [--case delta-empty|delta-one|delta-row|delta-full|snapshot-full|snapshot-retained] [--iterations N] [--warmup N] [--columns N] [--rows N]\n";

    return 0;
  }

  ScreenProbe{parseOptions(argc, argv)}.run();

  return 0;
} catch (const std::exception &error) {
  std::cerr << error.what() << '\n';

  return 1;
}
