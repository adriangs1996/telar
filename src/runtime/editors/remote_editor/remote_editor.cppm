export module telar.runtime.editors.remote_editor;

import std;
import telar.sys.posix;
import telar.tbc;

import telar.runtime.platform.background_executor;
import telar.runtime.transport.connection;
import telar.base.editors;
import telar.platform.process;
import telar.wire.editor;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.runtime.platform.process_probe;

// Interface: editors/remote_editor.cppm
export {
  namespace telar::runtime {

    class RemoteEditor {
    private:
      using Clock = std::chrono::steady_clock;

      // One open request: what it asks, the budgets it spends, and the candidate it opened, which views
      // the request's context. The editor keeps only the buffers every request reuses.
      struct Session {
        const OpenEditor& request;
        tbc::view<const RequestContext&, tbc::lt::a> context;
        EditorKind kind;
        Clock::time_point deadline;
        unsigned entries_left = 128;
        unsigned endpoints_left = 32;
        unsigned commands_left = 128;
        tbc::view<const EditorCandidate*, tbc::lt::a> opened = nullptr;
      };

    public:
      explicit RemoteEditor(ConcurrentMemory& memory);

      void open(const OpenEditor& request, const RequestContext& context, EncodedReply<ConcurrentMemory>& reply);

    private:
      static constexpr std::size_t output_limit = 16 * 1024;

      std::string_view command(Session& session, std::span<const std::string_view> arguments);
      static bool ownedPath(const char* path, bool directory) noexcept;
      void scan(Session& session, std::string_view root, bool descend);
      void discoverNeovim(Session& session);
      void discoverVim(Session& session);
      // A candidate of the session's context, region `a`.
      tbc::view<const EditorCandidate*, tbc::lt::a> candidate(const Session& session, pid_t pid) const noexcept;
      void quote(std::string_view value, bool lisp);
      void number(std::uint32_t value);
      void vimEndpoint(Session& session, std::string_view endpoint);
      void discoverEmacs(Session& session);
      void emacsEndpoint(Session& session, std::string_view endpoint);

      ConcurrentMemory& memory_;
      CommandOutput<ConcurrentMemory> output_;
      String<ConcurrentMemory> expression_;
      String<ConcurrentMemory> path_;
      String<ConcurrentMemory> editor_;
      ProcessInspector inspector_;
    };

  }
}
