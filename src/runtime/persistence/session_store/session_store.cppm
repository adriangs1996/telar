module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.persistence.session_store;

import std;
import telar.tbc;

import telar.platform.process;

import telar.runtime.model.client_layouts;

import telar.runtime.platform.request_worker;
import telar.wire.vocabulary;
import telar.wire.layout;
import telar.wire.worktrees;
import telar.platform.primitives;
import telar.runtime.terminal.control;
import telar.runtime.agents.snapshot;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.runtime.agents.screen_inference;
import telar.runtime.model.slot_store;
import telar.base.ds;

// Interface: persistence/records.cppm
export {
  namespace telar::runtime::checkpoint {

    inline constexpr std::string_view magic = "TELARCKP";
    inline constexpr std::uint16_t current_version = 10;
    inline constexpr std::size_t maximum_bytes = std::size_t{4} * 1024 * 1024;

    enum class Kind : Byte {
      end,
      workspace,
      tab,
      pane,
      layout,
      worktree,
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
      std::uint64_t id = 0;
      std::uint64_t workspace = 0;
      std::uint64_t tab = 0;
      std::string_view cwd;
      std::uint16_t columns = 0;
      std::uint16_t rows = 0;
      std::uint16_t argument_count = 0;
      std::string_view arguments;
      AgentProvider provider = AgentProvider::unknown;
      std::string_view session;
      std::string_view title;
      AgentTitleSource title_source = AgentTitleSource::telar;
      bool in_pane = false;
    };

    struct LayoutRecord {
      std::uint64_t identity;
      std::uint64_t last_used;
      std::span<const Byte> payload;
    };

    struct WorktreeRecord {
      std::uint64_t id = 0;
      std::uint64_t workspace = 0;
      RegisterWorktree registration;
    };

    void validatePath(std::string_view path);

    void validateTitle(std::string_view title, AgentTitleSource source);

  }
}

// The bounds a checkpoint's records keep within, which the reader, the writer and the restore check.
namespace telar::runtime::checkpoint {
  inline constexpr std::size_t maximum_path_bytes = 4096;
  inline constexpr std::size_t maximum_name_bytes = 256;
  inline constexpr std::size_t maximum_label_bytes = 128;
  inline constexpr std::size_t maximum_panes = 256;
  inline constexpr std::size_t maximum_tabs = 64;
  inline constexpr std::size_t maximum_tab_panes = 64;
  inline constexpr std::size_t maximum_arguments = 64;
  inline constexpr std::size_t maximum_argument_bytes = std::size_t{128} * 1024;
  inline constexpr std::size_t maximum_session_bytes = 64;
  inline constexpr std::size_t maximum_layout_bytes = std::size_t{16} * 1024;
}

// Interface: persistence/file_store.cppm
export {
  namespace telar::runtime::checkpoint {

    template <Allocator Memory>
    class FileStore {
    public:
      using Request = std::span<const Byte>;
      using Result = int;

      explicit FileStore(Memory& memory, std::string_view path);

      bool load(ds::Vec<Byte, Memory>& bytes);

      [[nodiscard]] FileDescriptor lock() const;

      Result observe(const Request& bytes) noexcept;

      void quarantine() noexcept;

      void stop() noexcept;

      static void setAside(Memory& memory, std::string_view path);

    private:
      FileDescriptor parent_;
      ds::String<Memory> name_;
    };

    template <Allocator Memory>
    FileStore(Memory& memory, std::string_view path) -> FileStore<Memory>;

    extern template class FileStore<SystemAllocator>;
    extern template class FileStore<ConcurrentMemory>;

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
      explicit Reader(std::span<const Byte> bytes);

      // Generic over the caller's consumer, which each record is handed to.
      template <typename Consumer>
      TBC_GENERIC inline void read(Consumer consume) {
        for (;;) {
          const auto kind = u8::decode(input_);
          if (kind > static_cast<Byte>(Kind::worktree)) {
            throw EncodingError{"Unknown checkpoint record"};
          }

          switch (static_cast<Kind>(kind)) {
          case Kind::end:
            if (!input_.empty()) {
              throw EncodingError{"Trailing checkpoint bytes"};
            }

            return;
          case Kind::workspace:
            consume(workspace());
            break;
          case Kind::tab:
            consume(tab());
            break;
          case Kind::pane:
            if (const auto record = pane()) {
              consume(*record);
            }

            break;
          case Kind::layout:
            consume(layout());
            break;
          case Kind::worktree:
            if (const auto record = worktree(); accepted(record)) {
              consume(record);
            }

            break;
          }
        }
      }

      // Public beside the reader's private input, as a restore reads them once the header is read.
      Counters counters; // NOLINT(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)

    private:
      bool boolean();

      std::string_view text(std::size_t length);

      std::string_view text16();

      std::span<const Byte> bytes32();

      WorkspaceRecord workspace();

      TabRecord tab();

      // A pane to restore, counted against the most a checkpoint holds; nothing for one left out.
      ds::Option<PaneRecord> pane();

      LayoutRecord layout();

      WorktreeRecord worktree();

      // Whether a worktree record is one to restore; one that is not is counted as skipped.
      bool accepted(const WorktreeRecord& record);

      std::span<const Byte> input_;
      std::uint16_t version_;
      std::size_t skipped_worktrees_ = 0;
      std::size_t pane_count_ = 0;
    };

  }
}

