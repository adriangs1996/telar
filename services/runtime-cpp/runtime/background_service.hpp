#pragma once

#include "telar_platform/trace.hpp"

#include "../history/failure_reply.hpp"
#include "../history/metrics.hpp"
#include "../history/store.hpp"
#include "request_context.hpp"
#include "telar_platform/error.hpp"
#include <variant>

#if TELAR_DIAGNOSTICS
#include "../diagnostics/file_storage.hpp"
#endif

namespace telar::runtime {

template <ConcurrentAllocator Memory>
class BackgroundService {
public:
  using InternalRequest = HistoryEvent<Memory>;

  explicit BackgroundService(Memory &memory, const char *history_path, const HistoryFilters &filters = default_history_filters)
      : history_(std::in_place_type<HistoryFilters>, filters),
#if TELAR_DIAGNOSTICS
        storage_(memory, history_path),
#endif
        decode_(AllocatorRef<Byte, Memory>{memory}) {
    decode_.resize(decode_capacity);
    try {
      history_.template emplace<HistoryStore<Memory>>(memory, history_path, filters);
    } catch (const SystemError &) {
      throw;
    } catch (const RequestError &error) {
      if (error.code() != FailureCode::internal) {
        throw;
      }
    } catch (...) {
    }

    if (!std::holds_alternative<HistoryStore<Memory>>(history_)) {
      history_.template emplace<HistoryFilters>(filters);
    }
    TELAR_DIAGNOSTIC(idle());
  }

  void process(std::span<const Byte> payload, EncodedReply<Memory> &reply, const RequestContext &context = {}) {
    TELAR_TRACE("background_service.process");
    TELAR_DIAGNOSTIC(idle());
    DecodeStorage storage{decode_};
    switch (static_cast<ClientTag>(payload.front())) {
    case ClientTag::query_history:
      execute(Codec::decode<QueryHistory>(payload, storage), reply, context);
      return;
    case ClientTag::import_history:
      execute(Codec::decode<ImportHistory>(payload, storage), reply, context);
      return;
    case ClientTag::delete_history:
      execute(Codec::decode<DeleteHistory>(payload, storage), reply, context);
      return;
    case ClientTag::prune_history:
      execute(Codec::decode<PruneHistory>(payload, storage), reply, context);
      return;
    case ClientTag::read_history_output:
      execute(Codec::decode<ReadHistoryOutput>(payload, storage), reply, context);
      return;
    case ClientTag::history_stats:
      execute(Codec::decode<HistoryStatsQuery>(payload, storage), reply, context);
      return;
    case ClientTag::report_agent_command:
      execute(Codec::decode<ReportAgentCommand>(payload, storage), reply, context);
      return;
    default:
      throw RequestError{FailureCode::invalid_request, "Unknown background request"};
    }
  }

  void processInternal(const InternalRequest &request) {
    TELAR_DIAGNOSTIC(idle());
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{&counters_.writes});
    if (auto *store = std::get_if<HistoryStore<Memory>>(&history_)) {
      try {
        store->record(request.view());
        return;
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
  }

  bool acceptsInternal(const HistoryEventView &event) const noexcept {
    if (const auto *store = std::get_if<HistoryStore<Memory>>(&history_)) {
      return store->accepts(event);
    }

    return event.kind != HistoryEventKind::command_finished || std::get<HistoryFilters>(history_).allowsPane(event.command.command, event.command.directory);
  }

#if TELAR_DIAGNOSTICS
  void idle() noexcept {
    storage_.sample(diagnostics::FileStorage<Memory>::Clock::now());
  }

  HistoryMetrics historyMetrics() const noexcept {
    auto snapshot = counters_.snapshot(std::holds_alternative<HistoryStore<Memory>>(history_));
    snapshot.sqlite_bytes = storage_.bytes();
    return snapshot;
  }
#endif

private:
  template <typename Message>
  void execute(const Message &request, EncodedReply<Memory> &reply, const RequestContext &context) {
    TELAR_DIAGNOSTIC(diagnostics::OperationTimer timing{counters_.template operation<Message>()});
    auto *store = std::get_if<HistoryStore<Memory>>(&history_);
    if (store != nullptr) {
      try {
        if constexpr (std::same_as<Message, QueryHistory>) {
          store->query(request, reply);
        } else if constexpr (std::same_as<Message, ImportHistory>) {
          store->importEntries(request, reply);
        } else if constexpr (std::same_as<Message, DeleteHistory>) {
          store->remove(request, reply);
        } else if constexpr (std::same_as<Message, PruneHistory>) {
          store->prune(request, reply);
        } else if constexpr (std::same_as<Message, ReadHistoryOutput>) {
          store->readOutput(request, reply);
        } else if constexpr (std::same_as<Message, HistoryStatsQuery>) {
          store->stats(request, reply);
        } else if constexpr (std::same_as<Message, ReportAgentCommand>) {
          store->reportAgentCommand(request, context, reply);
        }

        return;
      } catch (const RequestError &error) {
        if (error.code() != FailureCode::internal) {
          throw;
        }
      } catch (...) {
      }
    }

    TELAR_DIAGNOSTIC(timing.fail());
    replyHistoryFailure(request, reply, store != nullptr);
  }

  static constexpr std::size_t decode_capacity = 128 * 1024;
  std::variant<HistoryFilters, HistoryStore<Memory>> history_;
#if TELAR_DIAGNOSTICS
  diagnostics::FileStorage<Memory> storage_;
#endif
  Vector<Byte, Memory> decode_;
  [[no_unique_address]] HistoryCounters counters_;
};

template <ConcurrentAllocator Memory>
BackgroundService(Memory &memory, const char *history_path, const HistoryFilters &filters = default_history_filters) -> BackgroundService<Memory>;

}
