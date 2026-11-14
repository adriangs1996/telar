export module telar.runtime.platform.background_executor;

import std;

export import telar.runtime.platform.process_probe;
export import telar.runtime.suggestions.engine;
export import telar.runtime.transport.connection;
import telar.wire.vocabulary;
import telar.wire.editor;

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

    template <ConcurrentAllocator Memory>
    class SuggestionService {
    public:
      explicit SuggestionService(Memory& memory, SuggestionOptions options);

      bool available() const noexcept;

      void process(std::span<const Byte> payload, EncodedReply<Memory>& reply, const RequestContext& context = {});

      void idle() noexcept;

      void stop() noexcept;

    private:
      SuggestionEngine<Memory> engine_;
    };

    template <ConcurrentAllocator Memory>
    SuggestionService(Memory& memory, SuggestionOptions options) -> SuggestionService<Memory>;

    extern template class SuggestionService<ConcurrentMemory>;

  }
}
