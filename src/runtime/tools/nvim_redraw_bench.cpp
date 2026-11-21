// What the runtime does for each redraw of an embedded Neovim, measured without one: decoding
// the redraw into the screen, and writing what a client lacks as the messages of a frame. The
// redraws are the ones the common moves produce: a key typed, a line scrolled, a screen drawn
// whole. Each is timed over many repetitions; the output is one JSON object per workload.
//
//   nvim-redraw-bench [--columns N] [--rows N] [--iterations N]

#include <cstdio>

import std;
import telar.msgpack;
import telar.testing.test_memory;
import telar.base.ds;
import telar.base.memory.allocators;
import telar.runtime.nvim.frames;
import telar.runtime.nvim.redraw;
import telar.runtime.nvim.screen;

namespace {

  using namespace telar;
  using namespace telar::runtime;
  using Clock = std::chrono::steady_clock;

  struct Options {
    std::uint32_t columns = 200;
    std::uint32_t rows = 60;
    std::size_t iterations = 2000;
  };

  // The nanoseconds of each repetition, for the quantiles a latency is read by.
  class Samples {
  public:
    void add(Clock::duration elapsed) {
      values_.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
    }

    [[nodiscard]] std::int64_t quantile(double fraction) {
      if (values_.empty()) {
        return 0;
      }

      std::ranges::sort(values_);
      return values_[std::min(values_.size() - 1, static_cast<std::size_t>(fraction * static_cast<double>(values_.size())))];
    }

  private:
    std::vector<std::int64_t> values_;
  };

  // One redraw notification under construction: `[2, "redraw", [event...]]`.
  class Batch {
  public:
    explicit Batch(std::size_t capacity)
        : bytes_(capacity),
          writer_(bytes_) {}

    void begin(std::uint32_t events) {
      writer_ = msgpack::Writer{bytes_};
      writer_.array(events + 1);
    }

    // A grid_line that draws `text` on `row` of the window's grid, each run with its highlight.
    void line(std::uint32_t row, std::string_view text, std::uint32_t highlight) {
      constexpr std::size_t run = 8;

      writer_.array(2);
      writer_.string("grid_line");
      writer_.array(5);
      writer_.unsignedInteger(2);
      writer_.unsignedInteger(row);
      writer_.unsignedInteger(0);
      writer_.array(static_cast<std::uint32_t>(text.size()));

      for (std::size_t index = 0; index < text.size(); ++index) {
        // A new highlight every few cells, as highlighted source has.
        const bool starts = index % run == 0;

        writer_.array(starts ? 2 : 1);
        writer_.string(text.substr(index, 1));
        if (starts) {
          writer_.unsignedInteger(highlight + ((index / run) % 6));
        }
      }

      writer_.boolean(false);
    }

    void integers(std::string_view name, std::initializer_list<std::int64_t> values) {
      writer_.array(2);
      writer_.string(name);
      writer_.array(static_cast<std::uint32_t>(values.size()));

      for (const auto value : values) {
        writer_.integer(value);
      }
    }

    void highlight(std::uint32_t id, std::uint32_t color) {
      writer_.array(2);
      writer_.string("hl_attr_define");
      writer_.array(4);
      writer_.unsignedInteger(id);
      writer_.map(1);
      writer_.string("foreground");
      writer_.unsignedInteger(color);
      writer_.map(0);
      writer_.array(0);
    }

    [[nodiscard]] std::span<const std::uint8_t> end() {
      writer_.array(2);
      writer_.string("flush");
      writer_.array(0);
      if (writer_.overflowed()) {
        throw std::runtime_error{"The benchmark's redraw does not fit its buffer"};
      }

      return writer_.written();
    }

  private:
    std::vector<std::uint8_t> bytes_;
    msgpack::Writer writer_;
  };

  std::string sourceLine(std::uint32_t columns, std::size_t seed) {
    static constexpr std::string_view words = "const auto value = screen.grid(index); if (value != nullptr) { return value->rows; } // telar ";
    std::string text;

    while (text.size() < columns) {
      text += words.substr(seed % 17, words.size() - (seed % 17));
      ++seed;
    }

    text.resize(columns);
    return text;
  }

  // What one workload measured: the redraw's bytes and how long the runtime took to decode it,
  // then the frame's bytes and messages and how long they took to write.
  struct Result {
    std::string_view name;
    std::size_t redraw_bytes = 0;
    std::size_t frame_bytes = 0;
    std::size_t frame_messages = 0;
    Samples decode;
    Samples encode;
  };

  // Writes the frame a client that has frame `seen` lacks, as the delivery does, and counts it.
  void encode(NvimFrames& frames, const NvimScreen& screen, std::uint64_t seen, Result& result) {
    std::size_t bytes = 0;
    std::size_t messages = 0;

    frames.begin(screen, {.pane_id = 1, .seen = seen});
    for (auto grid = frames.next(screen); !grid.empty(); grid = frames.next(screen)) {
      bytes += grid.size();
      ++messages;
    }

    bytes += frames.end(screen).size();
    result.frame_bytes = bytes;
    result.frame_messages = messages + 1;
  }

