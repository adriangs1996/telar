// What the runtime does for the explorer, measured on directories it makes: listing one with
// many entries, giving its next page, measuring a tree, asking git what changed and inspecting
// a changed file. Each request goes through the file service as a client's does, decoded from
// its bytes and answered as an encoded reply, and is timed over many repetitions. The output is
// one JSON object per workload.
//
//   files-bench [--entries N] [--directories N] [--changes N] [--iterations N]

#include <cstdio>
#include <cstdlib>

import std;
import telar.testing.test_memory;
import telar.base.memory.allocators;
import telar.platform.fs;
import telar.runtime.files.service;
import telar.runtime.transport.connection;
import telar.wire.files;
import telar.wire.vocabulary;

namespace {

  using namespace telar;
  using namespace telar::runtime;
  using Clock = std::chrono::steady_clock;

  struct Options {
    // The entries of the directory listed, the directories of the tree measured, each with
    // `files_in_directory` files, and the files git says changed.
    std::size_t entries = 5000;
    std::size_t directories = 200;
    std::size_t changes = 200;
    std::size_t iterations = 200;
  };

  constexpr std::size_t files_in_directory = 20;

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

  // One workload: its name, how much it works on, and whether each repetition starts with a
  // service that holds nothing, as the first request on a directory finds it.
  struct Workload {
    std::string_view name;
    std::size_t size = 0;
    std::size_t iterations = 0;
    bool fresh = false;
  };

  template <typename Request>
  void run(ConcurrentMemory& memory, const Workload& workload, const Request& request) {
    constexpr std::size_t frame_bytes = std::size_t{64} * 1024;
    std::vector<Byte> frame(frame_bytes);
    const auto payload = Codec::encode(request, std::span<Byte>{frame});
    Samples samples;
    std::size_t reply_bytes = 0;
    std::optional<FileService> service;

    for (std::size_t iteration = 0; iteration < workload.iterations; ++iteration) {
      if (workload.fresh || !service) {
        service.emplace(memory);
        if (!workload.fresh) {
          // What a later request finds: the service answered this one before.
          EncodedReply warm{memory};

          service->process(payload, warm);
        }
      }

      EncodedReply reply{memory};
      const auto start = Clock::now();

      service->process(payload, reply);
      samples.add(Clock::now() - start);
      reply_bytes = reply.payload().size();
    }

    std::println(R"({{"workload":"{}","size":{},"iterations":{},"reply_bytes":{},"p50_us":{:.1f},"p99_us":{:.1f}}})", workload.name, workload.size, workload.iterations, reply_bytes, samples.quantile(0.5), samples.quantile(0.99));
  }

  void write(const std::string& path, std::size_t lines) {
    std::ofstream file{path};

    for (std::size_t line = 0; line < lines; ++line) {
      file << "A line of a file the explorer lists, measures and previews.\n";
    }
  }

  // Runs `command` in `directory` with a shell; false when it fails.
  bool shell(const std::string& directory, std::string_view command) {
    const auto line = std::format("cd '{}' && {} >/dev/null 2>&1", directory, command);

    return std::system(line.c_str()) == 0; // NOLINT(concurrency-mt-unsafe,cert-env33-c): the bench runs alone, on a directory it made
  }

  std::size_t number(std::string_view text, std::size_t fallback) {
    std::size_t value = 0;
    const auto parsed = std::from_chars(text.data(), text.data() + text.size(), value);

    return parsed.ec == std::errc{} && value != 0 ? value : fallback;
  }

  Options parse(std::span<char*> arguments) {
    Options options;

    for (std::size_t index = 1; index + 1 < arguments.size(); index += 2) {
      const std::string_view name{arguments[index]};
      const std::string_view value{arguments[index + 1]};

      if (name == "--entries") {
        options.entries = number(value, options.entries);
      } else if (name == "--directories") {
        options.directories = number(value, options.directories);
      } else if (name == "--changes") {
        options.changes = number(value, options.changes);
      } else if (name == "--iterations") {
        options.iterations = number(value, options.iterations);
      }
    }

    return options;
  }

}

int main(int argc, char** argv) {
  const auto options = parse({argv, static_cast<std::size_t>(argc)});
  telar::testing::TestMemory adapter;
  ConcurrentMemory& memory = adapter;
  const TemporaryDirectory directory{"/tmp/telar-files-bench-XXXXXX"};
  const std::string root{directory.path()};
  const auto flat = root + "/flat";
  const auto tree = root + "/tree";
  const auto repository = root + "/repository";

  // A directory of many entries, a tenth of them directories.
  std::filesystem::create_directories(flat);
  for (std::size_t entry = 0; entry < options.entries; ++entry) {
    constexpr std::size_t directory_every = 10;
    const auto path = std::format("{}/entry-{:06}", flat, entry);

    if (entry % directory_every == 0) {
      std::filesystem::create_directory(path);
    } else {
      write(path + ".md", 1);
    }
  }

  // A tree of directories, each holding a few files.
  for (std::size_t index = 0; index < options.directories; ++index) {
    const auto below = std::format("{}/directory-{:04}", tree, index);

    std::filesystem::create_directories(below);
    for (std::size_t file = 0; file < files_in_directory; ++file) {
      write(std::format("{}/file-{:02}.txt", below, file), files_in_directory);
    }
  }

  run(memory, {.name = "list.first_page", .size = options.entries, .iterations = options.iterations, .fresh = true}, ListDirectory{.request_id = 1, .path = flat, .skip = 0, .limit = FileLimits::maximum_entries});
  run(memory, {.name = "list.next_page", .size = options.entries, .iterations = options.iterations}, ListDirectory{.request_id = 1, .path = flat, .skip = FileLimits::maximum_entries, .limit = FileLimits::maximum_entries});
  run(memory, {.name = "measure.tree", .size = options.directories * files_in_directory, .iterations = std::max<std::size_t>(1, options.iterations / 4)}, MeasureDirectory{.request_id = 1, .path = tree, .skip = 0, .limit = FileLimits::maximum_entries});

  // A repository whose files changed since its commit.
  std::filesystem::create_directories(repository);
  for (std::size_t file = 0; file < options.changes; ++file) {
    constexpr std::size_t lines = 100;

    write(std::format("{}/file-{:04}.md", repository, file), lines);
  }

  const bool committed = shell(repository, "git init -q -b main") && shell(repository, "git add .") && shell(repository, "git -c user.name=telar -c user.email=telar@example.invalid -c commit.gpgsign=false commit -q -m 'Add the files'");
  if (!committed) {
    std::println(stderr, "git is not installed or refused the commit: the workloads on a repository are left out");
    return 0;
  }

  for (std::size_t file = 0; file < options.changes; ++file) {
    constexpr std::size_t lines = 104;

    write(std::format("{}/file-{:04}.md", repository, file), lines);
  }

  const auto slow = std::max<std::size_t>(1, options.iterations / 10);

  run(memory, {.name = "git.changes", .size = options.changes, .iterations = slow}, QueryChanges{.request_id = 1, .path = repository});
  run(memory, {.name = "inspect.changed_file", .size = 1, .iterations = slow}, InspectFile{.request_id = 1, .path = repository + "/file-0000.md"});
  return 0;
}
