
#include <cstdio>
#include <unistd.h>
import std;
import telar.runtime.tests.check;
import telar.runtime.tests.protocol_peer;

using namespace telar;

static PathResults awaitFinal(ProtocolPeer &peer, std::uint64_t request) {
  for (;;) {
    const auto result = peer.receive<PathResults>();
    if (result.request_id == request && result.complete) {
      return result;
    }
  }
}

static void record(ProtocolPeer &peer, std::ostream &dump, PathResults result) {
  result.root = "/fixture";
  peer.record(dump, result);
}

static void controlled(const char *socket, const std::filesystem::path &root, const char *output) {
  ProtocolPeer peer{socket};
  std::ofstream dump{output, std::ios::binary};
  const auto directory = root.string();
  std::uint64_t request = 1;
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{5};
  for (;;) {
    auto result = peer.exchange<PathResults>(FindPaths{.request_id = request++, .root = directory, .query = "file", .limit = 10});
    check(!result.complete);
    if (result.scanned >= 1024) {
      break;
    }
    check(std::chrono::steady_clock::now() < deadline);
  }

  std::ofstream{root / "release"} << "release";
  auto completed = awaitFinal(peer, request - 1);
  check(completed.scanned == 2049 && completed.matches.size() == 10 && !completed.truncated);
  completed.request_id = 1;
  record(peer, dump, completed);

  std::filesystem::remove(root / "release");
  auto refreshing = peer.exchange<PathResults>(FindPaths{.request_id = request++, .root = directory, .limit = 10, .refresh = true});
  check(!refreshing.complete);
  const auto replacement = (root.parent_path() / "replacement").string();
  peer.send(FindPaths{.request_id = request, .root = replacement, .limit = 10});
  auto replaced = awaitFinal(peer, request);
  check(replaced.scanned == 1 && replaced.matches.size() == 1 && replaced.matches[0].path == "replacement.txt");
  replaced.request_id = 2;
  record(peer, dump, replaced);

  bool refused = false;
  try {
    peer.exchange<PathResults>(FindPaths{.request_id = ++request, .root = "/nonexistent-telar-path-probe", .limit = 10});
    awaitFinal(peer, request);
  } catch (const ProtocolFailure &error) {
    refused = error.code == FailureCode::permission_denied;
  }
  check(refused);
  peer.exchange<RuntimeStopping>(RuntimeStop{});
  std::puts("{\"partial_before_completion\":true,\"latest_query_completed\":true,\"rebuild_cancelled\":true,\"unreadable_refused\":true}");
}

static void populate(const std::filesystem::path &root, unsigned files) {
  for (unsigned directory = 0; directory < 32; ++directory) {
    const auto path = root / ("module_" + std::to_string(directory));
    std::filesystem::create_directory(path);
    for (unsigned file = 0; file < files; ++file) {
      std::ofstream{path / ("runtime_" + std::to_string(file) + ".cpp")};
    }
  }

  std::filesystem::create_directory(root / "node_modules");
  std::ofstream{root / "node_modules" / "excluded.cpp"};
  std::ofstream{root / ".hidden"};
  std::filesystem::create_directory_symlink(root, root / "cycle");
}

int main(int argc, char **argv) {
  if (argc != 5) {
    return 2;
  }
  try {
    if (std::string_view{argv[1]} == "--controlled") {
      controlled(argv[2], argv[3], argv[4]);
      return 0;
    }

    ProtocolPeer peer{argv[1]};
    const auto iterations = static_cast<unsigned>(std::stoul(argv[3]));
    std::array<char, 64> directory{};
    std::strcpy(directory.data(), "/tmp/telar-path-large-XXXXXX");
    check(::mkdtemp(directory.data()) != nullptr);
    const std::filesystem::path root{directory.data()};
    populate(root, 128);
    std::ofstream dump{argv[4], std::ios::binary};
    constexpr std::array<std::string_view, 4> queries{"", "rt", "mod31", "cpp"};
    const auto started = std::chrono::steady_clock::now();
    for (unsigned index = 0; index < iterations; ++index) {
      peer.send(FindPaths{.request_id = index + 1, .root = directory.data(), .query = queries[index % queries.size()], .kind = index % 3 == 0 ? PathKindFilter::directories : PathKindFilter::any, .limit = 50});
      const auto result = awaitFinal(peer, index + 1);
      check(result.scanned == 4129 && !result.truncated);
      record(peer, dump, result);
    }
    const auto elapsed = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - started).count();
    std::filesystem::remove_all(root);
    std::printf("{\"iterations\":%u,\"elapsed_ns\":%lld,\"ns_per_iteration\":%lld}\n", iterations, static_cast<long long>(elapsed), static_cast<long long>(elapsed / iterations));
    return 0;
  } catch (const std::exception &error) {
    std::fprintf(stderr, "path-probe: %s\n", error.what());
    return 1;
  }
}
