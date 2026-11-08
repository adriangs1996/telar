module;
#include "tbc/view.hpp"
#include "telar_platform/trace_macro.hpp"
#include <stdlib.h>
#include <ghostty/vt.h>
#include <zlib.h>

#include <cerrno>
#include <fcntl.h>
#include <limits.h>
#include <sys/stat.h>
#include <cstdint>
#include <cstdio>
#if (defined(__linux__) && !defined(__GLIBC__))
#include <linux/fs.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <sys/syscall.h>
#endif
#if (defined(__linux__) && !defined(__GLIBC__))
#include <unistd.h>
#endif
#include <unistd.h>
#include <cstdlib>
#include <sys/file.h>

#include "telar_base/diagnostics/config.hpp"
#include <sys/types.h>
#include <cassert>
#include <cstring>
#include <cstddef>
#include <sys/mman.h>
#include "cell_layout.hpp"
#include <csignal>
#include <sys/uio.h>
#include <sys/wait.h>
#if (defined(__APPLE__))
#include <sys/event.h>
#endif
#if (defined(__linux__))
#include <climits>
#endif
#if (defined(__linux__))
#include <sched.h>
#endif
#if (defined(__linux__))
#include <sys/epoll.h>
#endif
#if (defined(__linux__))
#include <sys/syscall.h>
#endif
#include <new>

#include <pthread.h>

export module telar.runtime.persistence.session_store;

import std;

export import telar.platform;


export import telar.runtime.model.client_layouts;
export import telar.runtime.runtime.execution_service;


export import telar.runtime.agents.snapshot;


export import telar.runtime.platform.request_worker;
import telar.client.protocol;
import telar.platform.primitives;
import telar.runtime.diagnostics.line;
import telar.runtime.graphics.kitty;
import telar.runtime.terminal.control;

// Interface: persistence/records.cppm
export {
namespace telar::runtime::checkpoint {

inline constexpr std::string_view magic = "TELARCKP";
inline constexpr std::uint16_t current_version = 10;
inline constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;

enum class Kind : Byte {
  end,
  workspace,
  tab,
  pane,
  layout,
  worktree
};

struct Counters {
  std::uint64_t workspace = 1;
  std::uint64_t tab = 1;
  std::uint64_t pane = 1;
  std::uint64_t generation = 1;
};

struct WorkspaceRecord {
  std::uint64_t id;
  std::string_view path;
  std::string_view name;
  std::uint64_t first_tab;
  std::string_view first_label;
};

struct TabRecord {
  std::uint64_t workspace;
  std::uint64_t id;
  std::string_view label;
};

struct PaneRecord {
  std::uint64_t id;
  std::uint64_t workspace;
  std::uint64_t tab;
  std::string_view cwd;
  std::uint16_t columns;
  std::uint16_t rows;
  std::uint16_t argument_count;
  std::string_view arguments;
  AgentProvider provider = AgentProvider::unknown;
  std::string_view session{};
  std::string_view title{};
  AgentTitleSource title_source = AgentTitleSource::telar;
  bool in_pane = false;
};

struct LayoutRecord {
  std::uint64_t identity;
  std::uint64_t last_used;
  std::span<const Byte> payload;
};

struct WorktreeRecord {
  std::uint64_t id;
  std::uint64_t workspace;
  RegisterWorktree registration;
};

inline void validatePath(std::string_view path) {
  if (path.empty() || path.size() > 4096 || path.find('\0') != std::string_view::npos) {
    throw EncodingError{"Invalid checkpoint directory"};
  }
}

inline void validateTitle(std::string_view title, AgentTitleSource source) {
  if (title.empty()) {
    if (source != AgentTitleSource::telar) {
      throw EncodingError{"Empty checkpoint title has a source"};
    }

    return;
  }

  DisplayText16<96, false>::validate(title);
  if (source != AgentTitleSource::generated && source != AgentTitleSource::manual && source != AgentTitleSource::agent) {
    throw EncodingError{"Checkpoint title is not durable"};
  }
}

}
}

