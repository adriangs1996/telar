#include "check.hpp"
#include "persistence/clone_session.hpp"
#include <filesystem>

using namespace telar;
using namespace telar::runtime;

static std::span<const Byte> cloneSource(std::span<Byte> buffer) {
  checkpoint::Writer writer{buffer, {11, 12, 13, 14}};
  writer.append(checkpoint::WorkspaceRecord{1, "/tmp", "Workspace", 2, "Tab"});
  writer.append(checkpoint::TabRecord{1, 3, "Second tab"});
  const char arguments[] = "/bin/cat\0";
  writer.append(checkpoint::PaneRecord{.id = 4, .workspace = 1, .tab = 2, .cwd = "/tmp", .columns = 80, .rows = 24, .argument_count = 1, .arguments = {arguments, sizeof(arguments) - 1}, .provider = AgentProvider::codex, .session = "session-one", .title = "Agent title", .title_source = AgentTitleSource::agent, .in_pane = true});
  writer.append(checkpoint::WorktreeRecord{.id = 5, .workspace = 1, .registration = {.request_id = 1, .source = 1, .created_by = 4, .origin = WorktreeOrigin::external, .path = "/tmp/worktree", .branch = "feature"}});
  return writer.finish();
}

static void checkClonedStructure(std::span<const Byte> copied) {
  checkpoint::Reader reader{copied};
  check(reader.counters.workspace == 11 && reader.counters.generation == 14);
  unsigned records = 0;
  reader.read([&]<typename Record>(const Record &record) {
    ++records;
    if constexpr (std::same_as<Record, checkpoint::PaneRecord>) {
      check(record.id == 4 && record.workspace == 1 && record.tab == 2);
      check(record.argument_count == 1 && record.arguments == std::string_view{"/bin/sh\0", 8});
      check(record.provider == AgentProvider::unknown && record.session.empty());
      check(record.title.empty() && !record.in_pane);
    } else if constexpr (std::same_as<Record, checkpoint::WorktreeRecord>) {
      check(false);
    }
  });
  check(records == 3);
}

template <typename Action>
static bool fails(Action &&action) {
  try {
    action();
  } catch (const std::exception &) {
    return true;
  }
  return false;
}

void testClone() {
  SystemAllocator memory;
  std::array<Byte, 4096> input;
  std::array<Byte, 4096> output;
  const auto source = cloneSource(input);
  const auto copied = checkpoint::clone(source, output, "/bin/sh");
  checkClonedStructure(copied);
  check(fails([&] { checkpoint::clone(source, std::span{output}.first(48), "/bin/sh"); }));
  check(fails([&] { checkpoint::clone(source, output, "relative"); }));
  check(fails([&] { checkpoint::clone(source.first(source.size() - 1), output, "/bin/sh"); }));

  std::array<char, 64> temporary;
  std::strcpy(temporary.data(), "/tmp/telar-clone-test-XXXXXX");
  check(::mkdtemp(temporary.data()) != nullptr);
  const std::filesystem::path root{temporary.data()};
  const auto source_path = (root / "source.ckpt").string();
  const auto destination = (root / "destination.ckpt").string();
  const auto socket = (root / "runtime.sock").string();
  const std::string source_socket = "/tmp/source/runtime.sock";
  checkpoint::FileStore source_file{memory, source_path};
  check(source_file.observe(source) == 0);
  checkpoint::CloneOptions options{source_path, source_socket, "/bin/sh"};
  checkpoint::prepareClone(memory, options, destination, socket);
  checkpoint::FileStore clone_file{memory, destination};
  Vector<Byte, SystemAllocator> bytes{AllocatorRef<Byte, SystemAllocator>{memory}};
  check(clone_file.load(bytes));
  checkClonedStructure(bytes);
  const auto original = bytes;
  checkpoint::FileStore marker{memory, socket + ".desktop-clone.json"};
  check(marker.load(bytes));
  check(checkpoint::matchingCloneOrigin(memory, bytes, source_socket));
  check(!checkpoint::matchingCloneOrigin(memory, bytes, "/other/socket"));

  check(::unlink(source_path.c_str()) == 0);
  checkpoint::prepareClone(memory, options, destination, socket);
  check(clone_file.load(bytes) && bytes == original);
  options.source_socket = "/other/socket";
  check(fails([&] { checkpoint::prepareClone(memory, options, destination, socket); }));
  options.source_socket = source_socket;
  check(::unlink((socket + ".desktop-clone.json").c_str()) == 0);
  check(fails([&] { checkpoint::prepareClone(memory, options, destination, socket); }));
  check(clone_file.load(bytes) && bytes == original);
  const auto nested_destination = (root / "nested/session.ckpt").string();
  check(source_file.observe(source) == 0);
  checkpoint::prepareClone(memory, options, nested_destination, socket);
  checkpoint::FileStore nested_file{memory, nested_destination};
  check(nested_file.load(bytes));
  checkClonedStructure(bytes);
  check(::chmod(destination.c_str(), 0644) == 0);
  check(fails([&] { clone_file.load(bytes); }));
  check(::unlink(destination.c_str()) == 0);
  check(::mkfifo(destination.c_str(), 0600) == 0);
  check(fails([&] { clone_file.load(bytes); }));
  std::filesystem::remove_all(root);
}
