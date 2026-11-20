export module telar.runtime.suggestions.engine;

import std;
import telar.tbc;

import telar.runtime.transport.connection;
import telar.platform.process;
import telar.wire.editor;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: suggestions/engine.cppm
export {
  namespace telar::runtime {

    struct SuggestionOptions {
      std::span<const std::string_view> arguments;
      std::chrono::milliseconds timeout{30'000};
      std::chrono::milliseconds idle_timeout{300'000};
    };

    class SuggestionEngine {
    public:
      explicit SuggestionEngine(ConcurrentMemory& memory, SuggestionOptions options);

      bool available() const noexcept;
      void stop() noexcept;
      void idle() noexcept;
      void suggest(const SuggestCommand& request, std::string_view prompt, EncodedReply<ConcurrentMemory>& reply);

    private:
      using Clock = std::chrono::steady_clock;

      struct Timeout {};

      struct Rejected {};

      static std::string_view extract(std::string_view text) noexcept;
      void poll(bool writing);
      void write(std::string_view bytes);
      void nextLine();

      static constexpr std::size_t maximum_record = 64 * 1024;
      ConcurrentMemory& memory_;
      SuggestionOptions options_;
      ds::Option<PipeProcess> process_;
      ByteQueue<ConcurrentMemory> input_;
      ds::String<ConcurrentMemory> line_;
      ds::String<ConcurrentMemory> text_;
      ds::String<ConcurrentMemory> encoded_;
      Clock::time_point deadline_;
      Clock::time_point last_used_;
      std::atomic<bool> stopping_{false};
    };

  }
}

// Interface: suggestions/prompt.cppm
export {
  namespace telar::runtime {

    tbc::val_a<ds::String<ConcurrentMemory>> suggestionPrompt(tbc::mut_a<ConcurrentMemory> memory, std::string_view cwd, std::string_view screen, std::string_view request);

  }
}
