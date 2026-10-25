#include "check.hpp"
#include "runtime/path_service.hpp"
#include <thread>

using namespace telar;
using namespace telar::runtime;

struct GatedPathMemory : SystemAllocator {
  std::atomic<bool> release{false};
  std::atomic<unsigned> started{0};
  std::atomic<unsigned> cancelled{0};
};

class GatedPathIndex {
public:
  explicit GatedPathIndex(GatedPathMemory &memory)
      : memory_(memory) {}

  std::string_view root() const noexcept {
    return root_.view();
  }

  void reset(std::string_view root) {
    root_.assign(root);
    complete_ = false;
    cancelled_ = false;
  }

  void build() noexcept {
    ++memory_.started;
    while (!memory_.release && !cancelled_) {
      std::this_thread::sleep_for(std::chrono::milliseconds{1});
    }
    if (cancelled_) {
      ++memory_.cancelled;
    }
    complete_ = true;
  }

  void stop() noexcept {
    cancelled_ = true;
  }

  bool complete() const noexcept {
    return complete_;
  }

  bool canQueryInline(const FindPaths &request) const noexcept {
    return complete() && !request.refresh && root() == request.root;
  }

  template <typename Reply>
  bool queryPublished(const FindPaths &request, Reply &reply) {
    const bool done = complete();
    reply.send(PathResults{request.request_id, root(), done ? 2u : 1u, done, false, {}});
    return done;
  }

private:
  GatedPathMemory &memory_;
  FixedText<4096> root_;
  std::atomic<bool> complete_{false};
  std::atomic<bool> cancelled_{false};
};

template <typename Predicate, typename Action>
static void awaitPaths(Predicate &&predicate, Action &&action) {
  const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds{3};
  while (!predicate()) {
    check(std::chrono::steady_clock::now() < deadline);
    action();
    std::this_thread::sleep_for(std::chrono::milliseconds{1});
  }
}

static void testProgressiveQueries() {
  GatedPathMemory memory;
  PathService<GatedPathMemory, GatedPathIndex> paths{memory};
  std::array<unsigned, 5> partial{};
  std::array<unsigned, 5> final{};
  std::array<std::uint64_t, 5> last_request{};
  std::array<Byte, 8192> scratch;
  const auto consume = [&](std::uint64_t client, ClientTag tag, std::span<const Byte> payload) {
    check(tag == ClientTag::find_paths);
    DecodeStorage storage{scratch};
    const auto reply = Codec::decode<PathResults>(payload, storage);
    check(client >= 1 && client <= 5);
    ++(reply.complete ? final[client - 1] : partial[client - 1]);
    last_request[client - 1] = reply.request_id;
  };
  const auto collect = [&] { paths.collect(consume); };
  for (std::uint64_t client = 1; client <= 4; ++client) {
    paths.submit(client, FindPaths{.request_id = client, .root = "/fixture", .limit = 10});
  }
  awaitPaths([&] { return std::ranges::all_of(std::span{partial}.first(4), [](auto count) { return count == 1; }); }, collect);
  check(std::ranges::all_of(final, [](auto count) { return count == 0; }));

  bool busy = false;
  try {
    paths.submit(5, FindPaths{.request_id = 5, .root = "/fixture", .limit = 10});
  } catch (const RequestError &error) {
    busy = error.code() == FailureCode::resource_limit;
  }
  check(busy);
  paths.submit(1, FindPaths{.request_id = 10, .root = "/fixture", .query = "latest", .limit = 10});
  awaitPaths([&] { return partial[0] == 2; }, collect);
  check(last_request[0] == 10);

  memory.release = true;
  awaitPaths([&] { return std::ranges::all_of(std::span{final}.first(4), [](auto count) { return count == 1; }); }, collect);
  check(last_request[0] == 10);
  EncodedReply reply{memory};
  check(paths.tryQuery(1, FindPaths{.request_id = 11, .root = "/fixture", .limit = 10}, reply));
  check(!paths.tryQuery(5, FindPaths{.request_id = 11, .root = "/fixture", .limit = 10}, reply));
  paths.submit(5, FindPaths{.request_id = 12, .root = "/other", .limit = 10});
  awaitPaths([&] { return final[4] == 1; }, collect);
  check(!paths.tryQuery(2, FindPaths{.request_id = 13, .root = "/fixture", .limit = 10}, reply));
}

