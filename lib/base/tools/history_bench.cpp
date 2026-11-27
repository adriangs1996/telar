// Times the history's matcher over a corpus of a million distinct commands, shaped as a shell's
// history is, in nanoseconds per command for each query length, best of several rounds; `find`,
// the time to look for the query's first byte in each command, is the floor of any matcher. Build it
// in a Release tree, where assertions are off:
//   tools/cpp build <preset> -- --target history-bench && out/<preset>/lib/base/history-bench
import std;
import telar.base.history;

namespace {

  using namespace telar::runtime;

  // Keeps the compiler from proving a result unused and dropping the work that produced it.
  template <typename Value>
  void keep(const Value& value) {
    asm volatile("" : : "r,m"(value) : "memory");
  }

  // xorshift64*, so every run measures the same corpus.
  class Random {
  public:
    std::uint64_t next() noexcept {
      state_ ^= state_ >> 12U;
      state_ ^= state_ << 25U;
      state_ ^= state_ >> 27U;
      return state_ * 0x2545f4914f6cdd1dULL;
    }

    std::size_t below(std::size_t bound) noexcept {
      return static_cast<std::size_t>(next() % bound);
    }

    template <typename Range>
    auto pick(const Range& range) noexcept {
      return range[below(std::size(range))];
    }

  private:
    std::uint64_t state_ = 0x9e3779b97f4a7c15ULL;
  };

  constexpr std::array<std::string_view, 48> words{
      "src",
      "lib",
      "build",
      "test",
      "main",
      "config",
      "server",
      "client",
      "parser",
      "render",
      "deploy",
      "release",
      "feature",
      "fix",
      "update",
      "docs",
      "api",
      "auth",
      "cache",
      "index",
      "store",
      "history",
      "prompt",
      "terminal",
      "window",
      "module",
      "kernel",
      "network",
      "socket",
      "query",
      "report",
      "schema",
      "worker",
      "metrics",
      "logs",
      "user",
      "admin",
      "data",
      "backup",
      "staging",
      "production",
      "frontend",
      "backend",
      "plugin",
      "theme",
      "editor",
      "session",
      "agent",
  };

  constexpr std::array<std::string_view, 8> extensions{"rs", "cpp", "py", "ts", "go", "md", "json", "yaml"};

  std::string path(Random& random) {
    std::string out = random.below(3) == 0 ? "/home/user/" : "./";

    for (std::size_t depth = 1 + random.below(4); depth-- > 0;) {
      out += random.pick(words);
      out += '/';
    }

    out += random.pick(words);
    out += '.';
    out += random.pick(extensions);
    return out;
  }

  std::string command(Random& random) {
    const auto word = [&] {
      return std::string{random.pick(words)};
    };
    const auto number = [&] {
      return std::to_string(random.below(10000));
    };

    switch (random.below(16)) {
    case 0:
      return "git commit -m \"" + word() + " the " + word() + " " + number() + "\"";
    case 1:
      return "git checkout -b " + word() + "/" + word() + "-" + number();
    case 2:
      return "git push origin " + word() + "-" + number();
    case 3:
      return "git log --oneline -n " + number() + " -- " + path(random);
    case 4:
      return "docker run --rm -it -v " + path(random) + ":/" + word() + " " + word() + ":" + number() + " sh";
    case 5:
      return "kubectl get pods -n " + word() + " -l app=" + word() + number();
    case 6:
      return "kubectl logs -f deployment/" + word() + "-" + number() + " --since=" + number() + "s";
    case 7:
      return "cargo test --package " + word() + " " + word() + "::" + word() + number();
    case 8:
      return "cd " + path(random) + number();
    case 9:
      return "vim " + path(random) + " +" + number();
    case 10:
      return "grep -rn \"" + word() + number() + "\" " + path(random);
    case 11:
      return "ssh " + word() + "@" + word() + number() + ".example.com";
    case 12:
      return "make -j" + std::to_string(1 + random.below(16)) + " " + word() + "-" + number();
    case 13:
      return "python3 " + path(random) + " --" + word() + " " + number();
    case 14:
      return "curl -s https://" + word() + ".example.com/api/v" + std::to_string(random.below(4)) + "/" + word() + "/" + number();
    default:
      return "find " + path(random) + " -name \"*." + std::string{random.pick(extensions)} + "\" -mtime -" + number();
    }
  }

