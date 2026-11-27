// What the history costs a person typing into it, measured on a synthetic history of many runs:
// a query typed a character at a time in each search mode and through the captured outputs, the
// empty query the prompt opens with, queries scoped to a directory, the pages a browser scrolls
// through, and the run and the output an inspector reads. Each request goes through the history
// store as the worker's does, and its answer is encoded as a client gets it. The output is one
// JSON object per workload, with the quantiles of the requests it made.
//
//   history-store-bench [--runs N] [--database PATH] [--iterations N]
//   history-store-bench --check
//
// A database path that already holds a history is measured as it is, so a large one is made once
// and measured again after each change; without one the history lives in a temporary directory.
// The index is loaded before the first workload, as the runtime loads it when its reader idles.
//
// --check measures a fresh history of 100,000 runs and fails when a workload's p99 is over its
// budget: about ten times what a loaded four-core machine measures in a Release build, so a
// change that makes a keystroke ten times slower, as reading every run in SQL did (R1), fails it
// and the noise of a shared machine does not. `just bench-check` builds it and runs it.

#include <cstdio>
#include <cstdlib>
#include <unistd.h>

import std;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.runtime.history.event;
import telar.runtime.history.store;
import telar.runtime.transport.connection;
import telar.wire.history;
import telar.wire.vocabulary;
import telar.base.ds;

namespace {

  using namespace telar;
  using namespace telar::runtime;
  using Clock = std::chrono::steady_clock;

  constexpr std::size_t checked_runs = 100'000;

  struct Options {
    std::size_t runs = checked_runs;
    std::size_t iterations = 3;
    std::string database;
    bool check = false;
    bool sized = false;
  };

  // The p99 a workload may take at 100,000 runs under --check, in microseconds, in a Release
  // build: about ten times what a four-core machine shared with two other builds measured
  // (load 3 to 6), rounded up.
  struct Budget {
    std::string_view workload;
    double p99_us;
  };

