#pragma once

#include "../history/event.hpp"
#include "../transport/connection.hpp"
#include "request_context.hpp"
#include "telar_client/serializers/telar_protocol.hpp"
#include <concepts>

namespace telar::runtime {

struct WorktreeProbeRequest;
struct WorktreeProbeResult;

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