static void testRebuildAndDisconnect() {
  GatedPathMemory memory;
  PathService<GatedPathMemory, GatedPathIndex> paths{memory};
  unsigned replies = 0;
  bool final = false;
  std::array<Byte, 8192> scratch;
  const auto consume = [&](std::uint64_t client, ClientTag, std::span<const Byte> payload) {
    DecodeStorage storage{scratch};
    const auto reply = Codec::decode<PathResults>(payload, storage);
    ++replies;
    if (reply.request_id == 2) {
      check(reply.root == "/replacement");
      final |= reply.complete;
    }
    if (reply.request_id == 3) {
      paths.cancel(client);
    }
  };
  const auto collect = [&] { paths.collect(consume); };
  paths.submit(1, FindPaths{.request_id = 1, .root = "/original", .limit = 10});
  awaitPaths([&] { return replies == 1 && memory.started == 1; }, collect);
  paths.submit(1, FindPaths{.request_id = 2, .root = "/replacement", .limit = 10});
  awaitPaths([&] { return memory.cancelled == 1 && memory.started == 2; }, collect);
  memory.release = true;
  awaitPaths([&] { return final; }, collect);

  paths.submit(1, FindPaths{.request_id = 3, .root = "/replacement", .limit = 10});
  const auto before = replies;
  awaitPaths([&] { return replies > before; }, collect);
  collect();
  EncodedReply reply{memory};
  check(!paths.tryQuery(1, FindPaths{.request_id = 4, .root = "/replacement", .limit = 10}, reply));

  memory.release = false;
  const auto builds = memory.started.load();
  paths.submit(2, FindPaths{.request_id = 5, .root = "/closed", .limit = 10});
  awaitPaths([&] { return memory.started > builds; }, [] {});
  paths.cancel(2);
  const auto retained = replies;
  awaitPaths([&] { return memory.cancelled == 2; }, collect);
  collect();
  check(replies == retained);
}

static void testPublishedStorage() {
  SystemAllocator memory;
  PathIndexStorage storage{memory};
  constexpr std::string_view path = "src/runtime.cpp";
  constexpr std::size_t count = 16 * 1024;
  std::jthread builder{[&] {
    for (std::size_t index = 0; index < count; ++index) {
      check(storage.append(path, PathKind::file));
    }
    storage.finish();
  }};

  std::size_t checked = 0;
  while (checked < count) {
    const auto published = storage.published.load(std::memory_order_acquire);
    for (; checked < published; ++checked) {
      const auto &entry = storage.entry(checked);
      check(entry.offset == checked * path.size());
      check(storage.path(entry) == path && entry.kind == PathKind::file);
    }
    std::this_thread::yield();
  }
  builder.join();
  check(storage.complete.load(std::memory_order_acquire));

  storage.reset();
  for (std::size_t index = 0; index < storage.maximum_entries; ++index) {
    check(storage.append("x", PathKind::file));
  }
  check(!storage.append("x", PathKind::file) && storage.truncated);
  check(storage.count == storage.maximum_entries);

  storage.reset();
  std::array<char, 1024> long_path;
  long_path.fill('x');
  for (std::size_t bytes = 0; bytes < storage.maximum_bytes; bytes += long_path.size()) {
    check(storage.append({long_path.data(), long_path.size()}, PathKind::file));
  }
  check(!storage.append("x", PathKind::file) && storage.truncated);
  check(storage.bytes_used == storage.maximum_bytes);
}

void testPathService() {
  testProgressiveQueries();
  testRebuildAndDisconnect();
  testPublishedStorage();
}
