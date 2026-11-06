module;

#include "telar_client/serializers/telar_protocol.hpp"
#include <algorithm>
#include <array>
#include <string_view>
#include "telar_base/memory/fixed_text.hpp"
#include <chrono>
#include <cstdint>
#include <limits>
#include <optional>
#include "telar_base/text/utf8.hpp"
#include <cstring>
#include <span>
#include <sys/types.h>
#include <unistd.h>
#include <atomic>


#include <concepts>
#include "telar_base/memory/allocator.hpp"
#include <stdexcept>
#include <variant>
#include "telar_client/serializers/telar_messages.hpp"
#include <cassert>
#include <bit>
#include <exception>
#include "telar_client/codecs/telar_codec.hpp"
#include <cstddef>
#include "telar_client/serializers/telar_serializer.hpp"
#include <cerrno>
#include "telar_platform/file_descriptor.hpp"


#include "telar_platform/trace.hpp"
#include <charconv>
#include "telar_base/program_identity.hpp"
#include <limits.h>
#include <poll.h>
#include <sys/wait.h>

export module telar.runtime.runtime.background_executor;

export import telar.runtime.platform.process_probe;
export import telar.runtime.worktrees.git_probe;


export import telar.runtime.history.event;
export import telar.runtime.transport.connection;


export import telar.runtime.suggestions.engine;

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
  const std::atomic<bool> *cancelled = nullptr;
  bool persistent_client = false;
};

}
}

// Interface: runtime/background_executor.cppm
export {
namespace telar::runtime {


template <typename Executor, typename Memory>
concept BackgroundExecutor = Allocator<Memory> && HistoryEventSink<Executor> && requires(Executor &executor, std::uint64_t client, const RequestContext &context, void (*consume)(std::uint64_t, ClientTag, std::span<const Byte>)) {
  { executor.descriptors() } noexcept -> std::same_as<std::array<int, 5>>;
  { executor.collect(consume) } -> std::same_as<void>;
  { executor.cancel(client) } noexcept -> std::same_as<void>;
  { executor.suggestionsAvailable() } noexcept -> std::same_as<bool>;
  { executor.editorBusy() } noexcept -> std::same_as<bool>;
  { executor.takeHistoryFailures() } noexcept -> std::same_as<std::uint64_t>;
  { executor.submit(client, QueryHistory{}, context) } -> std::same_as<void>;
  { executor.submit(client, ImportHistory{}, context) } -> std::same_as<void>;
  { executor.submit(client, DeleteHistory{}, context) } -> std::same_as<void>;
  { executor.submit(client, PruneHistory{}, context) } -> std::same_as<void>;
  { executor.submit(client, ReadHistoryOutput{}, context) } -> std::same_as<void>;
  { executor.submit(client, HistoryStatsQuery{}, context) } -> std::same_as<void>;
  { executor.submit(client, ReportAgentCommand{}, context) } -> std::same_as<void>;
  { executor.submit(client, FindPaths{}, context) } -> std::same_as<void>;
  { executor.submit(client, OpenEditor{}, context) } -> std::same_as<void>;
  { executor.submit(client, SuggestCommand{}, context) } -> std::same_as<void>;
} && requires(Executor &executor, Connection<Memory> &reply, const WorktreeProbeRequest &request, void (*consume)(const WorktreeProbeResult &)) {
  { executor.tryPaths(std::uint64_t{}, FindPaths{}, reply) } -> std::same_as<bool>;
  { executor.observeWorktree(request) } -> std::same_as<bool>;
  { executor.collectWorktrees(consume) } -> std::same_as<void>;
};

}
}

// Interface: runtime/suggestion_service.cppm
export {
namespace telar::runtime {

template <ConcurrentAllocator Memory>
class SuggestionService {
public:
  inline explicit SuggestionService(Memory &memory, SuggestionOptions options)
      : engine_(memory, options) {}

  inline bool available() const noexcept {
    return engine_.available();
  }

  inline void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
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
SuggestionService(Memory &memory, SuggestionOptions options) -> SuggestionService<Memory>;

}
}
