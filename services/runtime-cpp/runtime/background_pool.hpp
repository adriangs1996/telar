#pragma once

#include "../history/event.hpp"
#include "../history/metrics.hpp"
#include "../platform/observation_worker.hpp"
#include "../platform/request_worker.hpp"
#include "../worktrees/git_probe.hpp"

namespace telar::runtime {

template <ConcurrentAllocator Memory, typename History, typename Paths, typename Editor, typename Suggestions, typename Worktrees = WorktreeGitProbe<Memory>>
class BackgroundPool {
public:
  explicit BackgroundPool(Memory &memory, History &history, Paths &paths, Editor &editor, Suggestions &suggestions)
      : path_service_(paths),
        suggestion_service_(suggestions),
#if TELAR_DIAGNOSTICS
        history_service_(history),
#endif
        history_(memory, history),
        editor_(memory, editor),
        suggestions_(memory, suggestions),
        worktree_service_(memory),
        worktrees_(worktree_service_) {
  }

  std::array<int, 5> descriptors() const noexcept {
    return {history_.descriptor(), path_service_.descriptor(), editor_.descriptor(), suggestions_.descriptor(), worktrees_.descriptor()};
  }

  bool suggestionsAvailable() const noexcept {
    return suggestion_service_.available();
  }

  bool editorBusy() noexcept {
    return editor_.pending();
  }

  template <typename Message>
  void submit(std::uint64_t client, const Message &message, const RequestContext &context = {}) {
    if constexpr (std::same_as<Message, FindPaths>) {
      path_service_.submit(client, message);
    } else if constexpr (std::same_as<Message, OpenEditor>) {
      editor_.submit(client, message, context);
    } else if constexpr (std::same_as<Message, SuggestCommand>) {
      suggestions_.submit(client, message, context);
    } else if constexpr (std::same_as<Message, QueryHistory>) {
      try {
        history_.submit(client, message, context);
        TELAR_DIAGNOSTIC(++history_queries_);
      } catch (...) {
        TELAR_DIAGNOSTIC(++history_query_failures_);
        throw;
      }
    } else {
      history_.submit(client, message, context);
    }
  }

  template <typename Consumer>
  void collect(Consumer &&consumer) {
    history_.collect(consumer);
    path_service_.collect(consumer);
    editor_.collect(consumer);
    suggestions_.collect(consumer);
  }

  template <typename Reply>
  bool tryPaths(std::uint64_t client, const FindPaths &request, Reply &reply) {
    return path_service_.tryQuery(client, request, reply);
  }

  bool recordHistory(const HistoryEventView &event) noexcept {
    try {
      history_.submitInternal(event);
      return true;
    } catch (...) {
      history_submission_failures_.fetch_add(1, std::memory_order_relaxed);
      return false;
    }
  }

  std::uint64_t takeHistoryFailures() noexcept {
    return history_submission_failures_.exchange(0, std::memory_order_relaxed) + history_.takeInternalFailures();
  }

  bool observeWorktree(const WorktreeProbeRequest &request) {
    return worktrees_.submit(request);
  }

  template <typename Consumer>
  void collectWorktrees(Consumer &&consume) {
    worktrees_.collect(consume);
  }

  void cancel(std::uint64_t client) noexcept {
    history_.cancel(client);
    path_service_.cancel(client);
    editor_.cancel(client);
    suggestions_.cancel(client);
  }

#if TELAR_DIAGNOSTICS
  HistoryMetrics historyMetrics() const noexcept
    requires requires(const History &service) { service.historyMetrics(); }
  {
    auto snapshot = history_service_.historyMetrics();
    snapshot.queue = history_.queueMetrics();
    snapshot.query_submissions = history_queries_;
    snapshot.query_refusals = history_query_failures_;
    return snapshot;
  }
#endif

private:
  Paths &path_service_;
  Suggestions &suggestion_service_;
#if TELAR_DIAGNOSTICS
  History &history_service_;
  std::uint64_t history_queries_ = 0;
  std::uint64_t history_query_failures_ = 0;
#endif
  RequestWorker<Memory, History> history_;
  RequestWorker<Memory, Editor> editor_;
  RequestWorker<Memory, Suggestions> suggestions_;
  Worktrees worktree_service_;
  ObservationWorker<Worktrees> worktrees_;
  std::atomic<std::uint64_t> history_submission_failures_{0};
};

template <ConcurrentAllocator Memory, typename History, typename Paths, typename Editor, typename Suggestions>
BackgroundPool(Memory &memory, History &history, Paths &paths, Editor &editor, Suggestions &suggestions) -> BackgroundPool<Memory, History, Paths, Editor, Suggestions>;

}