  constexpr std::array budgets{
      Budget{.workload = "type.fuzzy.distinct", .p99_us = 25'000},
      Budget{.workload = "type.fuzzy", .p99_us = 75'000},
      Budget{.workload = "type.substring", .p99_us = 15'000},
      Budget{.workload = "type.substring.distinct", .p99_us = 20'000},
      Budget{.workload = "type.fuzzy.distinct.cwd", .p99_us = 50'000},
      Budget{.workload = "type.substring.cwd", .p99_us = 15'000},
      Budget{.workload = "type.prefix", .p99_us = 15'000},
      Budget{.workload = "type.prefix.distinct", .p99_us = 20'000},
      Budget{.workload = "type.regex", .p99_us = 150'000},
      Budget{.workload = "type.regex.distinct", .p99_us = 150'000},
      Budget{.workload = "type.output", .p99_us = 900'000},
      Budget{.workload = "empty.distinct", .p99_us = 5'000},
      Budget{.workload = "empty", .p99_us = 5'000},
      Budget{.workload = "scroll", .p99_us = 8'000},
      Budget{.workload = "scroll.distinct", .p99_us = 12'000},
      Budget{.workload = "inspect.entry", .p99_us = 2'000},
      Budget{.workload = "inspect.output", .p99_us = 1'000},
  };

  // A workload's p99, kept for --check.
  struct Measured {
    std::string workload;
    double p99_us = 0;
  };

  std::vector<Measured> measured;

  // The microseconds of each keystroke, for the quantiles a latency is read by.
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

    [[nodiscard]] std::size_t size() const noexcept {
      return values_.size();
    }

  private:
    std::vector<std::int64_t> values_;
  };

  // A Zipf draw over `count` ranks: a few commands run all the time, most only now and then.
  class Zipf {
  public:
    Zipf(std::size_t count, double exponent) {
      double total = 0;

      cumulative_.reserve(count);
      for (std::size_t rank = 1; rank <= count; ++rank) {
        total += 1.0 / std::pow(static_cast<double>(rank), exponent);
        cumulative_.push_back(total);
      }

      for (auto& value : cumulative_) {
        value /= total;
      }
    }

    std::size_t draw(std::mt19937_64& random) const {
      const double point = std::uniform_real_distribution<double>{0.0, 1.0}(random);

      return static_cast<std::size_t>(std::ranges::lower_bound(cumulative_, point) - cumulative_.begin());
    }

  private:
    std::vector<double> cumulative_;
  };

  constexpr std::array<std::string_view, 24> verbs{
      "git status",
      "git commit -m",
      "git checkout",
      "git push origin",
      "git log --oneline",
      "git diff",
      "cd",
      "ls -la",
      "vim",
      "make",
      "cargo build --release",
      "npm run",
      "kubectl get pods -n",
      "kubectl logs -f",
      "docker run --rm -it",
      "ssh",
      "grep -rn",
      "find . -name",
      "python3 -m pytest",
      "cmake --build out --target",
      "rg --hidden",
      "just domain-test",
      "curl -fsSL",
      "tar xzf",
  };

  constexpr std::array<std::string_view, 16> nouns{
      "src/runtime/history/store.cpp",
      "feature/login-page",
      "main",
      "deployment.yaml",
      "README.md",
      "build",
      "test",
      "api-server",
      "staging",
      "prod-db-01",
      "'TODO'",
      "*.cppm",
      "dev",
      "release-v2",
      "payments",
      "lib/base/history",
  };

  // The `index`th distinct command: a verb and an argument, numbered past the pool of arguments so
  // every index names a command of its own, as a message or a path makes most commands unique.
  std::string distinctCommand(std::size_t index) {
    const auto verb = verbs.at(index % verbs.size());
    const auto noun = nouns.at((index / verbs.size()) % nouns.size());
    const auto variant = index / (verbs.size() * nouns.size());

    if (variant == 0) {
      return std::format("{} {}", verb, noun);
    }

    return std::format("{} {}-{}", verb, noun, variant);
  }

  std::string directoryOf(std::size_t index) {
    return std::format("/home/user/projects/project-{:03}", index);
  }

  // What a run printed, for one run in four: a build's or a test's last lines, now and then with a
  // warning or an error the output search finds.
  std::string outputOf(std::size_t run, std::uint64_t roll) {
    constexpr std::array<std::string_view, 6> lines{
        "Compiling telar-runtime v0.1.0\n    Finished `release` profile [optimized] target(s) in 41.2s\n",
        "warning: unused variable `index`\n  --> src/lib.rs:12:9\n",
        "error: could not compile `payments` due to 2 previous errors\n",
        "PASS  src/api/server.test.ts (4.1 s)\nTests: 41 passed, 41 total\n",
        "ssh: connect to host prod-db-01 port 22: Connection refused\n",
        "rm: cannot remove 'build': Permission denied\n",
    };

    return std::format("{}[run {}]\n", lines.at(roll % lines.size()), run);
  }

  void populate(HistoryStore& store, std::size_t runs) {
    constexpr std::size_t directories = 200;
    // About one run in eight is a command never run before, as a long-lived shell history has it.
    const std::size_t distinct = std::max<std::size_t>(runs / 8, 1);
    const Zipf commands{distinct, 1.05};
    const Zipf places{directories, 1.2};
    std::mt19937_64 random{0x74656c6172};
    const auto started = Clock::now();
    std::int64_t time_ms = 1'600'000'000'000;
    std::string workspace;

    for (std::size_t run = 0; run < runs; ++run) {
      const auto place = places.draw(random);
      const auto command = distinctCommand(commands.draw(random));
      const auto directory = directoryOf(place);
      const auto roll = random() % 100;
      const int exit_code = roll < 90 ? 0 : (roll < 98 ? 1 : 130);
      const HistorySession session{.id = {static_cast<Byte>(run / 4096), static_cast<Byte>((run / 4096) >> 8U), 1}, .pane = 1 + (run / 4096), .workspace_path = directory, .shell = "/bin/zsh"};

      const auto printed = run % 4 == 0 ? outputOf(run, random()) : std::string{};
      const std::span output{reinterpret_cast<const Byte*>(printed.data()), printed.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): an output is the bytes of its text

      time_ms += static_cast<std::int64_t>(random() % 60'000);
      store.record({.kind = HistoryEventKind::command_finished, .session = session, .command = {.command = command, .directory = directory, .started = {.milliseconds = time_ms}, .duration_ns = static_cast<std::int64_t>(random() % 5'000'000'000ULL), .exit_code = exit_code, .output = output, .output_observed = output.size()}});
    }

    std::println(R"({{"workload":"populate","runs":{},"seconds":{:.2f}}})", runs, std::chrono::duration<double>(Clock::now() - started).count());
  }

  struct Typed {
    std::string_view name;
    HistoryMatch match;
    bool distinct;
    HistoryScope scope = HistoryScope::global;
    std::string_view scope_value;
    // Searches the captured outputs, with queries of what a command prints.
    bool output = false;
  };

  // Each prefix of each query, as a person types it, through `typed`'s mode; every keystroke a
  // sample. A query of the prompt keeps the same snapshot, as the window does while it types.
  void typeQueries(ConcurrentMemory& memory, HistoryStore& store, const Typed& typed, std::size_t iterations) {
    constexpr std::array<std::string_view, 4> commands{"git commit", "kubectl get", "vim src/runtime", "cmake build"};
    constexpr std::array<std::string_view, 4> printed{"error: could", "warning: unused", "Permission denied", "Connection refused"};
    const auto& queries = typed.output ? printed : commands;
    constexpr std::uint16_t page = 50;
    Samples samples;
    std::size_t reply_bytes = 0;
    std::uint64_t request = 1;

    for (std::size_t iteration = 0; iteration < iterations; ++iteration) {
      for (const auto query : queries) {
        for (std::size_t length = 1; length <= query.size(); ++length) {
          EncodedReply reply{memory};
          QueryHistory asked{.request_id = request++, .query = query.substr(0, length), .scope = typed.scope, .match = typed.match, .distinct = typed.distinct, .limit = page, .output = typed.output};

          if (typed.scope != HistoryScope::global) {
            asked.scope_value = typed.scope_value;
          }

          const auto start = Clock::now();

          store.query(asked, reply);
          samples.add(Clock::now() - start);
          reply_bytes = std::max(reply_bytes, reply.payload().size());
        }
      }
    }

    std::println(R"({{"workload":"type.{}","keystrokes":{},"reply_bytes":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", typed.name, samples.size(), reply_bytes, samples.quantile(0.5), samples.quantile(0.99));
    measured.push_back({.workload = std::format("type.{}", typed.name), .p99_us = samples.quantile(0.99)});
  }

  // The same query again and again: the empty one the prompt and the browser open with.
  void repeat(ConcurrentMemory& memory, HistoryStore& store, std::string_view name, const QueryHistory& query, std::size_t iterations) {
    Samples samples;
    std::size_t reply_bytes = 0;

    for (std::size_t iteration = 0; iteration < iterations * 20; ++iteration) {
      EncodedReply reply{memory};
      const auto start = Clock::now();

      store.query(query, reply);
      samples.add(Clock::now() - start);
      reply_bytes = reply.payload().size();
    }

    std::println(R"({{"workload":"{}","iterations":{},"reply_bytes":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", name, samples.size(), reply_bytes, samples.quantile(0.5), samples.quantile(0.99));
    measured.push_back({.workload = std::string{name}, .p99_us = samples.quantile(0.99)});
  }

  // The pages a browser scrolls through, each after the one before.
  void scroll(ConcurrentMemory& memory, HistoryStore& store, std::string_view name, bool distinct, std::size_t pages) {
    constexpr std::uint16_t page = 100;
    std::vector<Byte> storage(std::size_t{8} * 1024 * 1024);
    Samples samples;
    QueryHistory query{.request_id = 1, .distinct = distinct, .limit = page};

    for (std::size_t index = 0; index < pages; ++index) {
      EncodedReply reply{memory};
      const auto start = Clock::now();

      store.query(query, reply);
      samples.add(Clock::now() - start);

      DecodeStorage decoded{storage};
      const auto result = Codec::decode<HistoryResults>(reply.payload(), decoded);
      if (!result.has_more || result.entries.empty()) {
        break;
      }

      query.request_id += 1;
      query.snapshot_id = result.snapshot_id;
      query.offset += static_cast<std::uint32_t>(result.entries.size());
    }

    std::println(R"({{"workload":"{}","pages":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", name, samples.size(), samples.quantile(0.5), samples.quantile(0.99));
    measured.push_back({.workload = std::string{name}, .p99_us = samples.quantile(0.99)});
  }

  // What an inspector reads of the runs a listing showed: each run alone, by its id, and its
  // output.
  void inspect(ConcurrentMemory& memory, HistoryStore& store, std::size_t runs, std::size_t iterations) {
    Samples entries;
    Samples outputs;
    std::uint64_t request = 1;

    for (std::size_t index = 0; index < iterations * 100; ++index) {
      // Every fourth run printed something; spread over the history.
      const auto id = 1 + (((index * 7919) % std::max<std::size_t>(runs / 4, 1)) * 4);
      EncodedReply entry{memory};
      auto start = Clock::now();

      store.query(QueryHistory{.request_id = request++, .limit = 1, .entry_id = id}, entry);
      entries.add(Clock::now() - start);

      EncodedReply output{memory};

      start = Clock::now();
      store.readOutput(ReadHistoryOutput{.request_id = request++, .id = id}, output);
      outputs.add(Clock::now() - start);
    }

    std::println(R"({{"workload":"inspect.entry","requests":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", entries.size(), entries.quantile(0.5), entries.quantile(0.99));
    std::println(R"({{"workload":"inspect.output","requests":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", outputs.size(), outputs.quantile(0.5), outputs.quantile(0.99));
    measured.push_back({.workload = "inspect.entry", .p99_us = entries.quantile(0.99)});
    measured.push_back({.workload = "inspect.output", .p99_us = outputs.quantile(0.99)});
  }

  // Each workload --check budgets against its budget; false when one is over it or missing.
  bool withinBudgets() {
    bool within = true;

    for (const auto& budget : budgets) {
      const auto found = std::ranges::find(measured, budget.workload, &Measured::workload);
      const bool kept = found != measured.end() && found->p99_us <= budget.p99_us;

      std::println(R"({{"check":"{}","p99_us":{:.1f},"budget_us":{:.1f},"within":{}}})", budget.workload, found != measured.end() ? found->p99_us : -1.0, budget.p99_us, kept);
      within = within && kept;
    }

    return within;
  }

  std::size_t number(std::string_view text, std::size_t fallback) {
    std::size_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);

    return parsed.ec == std::errc{} && value != 0 ? value : fallback;
  }

  Options parse(std::span<char*> arguments) {
    Options options;

    for (std::size_t index = 1; index < arguments.size(); ++index) {
      const std::string_view name{arguments[index]};

      if (name == "--check") {
        options.check = true;
        continue;
      }

      if (index + 1 == arguments.size()) {
        break;
      }

      const std::string_view value{arguments[++index]};

      if (name == "--runs") {
        options.runs = number(value, options.runs);
        options.sized = true;
      } else if (name == "--iterations") {
        options.iterations = number(value, options.iterations);
      } else if (name == "--database") {
        options.database = value;
      }
    }

    return options;
  }

}

int main(int argc, char** argv) {
  const auto options = parse({argv, static_cast<std::size_t>(argc)});

  // The budgets are those of a fresh history of 100,000 runs.
  if (options.check && (options.sized || !options.database.empty())) {
    std::println(stderr, "history-store-bench: --check measures a fresh history of {} runs; it takes neither --runs nor --database", checked_runs);
    return 2;
  }

  telar::testing::TestMemory adapter;
  ConcurrentMemory& memory = adapter;
  std::string root;
  auto path = options.database;

  if (path.empty()) {
    std::array<char, 64> pattern{};

    std::ranges::copy(std::string_view{"/tmp/telar-history-store-bench-XXXXXX"}, pattern.begin());
    if (::mkdtemp(pattern.data()) == nullptr) {
      std::println(stderr, "history-store-bench: cannot make a temporary directory");
      return 1;
    }

    root = pattern.data();
    path = root + "/history.db";
  }

  const bool fresh = !std::filesystem::exists(path);
  const auto opened = Clock::now();
  HistoryStore store{memory, path.c_str()};

  std::println(R"({{"workload":"open","seconds":{:.3f}}})", std::chrono::duration<double>(Clock::now() - opened).count());

  // What the writer does before its first write: an older file's upgrade, off the runtime's start.
  const auto upgrading = Clock::now();

  store.upgrade();
  std::println(R"({{"workload":"upgrade","seconds":{:.3f}}})", std::chrono::duration<double>(Clock::now() - upgrading).count());
  if (fresh) {
    populate(store, options.runs);
  }

  const auto directory = directoryOf(0);
  const auto warming = Clock::now();

  store.warm();
  std::println(R"({{"workload":"warm","seconds":{:.3f}}})", std::chrono::duration<double>(Clock::now() - warming).count());

  // How SQLite reads what the index does not answer: listings while it loads, and outputs.
  const auto plan = [&](std::string_view name, const QueryHistory& query) {
    ds::String<ConcurrentMemory> text{memory};

    store.plan(query, text);
    std::string line{text.view()};

    std::ranges::replace(line, '\n', ';');
    std::println(R"({{"workload":"plan.{}","plan":"{}"}})", name, line);
  };

  plan("listing", QueryHistory{.request_id = 1, .limit = 50});
  plan("listing.cwd", QueryHistory{.request_id = 1, .scope = HistoryScope::cwd, .scope_value = std::string_view{directory}, .limit = 50});
  plan("listing.failed", QueryHistory{.request_id = 1, .failed_only = true, .limit = 50});
  plan("output", QueryHistory{.request_id = 1, .query = "error", .limit = 50, .output = true});

  typeQueries(memory, store, {.name = "fuzzy.distinct", .match = HistoryMatch::fuzzy, .distinct = true}, options.iterations);
  typeQueries(memory, store, {.name = "fuzzy", .match = HistoryMatch::fuzzy, .distinct = false}, options.iterations);
  typeQueries(memory, store, {.name = "substring", .match = HistoryMatch::fts, .distinct = false}, options.iterations);
  typeQueries(memory, store, {.name = "substring.distinct", .match = HistoryMatch::fts, .distinct = true}, options.iterations);
  typeQueries(memory, store, {.name = "fuzzy.distinct.cwd", .match = HistoryMatch::fuzzy, .distinct = true, .scope = HistoryScope::cwd, .scope_value = directory}, options.iterations);
  typeQueries(memory, store, {.name = "substring.cwd", .match = HistoryMatch::fts, .distinct = false, .scope = HistoryScope::cwd, .scope_value = directory}, options.iterations);
  typeQueries(memory, store, {.name = "prefix", .match = HistoryMatch::prefix, .distinct = false}, options.iterations);
  typeQueries(memory, store, {.name = "prefix.distinct", .match = HistoryMatch::prefix, .distinct = true}, options.iterations);
  typeQueries(memory, store, {.name = "regex", .match = HistoryMatch::regex, .distinct = false}, options.iterations);
  typeQueries(memory, store, {.name = "regex.distinct", .match = HistoryMatch::regex, .distinct = true}, options.iterations);
  typeQueries(memory, store, {.name = "output", .match = HistoryMatch::substring, .distinct = false, .output = true}, options.iterations);
  repeat(memory, store, "empty.distinct", QueryHistory{.request_id = 1, .distinct = true, .limit = 50}, options.iterations);
  repeat(memory, store, "empty", QueryHistory{.request_id = 1, .limit = 50}, options.iterations);
  scroll(memory, store, "scroll", false, 50);
  scroll(memory, store, "scroll.distinct", true, 50);
  inspect(memory, store, options.runs, options.iterations);

  // The writer's first idle: retention, and the vacuum a migrated file waits for until then.
  const auto maintained = Clock::now();

  store.maintain(std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::system_clock::now().time_since_epoch()).count());
  std::println(R"({{"workload":"first_maintenance","seconds":{:.3f}}})", std::chrono::duration<double>(Clock::now() - maintained).count());

  if (!root.empty()) {
    std::error_code ignored;

    std::filesystem::remove_all(root, ignored);
  }

  if (options.check && !withinBudgets()) {
    std::println(stderr, "history-store-bench: a workload is over its budget");
    return 1;
  }

  return 0;
}
