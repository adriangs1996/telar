#include "check.hpp"
#include "persistence/file_store.hpp"
#include "persistence/restore.hpp"
#include "persistence/writer.hpp"
#include "platform/observation_worker.hpp"
#include <random>
#include <string>

using namespace telar;
using namespace telar::runtime;

static void testMonotonicIdentities(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 32, SystemAllocator> store{memory};
  std::array<std::uint64_t, 32> identities{};
  std::uint64_t counter = 63;
  std::minstd_rand random{71};
  for (unsigned iteration = 0; iteration < 10000; ++iteration) {
    const auto slot = random() % identities.size();
    if (identities[slot] != 0) {
      store.erase(identities[slot]);
      check(store.find(identities[slot]) == nullptr);
    }

    identities[slot] = counter;
    store.insert(counter, makeOwned<std::uint64_t>(memory, counter));
    counter += 64;
    for (const auto identity : identities) {
      if (identity != 0) {
        check(store.find(identity) != nullptr && *store.find(identity) == identity);
      }
    }
  }

  check(store.nextCounter() == counter - 63);
  bool exhausted = false;
  try {
    store.insert(UINT64_MAX, makeOwned<std::uint64_t>(memory, UINT64_MAX));
  } catch (const std::bad_alloc &) {
    exhausted = true;
  }
  check(exhausted);
}

static void testIndependentHandles(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 3, SystemAllocator> store{memory};
  constexpr std::uint64_t high_identity = UINT64_MAX - 1;
  const auto first = store.insert(high_identity, makeOwned<std::uint64_t>(memory, high_identity));
  check(*store.findHandle(first) == high_identity);
  check(store.find(high_identity) == store.findHandle(first));
  store.erase(high_identity);
  check(store.findHandle(first) == nullptr);

  const auto second = store.insert(1, makeOwned<std::uint64_t>(memory, 1));
  check(second != first);
  check(store.findHandle(first) == nullptr);
  check(*store.findHandle(second) == 1);
  check(store.findHandle(UINT64_MAX) == nullptr);
}

static void testExhaustedIdentities(SystemAllocator &memory) {
  SlotStore<std::uint64_t, 3, SystemAllocator> store{memory};
  store.advanceCounter(UINT64_MAX);
  check(store.nextId() == UINT64_MAX);
  store.insert(UINT64_MAX, makeOwned<std::uint64_t>(memory, UINT64_MAX));
  check(store.nextCounter() == 0 && *store.find(UINT64_MAX) == UINT64_MAX);
  store.erase(UINT64_MAX);
  store.advanceCounter(1);
  check(store.nextCounter() == 0 && store.size() == 0);

  bool exhausted = false;
  try {
    store.nextId();
  } catch (const std::bad_alloc &) {
    exhausted = true;
  }
  check(exhausted);
}