// Interface: persistence/file_store.cppm
export {
namespace telar::runtime::checkpoint {

template <Allocator Memory>
class FileStore {
public:
  using Request = std::span<const Byte>;
  using Result = int;

  inline explicit FileStore(Memory &memory, std::string_view path)
      : parent_(openPrivateParent(path)),
        name_(path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}) {}

  inline bool load(Vector<Byte, Memory> &bytes) {
    return readPrivateFile(parent_.get(), name_, bytes, maximum_bytes);
  }

  inline FileDescriptor lock() const {
    std::array<char, NAME_MAX + 1> name;
    const auto length = std::snprintf(name.data(), name.size(), "%s.lock", name_.c_str());
    if (length < 0 || static_cast<std::size_t>(length) >= name.size()) {
      throw SystemError{"Session lock path is too long", ENAMETOOLONG};
    }

    FileDescriptor file{::openat(parent_.get(), name.data(), O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0600)};
    struct stat state{};
    if (!file || ::fstat(file.get(), &state) != 0) {
      throw SystemError{"Open session lock"};
    }
    if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || state.st_nlink != 1 || (state.st_mode & 0077) != 0) {
      throw SystemError{"Unsafe session lock", EACCES};
    }
    while (::flock(file.get(), LOCK_EX) != 0) {
      if (errno != EINTR) {
        throw SystemError{"Lock session"};
      }
    }
    return file;
  }

  inline Result observe(const Request &bytes) noexcept {
    return writePrivateFile(parent_.get(), name_, bytes, PrivateFileMode::replace);
  }

  inline void quarantine() noexcept {
    std::array<char, NAME_MAX + 1> destination;
    const auto length = std::snprintf(destination.data(), destination.size(), "%s.corrupt", name_.c_str());
    if (length >= 0 && static_cast<std::size_t>(length) < destination.size()) {
      ::renameat(parent_.get(), name_.c_str(), parent_.get(), destination.data());
    }
  }

  inline void stop() noexcept {}

  inline static void setAside(Memory &memory, std::string_view path) {
    const auto parent = openPrivateParent(path);
    const String<Memory> name{path.substr(path.rfind('/') + 1), AllocatorRef<char, Memory>{memory}};
    String<Memory> previous{name, AllocatorRef<char, Memory>{memory}};
    previous += ".previous";
    if (::renameat(parent.get(), name.c_str(), parent.get(), previous.c_str()) != 0 && errno != ENOENT) {
      throw SystemError{"Set previous session aside"};
    }
  }

private:
  FileDescriptor parent_;
  String<Memory> name_;
};

template <Allocator Memory>
FileStore(Memory &memory, std::string_view path) -> FileStore<Memory>;

}
}

// Interface: persistence/options.cppm
export {
namespace telar::runtime::checkpoint {

struct Options {
  std::string_view path;
  bool resume_agents = true;
};

}
}

