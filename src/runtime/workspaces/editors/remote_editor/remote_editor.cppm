export module telar.runtime.workspaces.editors.remote_editor;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.workers.background_executor;
import telar.runtime.transport.connection;
import telar.base.editors;
import telar.platform.process;
import telar.wire.editor;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.runtime.host.process_probe;
import telar.base.ds;

// Interface: editors/remote_editor.cppm
export {
  namespace telar::runtime {

    class RemoteEditor {
    private:
      using Clock = std::chrono::steady_clock;

      // One open request: what it asks, the budgets it spends, and the candidate it opened, which views
      // the request's context. The editor keeps only the buffers every request reuses.
      struct Session {
        // What one request may spend: directory entries read, endpoints tried and commands run.
        static constexpr unsigned entry_budget = 128;
        static constexpr unsigned endpoint_budget = 32;
        static constexpr unsigned command_budget = 128;

        const OpenEditor& request;
        tbc::ref_a<RequestContext> context;
        EditorKind kind = EditorKind::unsupported;
        Clock::time_point deadline;
        unsigned entries_left = entry_budget;
        unsigned endpoints_left = endpoint_budget;
        unsigned commands_left = command_budget;
        tbc::val_a<const EditorCandidate*> opened = nullptr;
      };

    public:
      explicit RemoteEditor(ConcurrentMemory& memory);

      void open(const OpenEditor& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply);

    private:
      static constexpr std::size_t output_limit = std::size_t{16} * 1024;

      std::string_view command(Session& session, std::span<const std::string_view> arguments);
      static bool ownedPath(const char* path, bool directory) noexcept;
      void scan(Session& session, std::string_view root, bool descend);
      void discoverNeovim(Session& session);
      void discoverVim(Session& session);
      // A candidate of the session's context, region `a`.
      [[nodiscard]] tbc::val_a<const EditorCandidate*> candidate(const Session& session, pid_t pid) const noexcept;
      void quote(std::string_view value, bool lisp);
      void number(std::uint32_t value);
      void vimEndpoint(Session& session, std::string_view endpoint);
      void discoverEmacs(Session& session);
      void emacsEndpoint(Session& session, std::string_view endpoint);

      ConcurrentMemory& memory_;
      CommandOutput<ConcurrentMemory> output_;
      ds::String<ConcurrentMemory> expression_;
      ds::String<ConcurrentMemory> path_;
      ds::String<ConcurrentMemory> editor_;
      ProcessInspector inspector_;
    };

  }
}
