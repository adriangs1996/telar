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
    inline constexpr std::size_t maximum_bytes = 4 * 1024 * 1024;

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

    void validatePath(std::string_view path);

    void validateTitle(std::string_view title, AgentTitleSource source);

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

      explicit FileStore(Memory& memory, std::string_view path);

      bool load(Vector<Byte, Memory>& bytes);

      FileDescriptor lock() const;

      Result observe(const Request& bytes) noexcept;

      void quarantine() noexcept;

      void stop() noexcept;

      static void setAside(Memory& memory, std::string_view path);

    private:
      FileDescriptor parent_;
      String<Memory> name_;
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
      TBC_GENERIC inline void read(Consumer&& consume) {
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
            } catch (const EncodingError&) {
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
      bool boolean();

      std::string_view text(std::size_t length);

      std::string_view text16();

      std::span<const Byte> bytes32();

      ds::Option<PaneRecord> pane();

      WorktreeRecord worktree();

      std::span<const Byte> input_;
      std::uint16_t version_;
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
      inline explicit Restore(tbc::view<ConcurrentMemory&, tbc::lt::a> memory, tbc::view<RuntimeModel&, tbc::lt::a> model, tbc::view<Panes&, tbc::lt::a> panes, tbc::view<ClientLayouts&, tbc::lt::a> layouts, bool resume_agents)
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

        reader.read([&]<typename Record>(const Record& record) {
          if constexpr (std::same_as<Record, PaneRecord>) {
            records[count++] = record;
          } else if constexpr (!std::same_as<Record, LayoutRecord>) {
            try {
              restore(record);
            } catch (const std::exception&) {
            }
          }
        });

        const auto panes = std::span{records}.first(count);

        std::ranges::sort(panes, {}, &PaneRecord::id);
        for (const auto& record : panes) {
          try {
            restore(record);
          } catch (const std::exception&) {
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
              std::array<Byte, 64 * 1024> scratch;
              DecodeStorage storage{scratch};

              layouts_.retain(model_, record.identity, Codec::decode<UpdateClientLayout>(record.payload, storage));
            } catch (const std::exception&) {
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
        auto workspace = makeOwned<Workspace>(memory_, memory_, record.id, record.path, record.name);

        workspace->tabs.emplace_back(memory_, record.first_tab, record.first_label);
        model_.workspaces.insert(record.id, std::move(workspace));
        advanceIdentityCounter(model_.next_tab_id, record.first_tab + 1);
      }

      inline void restore(const TabRecord& record) {
        validateIdentity(record.id);
        auto* workspace = model_.workspaces.find(record.workspace);
        if (workspace == nullptr || workspace->tabs.size() == 64 || workspace->tab(record.id) != nullptr) {
          return;
        }

        workspace->tabs.emplace_back(memory_, record.id, record.label);
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
        auto* tab = workspace == nullptr ? nullptr : workspace->tab(record.tab);
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

        ds::Option<AgentResume> resume = resumable(record);
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
        // No client asked for it: its shell keeps its prompt, which telar's editor covers.
        const auto identity = panes_.launch(model_, nullptr, false, command, TabLocation{.workspace = {.id = record.workspace}, .tab_id = record.tab}, size, record.id).id;

        model_.workspaces.find(record.workspace)->tabMut(record.tab)->panes.push_back(identity);
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

          input.append({reinterpret_cast<const Byte*>(words[index].data()), words[index].size()});
        }

        constexpr Byte enter = '\r';

        input.append({&enter, 1});
      }

      inline ds::Option<AgentResume> resumable(const PaneRecord& record) const {
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
        std::array<std::uint64_t, WorkspaceStore::capacity> emptied{};
        std::size_t count = 0;

        for (auto* workspace : model_.workspaces.items()) {
          if (workspace == nullptr) {
            continue;
          }

          std::erase_if(workspace->tabs, [](const auto& tab) {
            return tab.panes.empty();
          });

          if (workspace->tabs.empty()) {
            emptied[count++] = workspace->id;
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

      tbc::view<ConcurrentMemory&, tbc::lt::a> memory_;
      tbc::view<RuntimeModel&, tbc::lt::a> model_;
      tbc::view<Panes&, tbc::lt::a> panes_;
      tbc::view<ClientLayouts&, tbc::lt::a> layouts_;
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
      explicit Writer(tbc::view<std::span<Byte>, tbc::lt::a> buffer, Counters counters);

      template <typename Record>
      void append(const Record& record);

      tbc::view<std::span<const Byte>, tbc::lt::a> finish();

      std::size_t dropped = 0;

    private:
      struct CapacityReached {};

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

      tbc::view<std::span<Byte>, tbc::lt::a> buffer_;
      tbc::view<std::span<Byte>, tbc::lt::a> remaining_;
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
      inline static tbc::view<std::span<const Byte>, tbc::lt::a> encode(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents, tbc::view<std::span<Byte>, tbc::lt::a> buffer, std::size_t& dropped) {
        Writer writer{buffer, Counters{model.workspaces.nextCounter(), model.next_tab_id, model.panes.nextCounter(), model.next_pane_generation}};

        for (const auto* workspace : model.workspaces.items()) {
          if (workspace == nullptr || workspace->tabs.empty()) {
            continue;
          }

          const auto& first = workspace->tabs.front();

          writer.append(WorkspaceRecord{workspace->id, workspace->path, workspace->name, first.id, first.label});
          for (std::size_t index = 1; index < workspace->tabs.size(); ++index) {
            const auto& tab = workspace->tabs[index];

            writer.append(TabRecord{workspace->id, tab.id, tab.label});
          }
        }

        for (const auto* worktree : model.worktrees.items()) {
          if (worktree == nullptr) {
            continue;
          }

          const auto entry = worktree->entry();

          writer.append(WorktreeRecord{entry.worktree, entry.workspace.valueOr(0), RegisterWorktree{.source = entry.source, .created_by = entry.created_by, .origin = entry.origin, .path = entry.path, .branch = entry.branch, .base = entry.base, .title = entry.title, .brief = entry.brief, .dispatched_from = entry.dispatched_from, .coordinator = entry.coordinator}});
        }

        for (const auto* pane : model.panes.items()) {
          if (pane == nullptr || pane->output_closed || pane->exit_status || pane->close_requested || pane->launch.count() == 0) {
            continue;
          }

          PaneRecord record{pane->id, pane->location.workspace.id, pane->location.tab_id, pane->cwd, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->launch.count(), pane->launch.bytes()};

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

        std::array<Byte, 16 * 1024> payload;

        layouts.exportRecords(model, [&](std::uint64_t identity, std::uint64_t last_used, const UpdateClientLayout& layout) {
          writer.append(LayoutRecord{identity, last_used, Codec::encode(layout, payload)});
        });

        dropped = writer.dropped;
        return writer.finish();
      }

      inline bool changed(const RuntimeModel& model, const ClientLayouts& layouts, const Agents& agents) noexcept {
        const std::array revisions{model.workspace_revision, layouts.revision(), agents.revision()};
        bool changed = revisions != revisions_;

        revisions_ = revisions;
        const auto panes = model.panes.items();

        for (std::size_t index = 0; index < panes.size(); ++index) {
          const auto* pane = panes[index];
          const PaneStamp stamp = pane == nullptr ? PaneStamp{} : PaneStamp{pane->id, pane->cwd_revision, pane->terminal.screen.cols, pane->terminal.screen.rows, pane->output_closed || pane->exit_status.hasValue() || pane->close_requested};

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

        bool operator==(const PaneStamp&) const = default;
      };

      std::array<std::uint64_t, 3> revisions_{};
      // One stamp per pane slot, so `changed` indexes it with every slot the store can hold.
      std::array<PaneStamp, PaneStore::capacity> stamps_{};
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
            buffer_(AllocatorRef<Byte, ConcurrentMemory>{memory}) {}

      inline ~SessionStore() {
        if (worker_) {
          worker_.getMut().wait([](int) {});
        }
      }

      SessionStore(const SessionStore&) = delete;
      SessionStore& operator=(const SessionStore&) = delete;

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
        } catch (const std::exception&) {
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
          const auto bytes = Snapshot<Agents>::encode(model, layouts, agents, buffer_, dropped_records);

          pending_ = worker_.getMut().submit(bytes);
          dirty_ = !pending_;
        } catch (const std::exception&) {
          dirty_ = false;
          ++encoding_failures;
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
          worker_.getMut().wait([&](int error) {
            completed(error);
          });

          if (snapshot_.changed(model, layouts, agents) || dirty_) {
            const auto bytes = Snapshot<Agents>::encode(model, layouts, agents, buffer_, dropped_records);
            if (worker_.getMut().submit(bytes)) {
              worker_.getMut().wait([&](int error) {
                completed(error);
              });
            }
          }
        } catch (const std::exception&) {
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

      ConcurrentMemory& memory_;
      Snapshot<Agents> snapshot_;
      Vector<Byte, ConcurrentMemory> buffer_;
      // The worker stores the encoded buffer above until its result is collected, so the store stays put.
      tbc::view<ds::Option<ObservationWorker<FileStore<ConcurrentMemory>>>, tbc::lt::self> worker_;
      Clock::time_point due_{};
      bool dirty_ = false;
      bool pending_ = false;
    };

  }
}