// Interface: persistence/reader.cppm
export {
namespace telar::runtime::checkpoint {

class Reader {
public:
  inline explicit Reader(std::span<const Byte> bytes)
      : input_(bytes) {
    if (bytes.size() > maximum_bytes || text(magic.size()) != magic) {
      throw EncodingError{"Invalid checkpoint header"};
    }

    version_ = u16::decode(input_);
    if (version_ == 0 || version_ > current_version) {
      throw EncodingError{"Unsupported checkpoint version"};
    }

    counters = {u64::decode(input_), u64::decode(input_), u64::decode(input_), u64::decode(input_)};
    if (counters.workspace == 0 || counters.tab == 0 || counters.pane == 0 || counters.generation == 0) {
      throw EncodingError{"Invalid checkpoint counters"};
    }
  }

  template <typename Consumer>
  inline void read(Consumer &&consume) {
    std::size_t pane_count = 0;
    for (;;) {
      switch (static_cast<Kind>(u8::decode(input_))) {
      case Kind::end:
        if (!input_.empty()) {
          throw EncodingError{"Trailing checkpoint bytes"};
        }

        return;
      case Kind::workspace: {
        const WorkspaceRecord record{u64::decode(input_), text16(), text16(), u64::decode(input_), text16()};
        validatePath(record.path);
        if (record.name.size() > 256 || record.first_label.size() > 128 || (version_ < 3 && record.first_label.empty())) {
          throw EncodingError{"Invalid checkpoint workspace label"};
        }

        consume(record);
        break;
      }
      case Kind::tab: {
        const TabRecord record{u64::decode(input_), u64::decode(input_), text16()};
        if (record.label.size() > 128 || (version_ < 3 && record.label.empty())) {
          throw EncodingError{"Invalid checkpoint tab label"};
        }

        consume(record);
        break;
      }
      case Kind::pane: {
        const auto record = pane();
        if (!record) {
          break;
        }
        if (++pane_count > 256) {
          throw EncodingError{"Checkpoint has too many panes"};
        }

        consume(*record);
        break;
      }
      case Kind::layout: {
        const LayoutRecord record{u64::decode(input_), u64::decode(input_), bytes32()};
        if (record.payload.empty() || record.payload.size() > 16 * 1024) {
          throw EncodingError{"Invalid checkpoint layout size"};
        }

        consume(record);
        break;
      }
      case Kind::worktree: {
        const auto record = worktree();
        try {
          validatePath(record.registration.path);
          if (record.id == 0) {
            throw EncodingError{"Invalid checkpoint worktree identity"};
          }
          Codec::encodedSize(record.registration);
        } catch (const EncodingError &) {
          ++skipped_worktrees;
          break;
        }

        consume(record);
        break;
      }
      default:
        throw EncodingError{"Unknown checkpoint record"};
      }
    }
  }

  Counters counters;
  std::size_t skipped_worktrees = 0;

private:
  inline bool boolean() {
    const auto value = u8::decode(input_);
    if (value > 1) {
      throw EncodingError{"Invalid checkpoint boolean"};
    }

    return value != 0;
  }

  inline std::string_view text(std::size_t length) {
    if (length > input_.size()) {
      throw EncodingError{"Truncated checkpoint text"};
    }

    const std::string_view result{reinterpret_cast<const char *>(input_.data()), length};
    input_ = input_.subspan(length);
    return result;
  }

  inline std::string_view text16() {
    return text(u16::decode(input_));
  }

  inline std::span<const Byte> bytes32() {
    const auto value = text(u32::decode(input_));
    return {reinterpret_cast<const Byte *>(value.data()), value.size()};
  }

  inline std::optional<PaneRecord> pane() {
    PaneRecord record{u64::decode(input_), u64::decode(input_), u64::decode(input_), text16(), u16::decode(input_), u16::decode(input_), u16::decode(input_), {}};
    record.arguments = version_ >= 9 ? text(u32::decode(input_)) : text16();
    validatePath(record.cwd);
    if (record.argument_count > 64 || record.arguments.size() > 128 * 1024 || std::ranges::count(record.arguments, '\0') != record.argument_count) {
      throw EncodingError{"Invalid checkpoint launch arguments"};
    }

    record.provider = static_cast<AgentProvider>(u8::decode(input_));
    record.session = text16();
    if (!record.session.empty()) {
      validateAgentSession(record.session, false);
    }
    if (version_ >= 2) {
      record.title = text16();
      record.title_source = static_cast<AgentTitleSource>(u8::decode(input_));
    }
    validateTitle(record.title, record.title_source);

    record.in_pane = version_ >= 8 && boolean();
    if (version_ == 4 && boolean()) {
      return std::nullopt;
    }
    if (record.argument_count == 0) {
      throw EncodingError{"Checkpoint launch has no arguments"};
    }

    return record;
  }

  inline WorktreeRecord worktree() {
    WorktreeRecord record{};
    record.id = u64::decode(input_);
    auto &registration = record.registration;
    registration.request_id = 1;
    registration.source = u64::decode(input_);
    record.workspace = u64::decode(input_);
    const auto created_by = u64::decode(input_);
    if (created_by != 0) {
      registration.created_by = created_by;
    }
    registration.origin = static_cast<WorktreeOrigin>(u8::decode(input_));
    registration.path = text16();
    registration.branch = text16();
    registration.base = text16();
    registration.title = text16();
    registration.brief = text16();
    if (version_ >= 7) {
      registration.dispatched_from = text16();
    }
    if (version_ >= 10 && boolean()) {
      CoordinatorReference coordinator;
      const auto session = text(coordinator.session_id.size());
      std::copy(session.begin(), session.end(), coordinator.session_id.begin());
      coordinator.pane_id = u64::decode(input_);
      coordinator.pane_generation = u64::decode(input_);
      registration.coordinator = coordinator;
    }

    return record;
  }

  std::span<const Byte> input_;
  std::uint16_t version_;
};

}
}

