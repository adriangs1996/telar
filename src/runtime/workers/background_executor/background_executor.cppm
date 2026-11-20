export module telar.runtime.workers.background_executor;

import std;

import telar.runtime.host.process_probe;
import telar.runtime.suggestions.engine;
import telar.runtime.transport.connection;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: runtime/request_context.cppm
export {
  namespace telar::runtime {

    struct EditorCandidate {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      ProcessIdentity process;
    };

    struct RequestContext {
      static constexpr std::size_t history_session_bytes = 16;
      static constexpr std::size_t editor_candidate_capacity = 64;

      TabLocation location{};
      ds::Array<Byte, history_session_bytes> history_session{};
      std::string_view workspace_path;
      std::string_view prompt;
      std::int64_t received_at_ms = 0;
      ds::Array<EditorCandidate, editor_candidate_capacity> editor_candidates{};
      std::size_t editor_candidate_count = 0;
      const std::atomic<bool>* cancelled = nullptr;
      bool persistent_client = false;
    };

  }
}

// Interface: runtime/suggestion_service.cppm
export {
  namespace telar::runtime {

    class SuggestionService {
    public:
      explicit SuggestionService(ConcurrentMemory& memory, SuggestionOptions options);

      bool available() const noexcept;

      void process(std::span<const Byte> payload, EncodedReply<ConcurrentMemory>& reply, const RequestContext& context = {});

      void idle() noexcept;

      void stop() noexcept;

    private:
      SuggestionEngine engine_;
    };

  }
}
