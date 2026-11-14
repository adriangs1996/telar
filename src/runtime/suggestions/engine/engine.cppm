export module telar.runtime.suggestions.engine;

import std;

export import telar.runtime.transport.connection;
export import telar.platform.process;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.platform.primitives;

// Interface: suggestions/engine.cppm
export {
  namespace telar::runtime {

    struct SuggestionOptions {
      std::span<const std::string_view> arguments;
      std::chrono::milliseconds timeout{30'000};
      std::chrono::milliseconds idle_timeout{300'000};
    };

    template <Allocator Memory>
    class SuggestionEngine {
    public:
      explicit SuggestionEngine(Memory& memory, SuggestionOptions options);

      bool available() const noexcept;
      void stop() noexcept;
      void idle() noexcept;
      void suggest(const SuggestCommand& request, std::string_view prompt, EncodedReply<Memory>& reply);

    private:
      using Clock = std::chrono::steady_clock;

      struct Timeout {};

      struct Rejected {};

      static std::string_view extract(std::string_view text) noexcept;
      void poll(bool writing);
      void write(std::string_view bytes);
      void nextLine();

      static constexpr std::size_t maximum_record = 64 * 1024;
      Memory& memory_;
      SuggestionOptions options_;
      std::optional<PipeProcess> process_;
      ByteQueue<Memory> input_;
      String<Memory> line_;
      String<Memory> text_;
      String<Memory> encoded_;
      Clock::time_point deadline_{};
      Clock::time_point last_used_{};
      std::atomic<bool> stopping_{false};
    };

    extern template class SuggestionEngine<ConcurrentMemory>;

  }
}

// Interface: suggestions/prompt.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    String<Memory> suggestionPrompt(Memory& memory, std::string_view cwd, std::string_view screen, std::string_view request);

    extern template String<ConcurrentMemory> suggestionPrompt<ConcurrentMemory>(ConcurrentMemory& memory, std::string_view cwd, std::string_view screen, std::string_view request);

  }
}