  // The commands in one buffer, as an index keeps them, and a view of each.
  struct Corpus {
    std::string bytes;
    std::vector<std::string_view> commands;
  };

  Corpus corpus(std::size_t count) {
    Random random;
    std::unordered_set<std::string> seen;
    std::vector<std::pair<std::size_t, std::size_t>> extents;
    Corpus out;

    extents.reserve(count);
    while (extents.size() < count) {
      auto text = command(random);

      if (seen.insert(text).second) {
        extents.emplace_back(out.bytes.size(), text.size());
        out.bytes += text;
      }
    }

    out.commands.reserve(count);
    for (const auto [offset, size] : extents) {
      out.commands.push_back(std::string_view{out.bytes}.substr(offset, size));
    }

    return out;
  }

  // Best of several rounds of `score` over every command, in nanoseconds per command, and how
  // many it matched.
  template <typename Score>
  std::pair<double, std::size_t> timed(const std::vector<std::string_view>& commands, const Score& score) {
    auto best = std::numeric_limits<double>::infinity();
    std::size_t matched = 0;

    for (int round = 0; round < 3; ++round) {
      std::size_t count = 0;
      const auto start = std::chrono::steady_clock::now();

      for (const auto command : commands) {
        const auto result = score(command);

        count += result ? 1 : 0;
        keep(result);
      }

      const std::chrono::duration<double, std::nano> elapsed = std::chrono::steady_clock::now() - start;

      best = std::min(best, elapsed.count() / static_cast<double>(commands.size()));
      matched = count;
    }

    return {best, matched};
  }

  // Queries a user types, by length: abbreviations, words and parts of words.
  constexpr std::array<std::string_view, 18> queries{
      "g",
      "k",
      "gp",
      "kl",
      "gco",
      "dkr",
      "push",
      "logs",
      "gcomm",
      "cargo",
      "kubget",
      "deploy",
      "gitpush",
      "srcmain",
      "cargtest",
      "kubectl logs",
      "git push origin",
      "docker run --rm -it",
  };

}

int main() {
  constexpr std::size_t count = 1'000'000;
  const auto owned = corpus(count);
  const auto& commands = owned.commands;

  std::println("{} commands; ns per command, then how many matched", commands.size());

  const auto fast = std::make_unique<HistoryMatchArena>(HistorySearchPath::fast);
  const auto reference = std::make_unique<HistoryMatchArena>(HistorySearchPath::reference);

  for (const auto query : queries) {
    const HistoryPattern pattern{query};
    const auto [floor, floor_matched] = timed(commands, [&](std::string_view command) {
      return command.find(query.front()) != std::string_view::npos;
    });
    const auto [score, score_matched] = timed(commands, [&](std::string_view command) {
      return historyScore(command, query);
    });
    const auto [match, match_matched] = timed(commands, [&](std::string_view command) {
      return historyMatch(pattern, command, *fast);
    });
    const auto [scalar, scalar_matched] = timed(commands, [&](std::string_view command) {
      return historyMatch(pattern, command, *reference);
    });

    std::println(
        "{:<22} len {:2}  find {:5.1f}  historyScore {:6.1f} {:7}  historyMatch {:6.1f} {:7}  reference {:6.1f}",
        std::format("\"{}\"", query),
        query.size(),
        floor,
        score,
        score_matched,
        match,
        match_matched,
        scalar
    );
    keep(scalar_matched);
    keep(floor_matched);
  }
}
