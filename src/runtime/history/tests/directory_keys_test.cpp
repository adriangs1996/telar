#include <climits>

import std;
import telar.testing;
import telar.testing.test_memory;
import telar.base.memory.containers;
import telar.runtime.history.directory_keys;
import telar.base.ds;

// What the history's directory keys do when resolving a directory hangs, as on a network mount
// that stopped answering: no real path can be made to hang on every system, so a resolver stands
// in for realpath and hangs on the paths under /stuck until the test lets it go.
namespace {

  using telar::testing::check;

  using namespace telar;
  using namespace telar::runtime;

  constexpr std::string_view stuck_root = "/stuck";
  constexpr std::string_view resolved_root = "/resolved";
  // Far past the patience the keys document, so a loaded machine still answers in time, and far
  // short of a hang.
  constexpr auto answers_within = std::chrono::seconds{2};

  // The mount: it hangs while it is held, then answers.
  struct Mount {
    std::mutex mutex;
    std::condition_variable released;
    bool held = true;
  };

  Mount mount;

  // The key of a path is the path under /resolved, so a key tells whether it was resolved.
  std::string_view resolve(std::string_view path, ds::Array<char, PATH_MAX>& buffer) noexcept {
    if (path.starts_with(stuck_root)) {
      std::unique_lock lock{mount.mutex};

      mount.released.wait(lock, [] {
        return !mount.held;
      });
    }

    auto* out = std::ranges::copy(resolved_root, buffer.dataMut()).out;

    out = std::ranges::copy(path, out).out;
    return {buffer.data(), static_cast<std::size_t>(out - buffer.data())};
  }

  void release() {
    {
      const std::scoped_lock lock{mount.mutex};

      mount.held = false;
    }

    mount.released.notify_all();
  }

  // The key `keys` gives `path`, or none when it did not come back in time.
  ds::Option<std::string> keyInTime(DirectoryKeys& keys, std::string path) {
    auto asked = std::async(std::launch::async, [&keys, path = std::move(path)] {
      FixedText<PATH_MAX> out;

      keys.key(path, out);
      return std::string{out.view()};
    });

    if (asked.wait_for(answers_within) != std::future_status::ready) {
      // Lets the lookup end, so the test fails instead of hanging with it.
      release();
      return ds::none;
    }

    return asked.get();
  }

  // A lookup on a hung mount comes back within the keys' patience, keyed as it was written; the
  // lookups after it are not held behind it; and once the mount answers, its keys are resolved.
  void aHungDirectoryIsKeyedAsWritten() {
    static telar::testing::TestMemory memory;
    DirectoryKeys keys{memory, resolve};

    const auto started = std::chrono::steady_clock::now();
    const auto hung = keyInTime(keys, "/stuck/project/");

    check(hung.hasValue(), "a lookup on a hung mount comes back");
    check(hung && *hung == "/stuck/project", "keyed as written, without its slash");
    check(std::chrono::steady_clock::now() - started >= DirectoryKeys::patience, "after waiting the patience for the answer");

    const auto later = keyInTime(keys, "/home/project");

    check(later.hasValue() && *later == "/home/project", "a later lookup is not held behind the hung one");

    release();

    // The helper answers the hung path once the mount does, and is then free for the next.
    const auto deadline = std::chrono::steady_clock::now() + answers_within;
    ds::Option<std::string> resolved;

    while (std::chrono::steady_clock::now() < deadline && (!resolved || *resolved != "/resolved/home/project")) {
      resolved = keyInTime(keys, "/home/project");
    }

    check(resolved && *resolved == "/resolved/home/project", "resolved once the mount answers");

    const auto answered = keyInTime(keys, "/stuck/project/");

    check(answered && *answered == "/resolved/stuck/project/", "the late answer keys the hung path");
  }

  const telar::testing::Case case_hung{"directory_keys.a_hung_directory_is_keyed_as_written", aHungDirectoryIsKeyedAsWritten};

}