  void print(Result& result, const Options& options) {
    std::println(
        R"({{"workload":"{}","grid":"{}x{}","redraw_bytes":{},"decode_ns_p50":{},"decode_ns_p99":{},"frame_bytes":{},"frame_messages":{},"encode_ns_p50":{},"encode_ns_p99":{}}})",
        result.name,
        options.columns,
        options.rows,
        result.redraw_bytes,
        result.decode.quantile(0.5),
        result.decode.quantile(0.99),
        result.frame_bytes,
        result.frame_messages,
        result.encode.quantile(0.5),
        result.encode.quantile(0.99)
    );
  }

  int run(const Options& options) {
    // The screen and the encoder keep their buffers between frames, so what is timed allocates
    // nothing once the first frames have grown them.
    testing::TestMemory adapter;
    ConcurrentMemory& memory = adapter;
    NvimScreen screen{memory};
    NvimFrames frames{memory};
    Batch batch{std::size_t{8} * 1024 * 1024};
    const auto columns = options.columns;
    const auto rows = options.rows;

    // The screen an editor starts with: the default grid, a window over it, and its colors.
    batch.begin(rows + 10);
    batch.integers("grid_resize", {1, columns, rows});
    batch.integers("grid_resize", {2, columns, rows - 2});
    batch.integers("win_pos", {2, 1000, 0, 0, columns, rows - 2});
    batch.integers("default_colors_set", {0xdcdccc, 0x1f1f1f, 0xff0000, 0, 0});
    for (std::uint32_t id = 1; id <= 8; ++id) {
      batch.highlight(id, 0x808080 + (id * 0x0f0f0f));
    }

    for (std::uint32_t row = 0; row < rows - 2; ++row) {
      batch.line(row, sourceLine(columns, row), 1);
    }

    if (!applyRedraw(screen, batch.end(), memory).accepted) {
      throw std::runtime_error{"The benchmark's first redraw was refused"};
    }

    Result typing{.name = "key typed"};
    Result scrolling{.name = "one line scrolled"};
    Result repaint{.name = "screen drawn whole"};
    std::uint64_t seen = screen.flushed();

    for (std::size_t index = 0; index < options.iterations; ++index) {
      // A key typed in insert mode: the cursor's row is drawn again and the cursor moves.
      batch.begin(2);
      batch.line(10, sourceLine(columns, index), 1);
      batch.integers("grid_cursor_goto", {2, 10, static_cast<std::int64_t>(index % columns)});
      const auto typed = batch.end();
      auto started = Clock::now();

      static_cast<void>(applyRedraw(screen, typed, memory));
      typing.decode.add(Clock::now() - started);
      typing.redraw_bytes = typed.size();
      started = Clock::now();
      encode(frames, screen, seen, typing);
      typing.encode.add(Clock::now() - started);
      seen = screen.flushed();

      // One line scrolled: the rows move, the new one is drawn at the bottom.
      batch.begin(2);
      batch.integers("grid_scroll", {2, 0, rows - 2, 0, columns, 1, 0});
      batch.line(rows - 3, sourceLine(columns, index + 7), 1);
      const auto scrolled = batch.end();

      started = Clock::now();
      static_cast<void>(applyRedraw(screen, scrolled, memory));
      scrolling.decode.add(Clock::now() - started);
      scrolling.redraw_bytes = scrolled.size();
      started = Clock::now();
      encode(frames, screen, seen, scrolling);
      scrolling.encode.add(Clock::now() - started);
      seen = screen.flushed();
    }

    for (std::size_t index = 0; index < std::max<std::size_t>(1, options.iterations / 20); ++index) {
      // Every row drawn again, as a jump to another place in the file does.
      batch.begin(rows - 2);
      for (std::uint32_t row = 0; row < rows - 2; ++row) {
        batch.line(row, sourceLine(columns, row + index), 1);
      }

      const auto drawn = batch.end();
      auto started = Clock::now();

      static_cast<void>(applyRedraw(screen, drawn, memory));
      repaint.decode.add(Clock::now() - started);
      repaint.redraw_bytes = drawn.size();
      started = Clock::now();
      encode(frames, screen, seen, repaint);
      repaint.encode.add(Clock::now() - started);
      seen = screen.flushed();
    }

    print(typing, options);
    print(scrolling, options);
    print(repaint, options);
    return 0;
  }

}

int main(int argc, char** argv) {
  Options options;
  const std::span<char*> arguments{argv, static_cast<std::size_t>(argc)};

  try {
    for (std::size_t index = 1; index + 1 < arguments.size(); index += 2) {
      const std::string_view name = arguments[index];
      const auto value = std::stoull(arguments[index + 1]);

      if (name == "--columns") {
        options.columns = static_cast<std::uint32_t>(value);
      } else if (name == "--rows") {
        options.rows = static_cast<std::uint32_t>(value);
      } else if (name == "--iterations") {
        options.iterations = value;
      } else {
        std::println(stderr, "usage: nvim-redraw-bench [--columns N] [--rows N] [--iterations N]");
        return 2;
      }
    }

    if (options.columns < 20 || options.rows < 6 || options.columns * options.rows > 130000) {
      std::println(stderr, "nvim-redraw-bench: a grid of at least 20x6 and at most 130000 cells");
      return 2;
    }

    return run(options);
  } catch (const std::exception& error) {
    std::println(stderr, "nvim-redraw-bench: {}", error.what());
    return 1;
  }
}