// Interface: persistence/restore.cppm
export {
namespace telar::runtime::checkpoint {

template <Allocator Memory, EventLoop Poller, HistoryEventSink History = DiscardedHistory>
class Restore {
public:
  inline explicit Restore(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, ClientLayouts<Memory> &layouts, bool resume_agents)
      : memory_(memory),
        model_(model),
        panes_(panes),
        layouts_(layouts),
        resume_agents_(resume_agents) {}

  inline void apply(std::span<const Byte> bytes) {
    Reader reader{bytes};
    model_.next_pane_generation = std::max(model_.next_pane_generation, reader.counters.generation);
    std::array<PaneRecord, 256> records;
    std::size_t count = 0;
    reader.read([&]<typename Record>(const Record &record) {
      if constexpr (std::same_as<Record, PaneRecord>) {
        records[count++] = record;
      } else if constexpr (!std::same_as<Record, LayoutRecord>) {
        try {
          restore(record);
        } catch (const std::exception &) {
        }
      }
    });

    const auto panes = std::span{records}.first(count);
    std::ranges::sort(panes, {}, &PaneRecord::id);
    for (const auto &record : panes) {
      try {
        restore(record);
      } catch (const std::exception &) {
      }
    }

    model_.panes.advanceCounter(reader.counters.pane);
    model_.workspaces.advanceCounter(reader.counters.workspace);
    advanceIdentityCounter(model_.next_tab_id, reader.counters.tab);
    dropEmptyTabs();

    Reader layouts{bytes};
    layouts.read([&]<typename Record>(const Record &record) {
      if constexpr (std::same_as<Record, LayoutRecord>) {
        try {
          std::array<Byte, 64 * 1024> scratch;
          DecodeStorage storage{scratch};
          layouts_.retain(model_, record.identity, Codec::decode<UpdateClientLayout>(record.payload, storage));
        } catch (const std::exception &) {
        }
      }
    });

    ++model_.workspace_revision;
  }

private:
  inline static void validateIdentity(std::uint64_t identity) {
    if (identity == 0) {
      throw EncodingError{"Invalid restored identity"};
    }
  }

  inline void restore(const WorkspaceRecord &record) {
    validateIdentity(record.id);
    validateIdentity(record.first_tab);
    auto workspace = makeOwned<Workspace<Memory>>(memory_, memory_, record.id, record.path, record.name);
    workspace->tabs.emplace_back(memory_, record.first_tab, record.first_label);
    model_.workspaces.insert(record.id, std::move(workspace));
    advanceIdentityCounter(model_.next_tab_id, record.first_tab + 1);
  }

  inline void restore(const TabRecord &record) {
    validateIdentity(record.id);
    auto *workspace = model_.workspaces.find(record.workspace);
    if (workspace == nullptr || workspace->tabs.size() == 64 || workspace->tab(record.id) != nullptr) {
      return;
    }

    workspace->tabs.emplace_back(memory_, record.id, record.label);
    advanceIdentityCounter(model_.next_tab_id, record.id + 1);
  }

  inline void restore(const WorktreeRecord &record) {
    const auto registered = model_.worktrees.registerEntry(record.registration, record.id);
    if (record.workspace != 0) {
      model_.worktrees.find(registered.worktree)->workspace = record.workspace;
    }
  }

  inline void restore(const PaneRecord &record) {
    validateIdentity(record.id);
    auto *workspace = model_.workspaces.find(record.workspace);
    auto *tab = workspace == nullptr ? nullptr : workspace->tab(record.tab);
    if (tab == nullptr || tab->panes.size() == 64 || model_.panes.find(record.id) != nullptr) {
      return;
    }

    std::array<std::string_view, 64> original;
    auto remaining = record.arguments;
    for (std::size_t index = 0; index < record.argument_count; ++index) {
      const auto end = remaining.find('\0');
      original[index] = remaining.substr(0, end);
      remaining.remove_prefix(end + 1);
    }

    std::optional<AgentResume> resume = resumable(record);
    std::array<std::string_view, 4> resume_storage;
    auto resumed = resume ? resumeArguments(*resume, resume_storage) : std::span<const std::string_view>{};
    const bool direct = !resumed.empty() && original[0].substr(original[0].rfind('/') + 1) == resumed[0];
    if (direct) {
      resume_storage[0] = original[0];
    }

    const auto arguments = direct ? resumed : std::span<const std::string_view>{original}.first(record.argument_count);
    Command command{memory_, Launch{.cwd = record.cwd, .arguments = arguments}};
    const TerminalSize size{.cols = record.columns == 0 ? std::uint16_t{80} : record.columns, .rows = record.rows == 0 ? std::uint16_t{24} : record.rows, .cell_width_px = 0, .cell_height_px = 0};
    // Launching changes the model: the tab is found again, and the pane by its identity.
    const auto identity = panes_.launch(model_, nullptr, command, TabLocation{.workspace = {.id = record.workspace}, .tab_id = record.tab}, size, record.id).id;
    model_.workspaces.find(record.workspace)->tab(record.tab)->panes.push_back(identity);
    auto &pane = *model_.panes.find(identity);
    pane.launch.restore(record.arguments, record.argument_count);
    pane.restored_agent = resume;

    if (resume && !direct) {
      for (std::size_t index = 0; index < resumed.size(); ++index) {
        const Byte separator = index == 0 ? 0 : ' ';
        if (index != 0) {
          pane.input.append({&separator, 1});
        }
        pane.input.append({reinterpret_cast<const Byte *>(resumed[index].data()), resumed[index].size()});
      }
      constexpr Byte enter = '\r';
      pane.input.append({&enter, 1});
      panes_.flushInput(pane);
    }
  }

  inline std::optional<AgentResume> resumable(const PaneRecord &record) const {
    if (!resume_agents_ || !validResumeSession(record.provider, record.session)) {
      return std::nullopt;
    }

    for (const auto *pane : model_.panes.items()) {
      if (pane != nullptr && pane->restored_agent && pane->restored_agent->provider == record.provider && pane->restored_agent->session.view() == record.session) {
        return std::nullopt;
      }
    }

    AgentResume resume{.provider = record.provider, .title_source = record.title_source, .in_pane = record.in_pane};
    resume.session.assign(record.session);
    resume.title.assign(record.title);
    return resume;
  }

  inline void dropEmptyTabs() {
    for (auto *workspace : model_.workspaces.items()) {
      if (workspace == nullptr) {
        continue;
      }

      std::erase_if(workspace->tabs, [](const auto &tab) { return tab.panes.empty(); });
      if (workspace->tabs.empty()) {
        model_.workspaces.erase(workspace->id);
      }
    }

    for (auto *worktree : model_.worktrees.items()) {
      if (worktree != nullptr && worktree->workspace && model_.workspaces.find(*worktree->workspace) == nullptr) {
        worktree->workspace.reset();
      }
    }
  }

  Memory &memory_;
  RuntimeModel<Memory> &model_;
  PaneService<Memory, Poller, History> &panes_;
  ClientLayouts<Memory> &layouts_;
  bool resume_agents_;
};

template <Allocator Memory, EventLoop Poller, HistoryEventSink History>
Restore(Memory &memory, RuntimeModel<Memory> &model, PaneService<Memory, Poller, History> &panes, ClientLayouts<Memory> &layouts, bool resume_agents) -> Restore<Memory, Poller, History>;

}
}

