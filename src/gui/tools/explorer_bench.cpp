// What the explorer costs the window between a key and what it draws, measured without a
// window: building the rows of a directory with many entries, moving the selection, sorting,
// filtering, and reading what a page of rows, the header, the status line, the hints and the
// preview show. The directory, its sizes and what git says of it are answered here as a runtime
// would. Each workload is timed over many repetitions; the output is one JSON object each.
//
//   explorer-bench [--entries N] [--iterations N]

#include <cstdio>

import std;
import telar.base.memory.allocators;
import telar.config.client;
import telar.gui.features.explorer;
import telar.gui.foundation.keys;
import telar.wire.files;
import telar.wire.runtime;
import telar.wire.vocabulary;

namespace {

  using namespace telar;
  using namespace telar::gui;
  using namespace telar::gui::features::explorer;
  using Clock = std::chrono::steady_clock;

  constexpr std::uint64_t machine = 1;
  constexpr std::string_view root = "/home/dev/project";
  // The rows a window of an ordinary height shows.
  constexpr std::size_t page_rows = 40;

  // The nanoseconds of each repetition, for the quantiles a latency is read by.
  class Samples {
  public:
    void add(Clock::duration elapsed) {
      values_.push_back(std::chrono::duration_cast<std::chrono::nanoseconds>(elapsed).count());
    }

    [[nodiscard]] double quantile(double fraction) {
      constexpr double microsecond = 1000;

      if (values_.empty()) {
        return 0;
      }

      std::ranges::sort(values_);
      return static_cast<double>(values_[std::min(values_.size() - 1, static_cast<std::size_t>(fraction * static_cast<double>(values_.size())))]) / microsecond;
    }

  private:
    std::vector<std::int64_t> values_;
  };

  // An explorer on one directory of `entries` entries, a tenth of them directories and a tenth
  // of its files changed, whose runtime this answers for.
  struct Bench {
    explicit Bench(std::size_t entries) {
      constexpr std::size_t every = 10;
      constexpr std::uint64_t file_bytes = 4096;

      names.reserve(entries);
      for (std::size_t index = 0; index < entries; ++index) {
        names.push_back(std::format("entry-{:06}{}", index, index % every == 0 ? "" : ".md"));
      }

      for (std::size_t index = 0; index < entries; ++index) {
        const bool directory = index % every == 0;

        listed.push_back({.name = names[index], .kind = directory ? FileKind::directory : FileKind::file, .directory = directory, .size = directory ? 0 : file_bytes + index, .identity = {.inode = index + 1, .modified_seconds = index}});
        if (index % every == 1) {
          changed.push_back({.path = names[index], .unstaged = FileState::modified, .added = 3, .removed = 1});
        }
      }

      panes.push_back(PaneFact{.id = 1, .number = 1, .kind = features::explorer::PaneKind::shell, .title = "zsh", .cwd = root});
    }

    [[nodiscard]] Context context() const {
      return {.panes = panes, .focused = 1, .workspace = root, .home = "/home/dev", .machine = "bench", .local = true};
    }

    // Answers what the explorer lacks, a page of a listing at a time, until it lacks nothing.
    void answer() {
      while (const auto wanted = need(view, state, machine)) {
        const auto request = ++requests;
        const std::string path{wanted->path};

        switch (wanted->kind) {
        case NeedKind::listing: {
          const auto asking = listing(state, path);
          const auto first = std::min<std::size_t>(asking.skip, listed.size());
          const auto count = path == root ? std::min<std::size_t>(asking.limit, listed.size() - first) : 0;

          asked(state, *wanted, request);
          static_cast<void>(receive(state, DirectoryContents{.request_id = request, .path = path, .skip = static_cast<std::uint32_t>(first), .total = path == root ? static_cast<std::uint32_t>(listed.size()) : 0, .entries = std::span<const DirectoryEntry>{listed}.subspan(first, count)}));
          break;
        }
        case NeedKind::sizes:
          asked(state, *wanted, request);
          static_cast<void>(receive(state, DirectorySizes{.request_id = request, .path = path}));
          break;
        case NeedKind::changes:
          asked(state, *wanted, request);
          static_cast<void>(receive(state, RepositoryChanges{.request_id = request, .path = path, .root = root, .branch = "main", .changes = changed}));
          break;
        case NeedKind::inspection:
          asked(state, *wanted, request);
          static_cast<void>(receive(state, FileInspection{.request_id = request, .path = path, .size = 4096, .text = "A line of a file.\n", .diff = "@@ -1 +1 @@\n-old\n+new\n"}));
          break;
        }
      }

      rebuild(view, state, context(), machine);
    }

