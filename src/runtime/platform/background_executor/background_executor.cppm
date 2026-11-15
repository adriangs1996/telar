export module telar.runtime.platform.background_executor;

import std;

import telar.runtime.platform.process_probe;
import telar.runtime.suggestions.engine;
import telar.runtime.transport.connection;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.base.memory.allocators;

// Interface: runtime/request_context.cppm
export {
  namespace telar::runtime {

    struct EditorCandidate {
      std::uint64_t pane = 0;
      std::uint64_t generation = 0;
      ProcessIdentity process;
    };

    struct RequestContext {
      TabLocation location{};
      std::array<Byte, 16> history_session{};
      std::string_view workspace_path{};
      std::string_view prompt{};
      std::int64_t received_at_ms = 0;
      std::array<EditorCandidate, 64> editor_candidates{};
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