// Interface: persistence/writer.cppm
export {
namespace telar::runtime::checkpoint {

class Writer {
public:
  inline explicit Writer(std::span<Byte> buffer, Counters counters)
      : buffer_(buffer),
        remaining_(buffer.empty() ? buffer : buffer.first(buffer.size() - 1)) {
    constexpr std::size_t header_bytes = magic.size() + sizeof(current_version) + 4 * sizeof(std::uint64_t);
    if (buffer.size() <= header_bytes) {
      throw EncodingError{"Checkpoint buffer cannot hold its header"};
    }

    raw(magic);
    integer(current_version);
    integer(counters.workspace);
    integer(counters.tab);
    integer(counters.pane);
    integer(counters.generation);
  }

  template <typename Record>
  inline void append(const Record &record) {
    if (dropped != 0) {
      ++dropped;
      return;
    }

    const auto previous = remaining_;
    try {
      write(record);
    } catch (const CapacityReached &) {
      remaining_ = previous;
      dropped = 1;
    }
  }

  inline std::span<const Byte> finish() {
    const auto count = buffer_.size() - remaining_.size() - 1;
    buffer_[count] = static_cast<Byte>(Kind::end);
    return buffer_.first(count + 1);
  }

  std::size_t dropped = 0;

private:
  struct CapacityReached {};

  inline void require(std::size_t count) {
    if (count > remaining_.size()) {
      throw CapacityReached{};
    }
  }

  template <std::unsigned_integral Integer>
  inline void integer(Integer value) {
    require(sizeof(value));
    LittleEndian<Integer>::encode(value, remaining_);
  }

  inline void raw(std::string_view value) {
    require(value.size());
    std::copy(value.begin(), value.end(), remaining_.begin());
    remaining_ = remaining_.subspan(value.size());
  }

  inline void text16(std::string_view value) {
    if (value.size() > UINT16_MAX) {
      throw EncodingError{"Checkpoint text exceeds its length field"};
    }

    integer(static_cast<std::uint16_t>(value.size()));
    raw(value);
  }

  inline void text32(std::string_view value) {
    if (value.size() > maximum_bytes) {
      throw EncodingError{"Checkpoint data exceeds file limit"};
    }

    integer(static_cast<std::uint32_t>(value.size()));
    raw(value);
  }

  inline void kind(Kind value) {
    integer(static_cast<Byte>(value));
  }

  inline void write(const WorkspaceRecord &record) {
    validatePath(record.path);
    if (record.name.size() > 256 || record.first_label.size() > 128) {
      throw EncodingError{"Invalid checkpoint workspace label"};
    }
    kind(Kind::workspace);
    integer(record.id);
    text16(record.path);
    text16(record.name);
    integer(record.first_tab);
    text16(record.first_label);
  }

  inline void write(const TabRecord &record) {
    kind(Kind::tab);
    integer(record.workspace);
    integer(record.id);
    text16(record.label);
  }

  inline void write(const PaneRecord &record) {
    validatePath(record.cwd);
    validateTitle(record.title, record.title_source);
    if (record.argument_count == 0 || record.argument_count > 64 || record.arguments.size() > 128 * 1024 || record.session.size() > 64) {
      throw EncodingError{"Invalid checkpoint launch record"};
    }
    kind(Kind::pane);
    integer(record.id);
    integer(record.workspace);
    integer(record.tab);
    text16(record.cwd);
    integer(record.columns);
    integer(record.rows);
    integer(record.argument_count);
    text32(record.arguments);
    integer(static_cast<Byte>(record.provider));
    text16(record.session);
    text16(record.title);
    integer(static_cast<Byte>(record.title_source));
    integer(static_cast<Byte>(record.in_pane));
  }

  inline void write(const WorktreeRecord &record) {
    const auto &registration = record.registration;
    auto checked = registration;
    checked.request_id = 1;
    Codec::encodedSize(checked);
    if (record.id == 0) {
      throw EncodingError{"Invalid checkpoint worktree identity"};
    }
    kind(Kind::worktree);
    integer(record.id);
    integer(registration.source);
    integer(record.workspace);
    integer(registration.created_by.value_or(0));
    integer(static_cast<Byte>(registration.origin));
    text16(registration.path);
    text16(registration.branch);
    text16(registration.base);
    text16(registration.title);
    text16(registration.brief);
    text16(registration.dispatched_from);
    integer(static_cast<Byte>(registration.coordinator.has_value()));
    if (registration.coordinator) {
      const auto &coordinator = *registration.coordinator;
      raw({reinterpret_cast<const char *>(coordinator.session_id.data()), coordinator.session_id.size()});
      integer(coordinator.pane_id);
      integer(coordinator.pane_generation);
    }
  }

  inline void write(const LayoutRecord &record) {
    if (record.payload.empty() || record.payload.size() > 16 * 1024) {
      throw EncodingError{"Invalid checkpoint layout size"};
    }
    kind(Kind::layout);
    integer(record.identity);
    integer(record.last_used);
    text32({reinterpret_cast<const char *>(record.payload.data()), record.payload.size()});
  }

  std::span<Byte> buffer_;
  std::span<Byte> remaining_;
};

}
}

