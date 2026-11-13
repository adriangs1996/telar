export module telar.runtime.platform.background_executor;

import std;

export import telar.runtime.platform.process_probe;
export import telar.runtime.suggestions.engine;
export import telar.runtime.transport.connection;
import telar.client.protocol;

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
      inline explicit SuggestionService(Memory& memory, SuggestionOptions options)
          : engine_(memory, options) {}

      inline bool available() const noexcept {
        return engine_.available();
      }

      inline void process(std::span<const Byte> payload, EncodedReply<Memory>& reply, const RequestContext& context = {}) {
        std::array<Byte, 1024> scratch;
        DecodeStorage storage{scratch};
        const auto request = Codec::decode<SuggestCommand>(payload, storage);

        engine_.suggest(request, context.prompt, reply);
      }

      inline void idle() noexcept {
        engine_.idle();
      }

      inline void stop() noexcept {
        engine_.stop();
      }

    private:
      SuggestionEngine<Memory> engine_;
    };

    template <ConcurrentAllocator Memory>
    SuggestionService(Memory& memory, SuggestionOptions options) -> SuggestionService<Memory>;

  }
}