// Interface: persistence/restore.cppm
export {
  namespace telar::runtime::checkpoint {

    // The service that launches the restored panes and writes the input that resumes their agents.
    template <typename Panes>
    concept PaneLauncher = requires(Panes& panes, RuntimeModel& model, Command<ConcurrentMemory>& command, Pane& pane, TabLocation location, TerminalSize size, std::uint64_t identity) {
      panes.launch(model, nullptr, false, command, location, size, identity).id;
      panes.flushInput(pane);
    };

    // Kept whole: generic over the pane launcher, PaneService in telar.runtime.runtime, which imports this module.
    template <PaneLauncher Panes>
    class TBC_GENERIC Restore {
    public:
      // The panes it launches keep the allocator, so everything the restore reaches lives in region `a`.
      inline explicit Restore(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<RuntimeModel> model, tbc::mut_a<Panes> panes, tbc::mut_a<ClientLayouts> layouts, bool resume_agents)
          : memory_(memory),
            model_(model),
            panes_(panes),
            layouts_(layouts),
            resume_agents_(resume_agents) {}

      inline void apply(std::span<const Byte> bytes) {
        Reader reader{bytes};

        model_.next_pane_generation = std::max(model_.next_pane_generation, reader.counters.generation);
        ds::Array<PaneRecord, maximum_panes> records;
        std::size_t count = 0;

        reader.read([&]<typename Record>(const Record& record) {
          if constexpr (std::same_as<Record, PaneRecord>) {
            records.atMut(count++) = record;
          } else if constexpr (!std::same_as<Record, LayoutRecord>) {
            try {
              restore(record);
            } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a record that cannot be restored is left out, and the rest restore
            }
          }
        });

        const auto panes = records.viewMut().first(count);

        std::ranges::sort(panes, {}, &PaneRecord::id);
        for (const auto& record : panes) {
          try {
            restore(record);
          } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a pane that cannot be restored is left out, and the rest restore
          }
        }

        model_.panes.advanceCounter(reader.counters.pane);
        model_.workspaces.advanceCounter(reader.counters.workspace);
        advanceIdentityCounter(model_.next_tab_id, reader.counters.tab);
        dropEmptyTabs();

        Reader layouts{bytes};

        layouts.read([&]<typename Record>(const Record& record) {
          if constexpr (std::same_as<Record, LayoutRecord>) {
            try {
              constexpr std::size_t scratch_bytes = std::size_t{64} * 1024;
              ds::Array<Byte, scratch_bytes> scratch; // NOLINT(cppcoreguidelines-pro-type-member-init): the decoder writes what it reads back, so zeroing 64 KiB per layout would be waste
              DecodeStorage storage{scratch.viewMut()};

              layouts_.retain(model_, record.identity, Codec::decode<UpdateClientLayout>(record.payload, storage));
            } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a layout that cannot be decoded is left out, as one never saved
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

      inline void restore(const WorkspaceRecord& record) {
        validateIdentity(record.id);
        validateIdentity(record.first_tab);
        auto workspace = ds::makeBox<Workspace>(memory_, memory_, record.id, record.path, record.name);

        workspace.getMut().tabs.emplace(memory_, record.first_tab, record.first_label);
        model_.workspaces.insert(record.id, std::move(workspace));
        advanceIdentityCounter(model_.next_tab_id, record.first_tab + 1);
      }

      inline void restore(const TabRecord& record) {
        validateIdentity(record.id);
        auto* workspace = model_.workspaces.find(record.workspace);
        if (workspace == nullptr || workspace->tabs.size() == maximum_tabs || workspace->tab(record.id) != nullptr) {
          return;
        }

        workspace->tabs.emplace(memory_, record.id, record.label);
        advanceIdentityCounter(model_.next_tab_id, record.id + 1);
      }

      inline void restore(const WorktreeRecord& record) {
        const auto registered = model_.worktrees.registerEntry(record.registration, record.id);

        if (record.workspace != 0) {
          model_.worktrees.find(registered.worktree)->workspace = record.workspace;
        }
      }

      inline void restore(const PaneRecord& record) {
        validateIdentity(record.id);
        auto* workspace = model_.workspaces.find(record.workspace);
        const auto* tab = workspace == nullptr ? nullptr : workspace->tab(record.tab);
        if (tab == nullptr || tab->panes.size() == maximum_tab_panes || model_.panes.find(record.id) != nullptr) {
          return;
        }

        ds::Array<std::string_view, maximum_arguments> original;
        auto remaining = record.arguments;

        for (std::size_t index = 0; index < record.argument_count; ++index) {
          const auto end = remaining.find('\0');

          original.atMut(index) = remaining.substr(0, end);
          remaining.remove_prefix(end + 1);
        }

        ds::Option<AgentResume> resume = resumable(record);
        ds::Array<std::string_view, 4> resume_storage;
        const auto resumed_count = resume ? resumeArguments(*resume, resume_storage).size() : 0;
        const bool direct = resumed_count != 0 && original[0].substr(original[0].rfind('/') + 1) == resume_storage[0];
        if (direct) {
          resume_storage.atMut(0) = original[0];
        }

        // Viewed once the program the pane ran is in place.
        const auto resumed = std::span<const std::string_view>{resume_storage}.first(resumed_count);

        const auto arguments = direct ? resumed : std::span<const std::string_view>{original}.first(record.argument_count);
        Command command{memory_, Launch{.cwd = record.cwd, .arguments = arguments}};
        const TerminalSize size{.cols = record.columns == 0 ? std::uint16_t{80} : record.columns, .rows = record.rows == 0 ? std::uint16_t{24} : record.rows, .cell_width_px = 0, .cell_height_px = 0};
        // Launching changes the model: the tab is found again, and the pane by its identity.
        // No client asked for it: its shell keeps its prompt, which telar's editor covers.
        const auto identity = panes_.launch(model_, nullptr, false, command, TabLocation{.workspace = {.id = record.workspace}, .tab_id = record.tab}, size, record.id).id;

        model_.workspaces.find(record.workspace)->tabMut(record.tab)->panes.push(identity);
        auto& pane = *model_.panes.find(identity);

        pane.launch.restore(record.arguments, record.argument_count);
        pane.restored_agent = resume;

        if (resume && !direct) {
          writeResume(pane.input, resumed);
          // Writing the input may grow its buffer, so the pane is found again.
          panes_.flushInput(*model_.panes.find(identity));
        }
      }

      // Types the command that resumes an agent, its words separated by spaces, and presses enter.
      inline static void writeResume(ByteQueue<ConcurrentMemory>& input, std::span<const std::string_view> words) {
        for (std::size_t index = 0; index < words.size(); ++index) {
          constexpr Byte separator = ' ';

          if (index != 0) {
            input.append({&separator, 1});
          }

          input.append(byteView(words[index]));
        }

        constexpr Byte enter = '\r';

        input.append({&enter, 1});
      }

      [[nodiscard]] inline ds::Option<AgentResume> resumable(const PaneRecord& record) const {
        if (!resume_agents_ || !validResumeSession(record.provider, record.session)) {
          return ds::none;
        }

        for (const auto* pane : model_.panes.items()) {
          if (pane != nullptr && pane->restored_agent && pane->restored_agent->provider == record.provider && pane->restored_agent->session.view() == record.session) {
            return ds::none;
          }
        }

        AgentResume resume{.provider = record.provider, .title_source = record.title_source, .in_pane = record.in_pane};

        resume.session.assign(record.session);
        resume.title.assign(record.title);
        return resume;
      }

      inline void dropEmptyTabs() {
        ds::Array<std::uint64_t, WorkspaceStore::capacity> emptied{};
        std::size_t count = 0;

        // By index: changing a workspace borrows the store it lies in.
        for (std::size_t index = 0; index < model_.workspaces.items().size(); ++index) {
          auto* workspace = model_.workspaces.items()[index];
          if (workspace == nullptr) {
            continue;
          }

          workspace->tabs.retain([](const auto& tab) {
            return !tab.panes.empty();
          });

          if (workspace->tabs.empty()) {
            emptied.atMut(count++) = workspace->id;
          }
        }

        // Erasing releases a workspace, so the store is not walked while it erases.
        for (const auto identity : std::span{emptied}.first(count)) {
          model_.workspaces.erase(identity);
        }

        for (auto* worktree : model_.worktrees.items()) {
          if (worktree != nullptr && worktree->workspace && model_.workspaces.find(*worktree->workspace) == nullptr) {
            worktree->workspace.reset();
          }
        }
      }

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::mut_a<RuntimeModel> model_;
      tbc::mut_a<Panes> panes_;
      tbc::mut_a<ClientLayouts> layouts_;
      bool resume_agents_;
    };

  }
}

// Interface: persistence/writer.cppm
export {
  namespace telar::runtime::checkpoint {

    // Writes a checkpoint into the caller's buffer, region `a`, which the finished bytes view.
    class Writer {
    public:
      explicit Writer(tbc::val_a<std::span<Byte>> buffer, Counters counters);

      template <typename Record>
      void append(const Record& record);

      tbc::val_a<std::span<const Byte>> finish();

      // The records left out for want of room.
      [[nodiscard]] std::size_t dropped() const noexcept;

    private:
      struct CapacityReached : std::exception {};

      void require(std::size_t count);

      template <std::unsigned_integral Integer>
      void integer(Integer value);

      void raw(std::string_view value);

      void text16(std::string_view value);

      void text32(std::string_view value);

      void kind(Kind value);

      void write(const WorkspaceRecord& record);

      void write(const TabRecord& record);

      void write(const PaneRecord& record);

      void write(const WorktreeRecord& record);

      void write(const LayoutRecord& record);

      tbc::val_a<std::span<Byte>> buffer_;
      tbc::val_a<std::span<Byte>> remaining_;
      std::size_t dropped_ = 0;
    };

    extern template void Writer::append<WorkspaceRecord>(const WorkspaceRecord& record);
    extern template void Writer::append<TabRecord>(const TabRecord& record);
    extern template void Writer::append<PaneRecord>(const PaneRecord& record);
    extern template void Writer::append<WorktreeRecord>(const WorktreeRecord& record);
    extern template void Writer::append<LayoutRecord>(const LayoutRecord& record);

  }
}

// Interface: persistence/snapshot.cppm
export {
  namespace telar::runtime::checkpoint {

    template <typename Source>
    concept AgentSource = requires(const Source& source, std::uint64_t identity) {
      { source.find(identity, identity) } noexcept -> std::same_as<const Agent*>;
      { source.revision() } noexcept -> std::same_as<std::uint64_t>;
    };

    // Encodes the session the model, the layouts and the agents describe, which each call lends. It keeps
    // only the stamps that tell whether the session changed.
    // Kept whole: generic over the agents, AgentService in telar.runtime.runtime and persistence_test's SnapshotAgents.
    template <AgentSource Agents>
    class TBC_GENERIC Snapshot {
    public:
      // The bytes view the buffer.
      inline static tbc::val_a<std::span<const Byte>> encode(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents, tbc::val_a<std::span<Byte>> buffer, std::size_t& dropped) {
        Writer writer{buffer, Counters{.workspace = model.workspaces.nextCounter(), .tab = model.next_tab_id, .pane = model.panes.nextCounter(), .generation = model.next_pane_generation}};

        for (const auto* workspace : model.workspaces.items()) {
          if (workspace == nullptr || workspace->tabs.empty()) {
            continue;
          }

          const auto& first = workspace->tabs.front();

          writer.append(WorkspaceRecord{.id = workspace->id, .path = workspace->path, .name = workspace->name, .first_tab = first.id, .first_label = first.label});
          for (std::size_t index = 1; index < workspace->tabs.size(); ++index) {
            const auto& tab = workspace->tabs[index];

            writer.append(TabRecord{.workspace = workspace->id, .id = tab.id, .label = tab.label});
          }
        }

        for (const auto* worktree : model.worktrees.items()) {
          if (worktree == nullptr) {
            continue;
          }

          const auto entry = worktree->entry();

          writer.append(WorktreeRecord{.id = entry.worktree, .workspace = entry.workspace.valueOr(0), .registration = RegisterWorktree{.source = entry.source, .created_by = entry.created_by, .origin = entry.origin, .path = entry.path, .branch = entry.branch, .base = entry.base, .title = entry.title, .brief = entry.brief, .dispatched_from = entry.dispatched_from, .coordinator = entry.coordinator}});
        }

        for (const auto* pane : model.panes.items()) {
          if (pane == nullptr || pane->output_closed || pane->exit_status || pane->close_requested || pane->launch.count() == 0) {
            continue;
          }

          PaneRecord record{.id = pane->id, .workspace = pane->location.workspace.id, .tab = pane->location.tab_id, .cwd = pane->cwd, .columns = pane->terminal.screen.cols, .rows = pane->terminal.screen.rows, .argument_count = pane->launch.count(), .arguments = pane->launch.bytes()};

          if (const auto* agent = agents.find(pane->id, pane->generation); agent != nullptr && validResumeSession(agent->provider, agent->session.view())) {
            record.provider = agent->provider;
            record.session = agent->session.view();
            if (!agent->title.view().empty() && agent->title_source != AgentTitleSource::telar) {
              record.title = agent->title.view();
              record.title_source = agent->title_source;
            }

            record.in_pane = agent->in_pane;
          } else if (pane->restored_agent) {
            const auto& resume = *pane->restored_agent;

            record.provider = resume.provider;
            record.session = resume.session.view();
            record.title = resume.title.view();
            record.title_source = resume.title_source;
            record.in_pane = resume.in_pane;
          }

          writer.append(record);
        }

        ds::Array<Byte, maximum_layout_bytes> payload; // NOLINT(cppcoreguidelines-pro-type-member-init): Codec::encode writes the bytes each record views, so zeroing 16 KiB per snapshot would be waste

        layouts.exportRecords(model, [&](std::uint64_t identity, std::uint64_t last_used, const UpdateClientLayout& layout) {
          writer.append(LayoutRecord{.identity = identity, .last_used = last_used, .payload = Codec::encode(layout, payload.viewMut())});
        });

        dropped = writer.dropped();
        return writer.finish();
      }

      inline bool changed(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents) noexcept {
        const ds::Array revisions{model.workspace_revision, layouts.revision(), agents.revision()};
        bool changed = revisions != revisions_;

        revisions_ = revisions;
        const auto panes = model.panes.items();

        for (std::size_t index = 0; index < panes.size(); ++index) {
          const auto* pane = panes[index];
          const PaneStamp stamp = pane == nullptr ? PaneStamp{} : PaneStamp{pane->id, pane->cwd_revision, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->output_closed || pane->exit_status.hasValue() || pane->close_requested};

          changed |= stamp != stamps_[index];
          stamps_.atMut(index) = stamp;
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

        bool operator==(const PaneStamp&) const = default;
      };

      ds::Array<std::uint64_t, 3> revisions_{};
      // One stamp per pane slot, so `changed` indexes it with every slot the store can hold.
      ds::Array<PaneStamp, PaneStore::capacity> stamps_{};
    };

  }
}

// Interface: persistence/session_store.cppm
export {
  namespace telar::runtime::checkpoint {

    // Kept whole: generic over the agents, AgentService in telar.runtime.runtime, which imports this module.
    template <AgentSource Agents>
    class TBC_GENERIC SessionStore {
      using Clock = std::chrono::steady_clock;

    public:
      inline explicit SessionStore(ConcurrentMemory& memory)
          : memory_(memory),
            buffer_(memory) {}

      inline ~SessionStore() {
        if (worker_) {
          worker_.getMut().wait([](int) {});
        }
      }

      SessionStore(const SessionStore&) = delete;
      SessionStore& operator=(const SessionStore&) = delete;
      SessionStore(SessionStore&&) = delete;
      SessionStore& operator=(SessionStore&&) = delete;

      template <PaneLauncher Panes>
      inline void configure(RuntimeModel& model, Panes& panes, ClientLayouts& layouts, Options options) {
        if (options.path.empty()) {
          return;
        }

        FileStore<ConcurrentMemory> file{memory_, options.path};

        try {
          if (file.load(buffer_)) {
            Reader validation{buffer_};

            validation.read([](const auto&) {});
            Restore restore{memory_, model, panes, layouts, options.resume_agents};

            restore.apply(buffer_);
          }
        } catch (const EncodingError&) {
          file.quarantine();
        } catch (const std::exception&) { // NOLINT(bugprone-empty-catch): a session that cannot be read starts empty, and the next checkpoint replaces it
        }

        buffer_.resize(maximum_bytes);
        worker_.emplace(std::in_place, std::move(file));
        dirty_ = true;
        due_ = Clock::now() + debounce;
      }

      inline std::chrono::nanoseconds tick(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents, Clock::time_point now) {
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
          const auto bytes = Snapshot<Agents>::encode(model, layouts, agents, buffer_.viewMut(), dropped_records_);

          pending_ = worker_.getMut().submit(bytes);
          dirty_ = !pending_;
        } catch (const std::exception&) {
          dirty_ = false;
          ++encoding_failures_;
        }

        return std::chrono::seconds{1};
      }

      inline void collect() {
        if (worker_) {
          worker_.getMut().collect([&](int error) {
            completed(error);
          });
        }
      }

      inline void finish(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents) noexcept {
        if (!worker_) {
          return;
        }

        try {
          waitForWrite();
          if (snapshot_.changed(model, layouts, agents) || dirty_) {
            writeNow(model, layouts, agents);
          }
        } catch (const std::exception&) {
          ++encoding_failures_;
        }
      }

      inline int descriptor() const noexcept {
        return worker_ ? worker_->descriptor() : -1;
      }

    private:
      static constexpr std::chrono::milliseconds debounce{500};

      inline void waitForWrite() {
        worker_.getMut().wait([&](int error) {
          completed(error);
        });
      }

      inline void writeNow(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents) {
        const auto bytes = Snapshot<Agents>::encode(model, layouts, agents, buffer_.viewMut(), dropped_records_);
        if (worker_.getMut().submit(bytes)) {
          waitForWrite();
        }
      }

      inline void completed(int error) {
        pending_ = false;
        if (error != 0) {
          ++write_failures_;
          dirty_ = true;
          due_ = Clock::now() + debounce;
        }
      }

      ConcurrentMemory& memory_;
      Snapshot<Agents> snapshot_;
      ds::Vec<Byte, ConcurrentMemory> buffer_;
      // The worker stores the encoded buffer above until its result is collected, so the store stays put.
      tbc::val_self<ds::Option<ObservationWorker<FileStore<ConcurrentMemory>>>> worker_;
      Clock::time_point due_;
      bool dirty_ = false;
      bool pending_ = false;
      std::uint64_t write_failures_ = 0;
      std::uint64_t encoding_failures_ = 0;
      std::size_t dropped_records_ = 0;
    };

  }
}