// Interface: persistence/snapshot.cppm
export {
namespace telar::runtime::checkpoint {

template <typename Source>
concept AgentSource = requires(const Source &source, std::uint64_t identity) {
  { source.find(identity, identity) } noexcept -> std::same_as<const Agent *>;
  { source.revision() } noexcept -> std::same_as<std::uint64_t>;
};

// Encodes the session the model, the layouts and the agents describe, which each call lends. It keeps
// only the stamps that tell whether the session changed.
template <Allocator Memory, AgentSource Agents>
class Snapshot {
public:
  // The bytes view the buffer.
  inline static tbc::view<std::span<const Byte>, tbc::lt::a> encode(const RuntimeModel<Memory> &model, const ClientLayouts<Memory> &layouts, const Agents &agents, tbc::view<std::span<Byte>, tbc::lt::a> buffer, std::size_t &dropped) {
    Writer writer{buffer, Counters{model.workspaces.nextCounter(), model.next_tab_id, model.panes.nextCounter(), model.next_pane_generation}};
    for (const auto *workspace : model.workspaces.items()) {
      if (workspace == nullptr || workspace->tabs.empty()) {
        continue;
      }

      const auto &first = workspace->tabs.front();
      writer.append(WorkspaceRecord{workspace->id, workspace->path, workspace->name, first.id, first.label});
      for (std::size_t index = 1; index < workspace->tabs.size(); ++index) {
        const auto &tab = workspace->tabs[index];
        writer.append(TabRecord{workspace->id, tab.id, tab.label});
      }
    }

    for (const auto *worktree : model.worktrees.items()) {
      if (worktree == nullptr) {
        continue;
      }

      const auto entry = worktree->entry();
      writer.append(WorktreeRecord{entry.worktree, entry.workspace.value_or(0), RegisterWorktree{.source = entry.source, .created_by = entry.created_by, .origin = entry.origin, .path = entry.path, .branch = entry.branch, .base = entry.base, .title = entry.title, .brief = entry.brief, .dispatched_from = entry.dispatched_from, .coordinator = entry.coordinator}});
    }

    for (const auto *pane : model.panes.items()) {
      if (pane == nullptr || pane->output_closed || pane->exit_status || pane->close_requested || pane->launch.count() == 0) {
        continue;
      }

      PaneRecord record{pane->id, pane->location.workspace.id, pane->location.tab_id, pane->cwd, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->launch.count(), pane->launch.bytes()};
      if (const auto *agent = agents.find(pane->id, pane->generation); agent != nullptr && validResumeSession(agent->provider, agent->session.view())) {
        record.provider = agent->provider;
        record.session = agent->session.view();
        if (!agent->title.view().empty() && agent->title_source != AgentTitleSource::telar) {
          record.title = agent->title.view();
          record.title_source = agent->title_source;
        }
        record.in_pane = agent->in_pane;
      } else if (pane->restored_agent) {
        const auto &resume = *pane->restored_agent;
        record.provider = resume.provider;
        record.session = resume.session.view();
        record.title = resume.title.view();
        record.title_source = resume.title_source;
        record.in_pane = resume.in_pane;
      }
      writer.append(record);
    }

    std::array<Byte, 16 * 1024> payload;
    layouts.exportRecords(model, [&](std::uint64_t identity, std::uint64_t last_used, const UpdateClientLayout &layout) {
      writer.append(LayoutRecord{identity, last_used, Codec::encode(layout, payload)});
    });
    dropped = writer.dropped;
    return writer.finish();
  }

  inline bool changed(const RuntimeModel<Memory> &model, const ClientLayouts<Memory> &layouts, const Agents &agents) noexcept {
    const std::array revisions{model.workspace_revision, layouts.revision(), agents.revision()};
    bool changed = revisions != revisions_;
    revisions_ = revisions;
    const auto panes = model.panes.items();
    for (std::size_t index = 0; index < panes.size(); ++index) {
      const auto *pane = panes[index];
      const PaneStamp stamp = pane == nullptr ? PaneStamp{} : PaneStamp{pane->id, pane->cwd_revision, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->output_closed || pane->exit_status.has_value() || pane->close_requested};
      changed |= stamp != stamps_[index];
      stamps_[index] = stamp;
    }

    return changed;
  }

private:
  struct PaneStamp {
    std::uint64_t identity = 0;
    std::uint64_t cwd_revision = 0;
    std::uint16_t columns = 0;
    std::uint16_t rows = 0;
    bool closed = false;

    bool operator==(const PaneStamp &) const = default;
  };

  std::array<std::uint64_t, 3> revisions_{};
  std::array<PaneStamp, 256> stamps_{};
};

}
}