static std::span<const Byte> checkpointFixture(std::span<Byte> buffer) {
  checkpoint::Writer writer{buffer, checkpoint::Counters{70, 80, 300, 900}};
  writer.append(checkpoint::WorkspaceRecord{5, "/tmp", "Restored", 7, "Shells"});
  writer.append(checkpoint::TabRecord{5, 8, "Missing"});
  constexpr char arguments[] = "/bin/sh\0-c\0read value\0";
  writer.append(checkpoint::PaneRecord{257, 5, 7, "/tmp", 90, 30, 3, {arguments, sizeof(arguments) - 1}});
  writer.append(checkpoint::PaneRecord{1, 5, 7, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  writer.append(checkpoint::PaneRecord{258, 5, 8, "/telar-missing-checkpoint-directory", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  return writer.finish();
}

static void testCheckpointValidation() {
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  std::size_t count = 0;
  checkpoint::Reader reader{fixture};
  reader.read([&](const auto &) { ++count; });
  check(count == 5 && reader.counters.generation == 900);

  for (std::size_t length = 0; length < fixture.size(); ++length) {
    bool rejected = false;
    try {
      checkpoint::Reader truncated{fixture.first(length)};
      truncated.read([](const auto &) {});
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }

  buffer[fixture.size()] = 0;
  bool trailing_rejected = false;
  try {
    checkpoint::Reader trailing{std::span{buffer}.first(fixture.size() + 1)};
    trailing.read([](const auto &) {});
  } catch (const EncodingError &) {
    trailing_rejected = true;
  }
  check(trailing_rejected);

  for (std::size_t capacity = 43; capacity < fixture.size(); ++capacity) {
    checkpoint::Writer bounded{std::span{buffer}.first(capacity), {}};
    bounded.append(checkpoint::WorkspaceRecord{1, "/tmp", "Example", 1, ""});
    const auto encoded = bounded.finish();
    checkpoint::Reader valid{encoded};
    valid.read([](const auto &) {});
    check(encoded.size() <= capacity);
  }

  for (std::size_t capacity = 0; capacity < 43; ++capacity) {
    bool rejected = false;
    try {
      checkpoint::Writer tiny{std::span{buffer}.first(capacity), {}};
    } catch (const EncodingError &) {
      rejected = true;
    }
    check(rejected);
  }
}

static void testRestore(SystemAllocator &memory) {
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
  ClientLayouts layouts{memory, model};
  checkpoint::Restore restore{memory, model, panes, layouts, false};
  restore.apply(fixture);
  check(model.panes.size() == 2);
  check(model.panes.find(1)->generation == 900);
  check(model.panes.find(257)->generation == 901);
  check(model.panes.find(257)->terminal.screen.cols == 90);
  check(model.panes.find(257)->launch.bytes() == model.panes.find(1)->launch.bytes());
  check(model.panes.nextId() == 300);
  check(model.workspaces.nextId() == 70);
  check(model.next_tab_id == 80);
  const auto *workspace = model.workspaces.find(5);
  check(workspace != nullptr && workspace->tabs.size() == 1);
  check(workspace->tabs.front().panes.size() == 2);
  check(workspace->tabs.front().panes[0] == 1);
}

static void testAtomicFile(SystemAllocator &memory) {
  std::array<char, 64> directory{};
  std::strcpy(directory.data(), "/tmp/telar-checkpoint-test-XXXXXX");
  check(::mkdtemp(directory.data()) != nullptr);
  const auto path = std::string{directory.data()} + "/session.ckpt";
  checkpoint::FileStore file{memory, path};
  Vector<Byte, SystemAllocator> loaded{AllocatorRef<Byte, SystemAllocator>{memory}};
  check(!file.load(loaded));
  std::array<Byte, 4096> buffer;
  const auto fixture = checkpointFixture(buffer);
  {
    ObservationWorker worker{file};
    check(worker.submit(fixture));
    worker.wait([](int error) { check(error == 0); });
  }

  check(file.load(loaded));
  check(std::ranges::equal(loaded, fixture));
  struct stat state{};
  check(::stat(path.c_str(), &state) == 0 && (state.st_mode & 0777) == 0600);
  file.quarantine();
  check(!file.load(loaded));
  check(::stat((path + ".corrupt").c_str(), &state) == 0);

  check(::mkdir(path.c_str(), 0700) == 0);
  check(file.observe(fixture) != 0);
  check(::stat(path.c_str(), &state) == 0 && S_ISDIR(state.st_mode));
  check(::rmdir(path.c_str()) == 0);
  check(::symlink((path + ".corrupt").c_str(), path.c_str()) == 0);
  bool rejected = false;
  try {
    file.load(loaded);
  } catch (const SystemError &) {
    rejected = true;
  }
  check(rejected);
  check(::unlink(path.c_str()) == 0);
  check(::unlink((path + ".corrupt").c_str()) == 0);
  check(::rmdir(directory.data()) == 0);
}

static void testLargePaneIdentity(SystemAllocator &memory) {
  constexpr std::uint64_t identity = UINT64_MAX - 2;
  std::array<Byte, 4096> buffer;
  checkpoint::Writer writer{buffer, checkpoint::Counters{2, 2, identity + 1, 10}};
  writer.append(checkpoint::WorkspaceRecord{1, "/tmp", "Large identity", 1, ""});
  constexpr char arguments[] = "/bin/sh\0-c\0printf 'restored'; read value\0";
  writer.append(checkpoint::PaneRecord{identity, 1, 1, "/tmp", 80, 24, 3, {arguments, sizeof(arguments) - 1}});
  RuntimeModel model{memory};
  NativeEventLoop<std::remove_reference_t<decltype(memory)>> poller{memory};
  PaneService panes{memory, model, poller, PaneLaunchOptions{.socket = "/tmp/unused-checkpoint-test.sock"}};
  ClientLayouts layouts{memory, model};
  checkpoint::Restore restore{memory, model, panes, layouts, false};
  restore.apply(writer.finish());
  auto *pane = model.panes.find(identity);
  check(pane != nullptr && pane->id == identity);
  check(model.panes.nextId() == identity + 1);

  const auto events = poller.wait(std::chrono::seconds{2});
  check(!events.empty());
  check(eventSource(events.front().token) == EventSource::pane);
  check(model.panes.findHandle(eventIdentity(events.front().token)) == pane);
  check(pane->read());
}

void testPersistence() {
  SystemAllocator memory;
  testMonotonicIdentities(memory);
  testIndependentHandles(memory);
  testExhaustedIdentities(memory);
  testCheckpointValidation();
  testRestore(memory);
  testLargePaneIdentity(memory);
  testAtomicFile(memory);
}