    Action key(char character) {
      KeyChord chord{.key = KeyChord::Key::character};

      chord.character = KeyCharacter::pack(static_cast<std::uint32_t>(static_cast<unsigned char>(character)));
      return press(view, state, context(), chord);
    }

    // What the window reads to draw after a key: a page of rows and everything around them.
    [[nodiscard]] std::size_t draw() const {
      const auto& shown = window(view);
      const auto seen = context();
      std::size_t read = 0;

      for (std::size_t row = shown.top; row < shown.rows.size() && row < shown.top + page_rows; ++row) {
        read += look(view, state, seen, {.window = view.current, .row = row}).name.view().size();
      }

      read += header(view, state, seen, view.current).last.view().size();
      read += status(view, state, seen, view.current).root.view().size();
      read += hints(view, state, seen).count;
      read += lenses(view, state, seen)[0].count;
      read += preview(view, state, seen, 0).fact_count;
      return read;
    }

    SystemAllocator upstream;
    telar::MemoryAdapter<SystemAllocator> adapter{upstream};
    telar::Memory& memory = adapter;
    State state{memory};
    View view{memory};
    std::vector<std::string> names;
    std::vector<DirectoryEntry> listed;
    std::vector<FileChange> changed;
    std::vector<PaneFact> panes;
    std::uint64_t requests = 0;
  };

  template <typename Work>
  void run(std::string_view name, std::size_t size, std::size_t iterations, const Work& work) {
    Samples samples;

    for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
      const auto start = Clock::now();

      work();
      samples.add(Clock::now() - start);
    }

    std::println(R"({{"workload":"{}","size":{},"iterations":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", name, size, iterations, samples.quantile(0.5), samples.quantile(0.99));
  }

  std::size_t number(std::string_view text, std::size_t fallback) {
    std::size_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);

    return parsed.ec == std::errc{} && value != 0 ? value : fallback;
  }

}

int main(int argc, char** argv) {
  std::size_t entries = 5000;
  std::size_t iterations = 500;
  const std::span<char*> arguments{argv, static_cast<std::size_t>(argc)};

  for (std::size_t index = 1; index + 1 < arguments.size(); index += 2) {
    const std::string_view name{arguments[index]};

    if (name == "--entries") {
      entries = number(arguments[index + 1], entries);
    } else if (name == "--iterations") {
      iterations = number(arguments[index + 1], iterations);
    }
  }

  Bench bench{entries};
  std::size_t read = 0;

  open(bench.view, bench.state, bench.context(), machine);
  bench.answer();

  const auto rows = window(bench.view).rows.size();

  run("rebuild", rows, iterations, [&] {
    rebuild(bench.view, bench.state, bench.context(), machine);
  });
  run("key.j", rows, iterations, [&] {
    static_cast<void>(bench.key('j'));
  });
  run("draw.page", page_rows, iterations, [&] {
    read += bench.draw();
  });
  run("key.j+draw", page_rows, iterations, [&] {
    static_cast<void>(bench.key('j'));
    bench.answer();
    read += bench.draw();
  });
  run("key.S (sort)", rows, iterations, [&] {
    static_cast<void>(bench.key('S'));
  });
  run("key.G", rows, iterations, [&] {
    static_cast<void>(bench.key('G'));
  });

  // A filter of two letters, as it is typed.
  static_cast<void>(bench.key('/'));
  run("filter", rows, iterations, [&] {
    typed(bench.view, bench.state, bench.context(), "99");
    typed(bench.view, bench.state, bench.context(), "9");
  });

  std::println(stderr, "read {} bytes of what the rows show", read);
  return 0;
}