// Interface: persistence/session_store.cppm
export {
namespace telar::runtime::checkpoint {

template <ConcurrentAllocator Memory, EventLoop Poller, AgentSource Agents, HistoryEventSink History = DiscardedHistory>
class SessionStore {
  using Clock = std::chrono::steady_clock;

public:
  using Panes = PaneService<Memory, Poller, History>;

  inline explicit SessionStore(Memory &memory)
      : memory_(memory),
        buffer_(AllocatorRef<Byte, Memory>{memory}) {}

  inline ~SessionStore() {
    if (worker_) {
      worker_->wait([](int) {});
    }
  }

  inline void configure(RuntimeModel<Memory> &model, Panes &panes, ClientLayouts<Memory> &layouts, Options options) {
    if (options.path.empty()) {
      return;
    }

    FileStore<Memory> file{memory_, options.path};
    try {
      if (file.load(buffer_)) {
        Reader validation{buffer_};
        validation.read([](const auto &) {});
        Restore restore{memory_, model, panes, layouts, options.resume_agents};
        restore.apply(buffer_);
      }
    } catch (const EncodingError &) {
      file.quarantine();
    } catch (const std::exception &) {
    }

    buffer_.resize(maximum_bytes);
    worker_.emplace(std::in_place, std::move(file));
    dirty_ = true;
    due_ = Clock::now() + debounce;
  }

  inline std::chrono::nanoseconds tick(const RuntimeModel<Memory> &model, const ClientLayouts<Memory> &layouts, const Agents &agents, Clock::time_point now) {
    if (!worker_) {
      return std::chrono::seconds{1};
    }

    collect();
    if (snapshot_.changed(model, layouts, agents)) {
      dirty_ = true;
      due_ = now + debounce;
    }

    if (!dirty_ || pending_) {
      return std::chrono::seconds{1};
    }
    if (now < due_) {
      return due_ - now;
    }

    try {
      TELAR_TRACE("checkpoint.encode");
      const auto bytes = Snapshot<Memory, Agents>::encode(model, layouts, agents, buffer_, dropped_records);
      pending_ = worker_->submit(bytes);
      dirty_ = !pending_;
    } catch (const std::exception &) {
      dirty_ = false;
      ++encoding_failures;
    }

    return std::chrono::seconds{1};
  }

  inline void collect() {
    if (worker_) {
      worker_->collect([&](int error) { completed(error); });
    }
  }

  inline void finish(const RuntimeModel<Memory> &model, const ClientLayouts<Memory> &layouts, const Agents &agents) noexcept {
    if (!worker_) {
      return;
    }

    try {
      worker_->wait([&](int error) { completed(error); });
      if (snapshot_.changed(model, layouts, agents) || dirty_) {
        const auto bytes = Snapshot<Memory, Agents>::encode(model, layouts, agents, buffer_, dropped_records);
        if (worker_->submit(bytes)) {
          worker_->wait([&](int error) { completed(error); });
        }
      }
    } catch (const std::exception &) {
      ++encoding_failures;
    }
  }

  inline int descriptor() const noexcept {
    return worker_ ? worker_->descriptor() : -1;
  }

  std::uint64_t write_failures = 0;
  std::uint64_t encoding_failures = 0;
  std::size_t dropped_records = 0;

private:
  static constexpr std::chrono::milliseconds debounce{500};

  inline void completed(int error) {
    pending_ = false;
    if (error != 0) {
      ++write_failures;
      dirty_ = true;
      due_ = Clock::now() + debounce;
    }
  }

  Memory &memory_;
  Snapshot<Memory, Agents> snapshot_;
  Vector<Byte, Memory> buffer_;
  std::optional<ObservationWorker<FileStore<Memory>>> worker_;
  Clock::time_point due_{};
  bool dirty_ = false;
  bool pending_ = false;
};

}
}
