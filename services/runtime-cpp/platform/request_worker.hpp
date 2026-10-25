#pragma once

#include "../diagnostics/config.hpp"
#include "../diagnostics/request_queue.hpp"
#include "../history/query_order.hpp"
#include "../runtime/request_context.hpp"
#include "../runtime/request_error.hpp"
#include "../transport/encoded_reply.hpp"
#include "completion_signal.hpp"
#include "error.hpp"
#include "request_queue.hpp"
#include <condition_variable>
#include <pthread.h>
#include <variant>

namespace telar::runtime {

template <typename Service, typename = void>
struct InternalRequestType {
  using Type = std::monostate;
};

template <typename Service>
struct InternalRequestType<Service, std::void_t<typename Service::InternalRequest>> {
  using Type = typename Service::InternalRequest;
};

template <typename Service, typename Memory>
concept RequestService = ConcurrentAllocator<Memory> && requires(Service &service, std::span<const Byte> request, EncodedReply<Memory> &reply) {
  { service.process(request, reply) } -> std::same_as<void>;
};

template <ConcurrentAllocator Memory, typename Service>
  requires RequestService<Service, Memory>
class RequestWorker {
public:
  explicit RequestWorker(Memory &memory, Service &service)
      : memory_(memory),
        service_(service),
        requests_(memory),
        batch_(memory),
        completions_(memory) {
    const int error = ::pthread_create(&thread_, nullptr, &start, this);
    if (error != 0) {
      throw SystemError{"start request worker", error};
    }
  }

  ~RequestWorker() {
    {
      const std::lock_guard lock{mutex_};
      stopping_ = true;
      active_cancelled_ = true;
      cancelQueued([](const Job &) { return true; });
    }

    if constexpr (requires { service_.stop(); }) {
      service_.stop();
    }
    ready_.notify_one();
    completion_available_.notify_one();
    ::pthread_join(thread_, nullptr);
  }

  RequestWorker(const RequestWorker &) = delete;
  RequestWorker &operator=(const RequestWorker &) = delete;

  template <typename Message>
  void submit(std::uint64_t client, const Message &message, RequestContext context = {}) {
    static_assert(MessageSchema<Message>::direction == Direction::client);
    const std::lock_guard lock{mutex_};
    if constexpr (std::same_as<Message, FindPaths>) {
      for (auto *queue : {&batch_, &requests_}) {
        for (std::size_t index = 0; index < queue->size(); ++index) {
          auto &queued = (*queue)[index];
          if (!queued.cancelled && queued.client == client) {
            queued.request.resize(Codec::encodedSize(message));
            Codec::encode(message, queued.request);
            queued.request_id = message.request_id;
            return;
          }
        }
      }
    }
    if (admissionFull() || stopping_) {
      TELAR_DIAGNOSTIC(++queue_metrics_.dropped);
      if constexpr (history_queue && std::same_as<Message, ImportHistory>) {
        throw RequestError{FailureCode::resource_limit, "history import was not accepted"};
      } else {
        throw RequestError{FailureCode::resource_limit, queue_full_message};
      }
    }

    auto &job = requests_.emplace(memory_, client, message.request_id);
    try {
      job.context = context;
      if constexpr (std::same_as<Message, QueryHistory>) {
        job.history_query.emplace(message, context.persistent_client);
      }

      job.workspace_path.assign(context.workspace_path);
      job.prompt.assign(context.prompt);
      job.request.resize(Codec::encodedSize(message));
      Codec::encode(message, job.request);
    } catch (...) {
      requests_.removeLast();
      TELAR_DIAGNOSTIC(++queue_metrics_.dropped);
      throw;
    }

    TELAR_DIAGNOSTIC(queue_metrics_.high_water = std::max(queue_metrics_.high_water, queuedCount()));
    ++outstanding_;
    ready_.notify_one();
  }

  template <typename Consumer>
  void collect(Consumer &&consume) {
    signal_.drain();

    for (;;) {
      std::optional<Completion> completed;
      {
        const std::lock_guard lock{mutex_};
        if (completions_.empty()) {
          return;
        }

        completed.emplace(completions_.take());
        --outstanding_;
      }

      completion_available_.notify_one();
      consume(completed->client, completed->tag, completed->reply.payload());
    }
  }

  template <typename Event>
    requires requires { typename Service::InternalRequest; }
  void submitInternal(const Event &event) {
    if constexpr (requires { { service_.acceptsInternal(event) } noexcept -> std::same_as<bool>; }) {
      if (!service_.acceptsInternal(event)) {
        return;
      }
    }

    const std::lock_guard lock{mutex_};
    if (admissionFull() || stopping_) {
      TELAR_DIAGNOSTIC(++queue_metrics_.dropped);
      throw RequestError{FailureCode::resource_limit, queue_full_message};
    }

    auto &job = requests_.emplace(memory_, 0, 0);
    try {
      job.internal.emplace(memory_, event);
    } catch (...) {
      requests_.removeLast();
      TELAR_DIAGNOSTIC(++queue_metrics_.dropped);
      throw;
    }

    TELAR_DIAGNOSTIC(queue_metrics_.high_water = std::max(queue_metrics_.high_water, queuedCount()));
    ++outstanding_;
    ready_.notify_one();
  }

  std::uint64_t takeInternalFailures() noexcept {
    return internal_failures_.exchange(0, std::memory_order_relaxed);
  }

  void cancel(std::uint64_t client) noexcept {
    const std::lock_guard lock{mutex_};
    if (active_client_ == client) {
      active_cancelled_ = true;
    }
    cancelQueued([&](const Job &job) { return job.client == client; });
  }

  bool pending() noexcept {
    const std::lock_guard lock{mutex_};
    return outstanding_ != 0;
  }

  int descriptor() const noexcept {
    return signal_.descriptor();
  }

#if TELAR_DIAGNOSTICS
  diagnostics::RequestQueueSnapshot queueMetrics() const noexcept {
    const std::lock_guard lock{mutex_};
    auto snapshot = queue_metrics_;
    snapshot.depth = queuedCount();
    return snapshot;
  }
#endif

private:
  static constexpr bool history_queue = !std::same_as<typename InternalRequestType<Service>::Type, std::monostate>;
  static constexpr std::size_t request_capacity = history_queue ? 64 : 32;
  static constexpr std::size_t completion_capacity = history_queue ? 4 : 32;
  static constexpr const char *queue_full_message = history_queue ? "history queue is full" : "Background request queue is full";

  struct Job {
    explicit Job(Memory &memory, std::uint64_t client_id, std::uint64_t request_identity)
        : client(client_id),
          request_id(request_identity),
          request(AllocatorRef<Byte, Memory>{memory}),
          reply(memory),
          workspace_path(AllocatorRef<char, Memory>{memory}),
          prompt(AllocatorRef<char, Memory>{memory}) {}

    bool cancelled = false;
    bool superseded = false;
    std::optional<HistoryQueryOrder> history_query;

    bool durable() const noexcept {
      if (internal) {
        return true;
      }
      if (request.empty()) {
        return false;
      }

      const auto tag = static_cast<ClientTag>(request.front());
      return tag == ClientTag::report_agent_command || tag == ClientTag::import_history;
    }

    std::uint64_t client;
    std::uint64_t request_id;
    Vector<Byte, Memory> request;
    EncodedReply<Memory> reply;
    RequestContext context;
    String<Memory> workspace_path;
    String<Memory> prompt;
    std::optional<typename InternalRequestType<Service>::Type> internal;
  };

  struct Completion {
    explicit Completion(Job &&job) noexcept
        : client(job.client),
          tag(static_cast<ClientTag>(job.request.front())),
          reply(std::move(job.reply)) {}

    std::uint64_t client;
    ClientTag tag;
    EncodedReply<Memory> reply;
  };

  bool admissionFull() const noexcept {
    return history_queue ? requests_.full() : outstanding_ == request_capacity;
  }

  std::size_t queuedCount() const noexcept {
    return requests_.size() + (history_queue ? 0 : batch_.size());
  }

  template <typename Predicate>
  void cancelQueued(Predicate &&matches) noexcept {
    for (auto *queue : {&batch_, &requests_}) {
      for (std::size_t index = 0; index < queue->size(); ++index) {
        auto &job = (*queue)[index];
        if (matches(job) && !job.durable()) {
          job.cancelled = true;
        }
      }
    }
  }

  static void *start(void *context) noexcept {
    static_cast<RequestWorker *>(context)->run();
    return nullptr;
  }

  void run() noexcept {
    for (;;) {
      std::optional<Job> job;
      {
        std::unique_lock lock{mutex_};
        ready_.wait_for(lock, std::chrono::seconds{1}, [&] { return stopping_ || !batch_.empty() || !requests_.empty(); });
        if (stopping_ && batch_.empty() && requests_.empty()) {
          return;
        }

        if (batch_.empty() && requests_.empty()) {
          lock.unlock();
          if constexpr (requires { service_.idle(); }) {
            service_.idle();
          }
          continue;
        }

        if (batch_.empty()) {
          batch_.swap(requests_);
        }

        job.emplace(batch_.take());
        if (job->cancelled) {
          --outstanding_;
          continue;
        }
        job->superseded = historySuperseded(*job);
        active_client_ = job->client;
        active_cancelled_ = false;
      }

      execute(*job);
      complete(*job);
    }
  }

  void complete(Job &job) noexcept {
    std::unique_lock lock{mutex_};
    active_client_ = 0;
    const bool acknowledged_import = history_queue && !job.request.empty() && job.request.front() == static_cast<Byte>(ClientTag::import_history);
    if (job.internal || acknowledged_import) {
      --outstanding_;
      return;
    }

    completion_available_.wait(lock, [&] { return stopping_ || !completions_.full(); });
    if (stopping_) {
      --outstanding_;
      return;
    }

    completions_.emplace(std::move(job));
    lock.unlock();
    signal_.notify();
  }

  bool historySuperseded(const Job &job) const noexcept {
    if (!job.history_query || !job.history_query->replaceable) {
      return false;
    }

    // Only the current batch participates; writes and other requests preserve ordering.
    for (std::size_t offset = 0; offset < batch_.size(); ++offset) {
      const auto &newer = batch_[offset];
      if (!newer.history_query) {
        break;
      }

      if (job.client == newer.client && job.request_id != newer.request_id && job.history_query->supersededBy(*newer.history_query)) {
        return true;
      }
    }

    return false;
  }

  void execute(Job &job) noexcept {
    if constexpr (requires { service_.processInternal(*job.internal); }) {
      if (job.internal) {
        try {
          service_.processInternal(*job.internal);
        } catch (...) {
          internal_failures_.fetch_add(1, std::memory_order_relaxed);
          signal_.notify();
        }

        return;
      }
    }

    try {
      if (job.superseded) {
        job.reply.send(RequestFailed{.request_id = job.request_id, .code = FailureCode::internal, .message = "History query superseded"});
        return;
      }

      if constexpr (requires { service_.process(job.request, job.reply, job.context); }) {
        job.context.workspace_path = job.workspace_path;
        job.context.prompt = job.prompt;
        job.context.cancelled = &active_cancelled_;
        service_.process(job.request, job.reply, job.context);
      } else {
        service_.process(job.request, job.reply);
      }
    } catch (const RequestError &error) {
      job.reply.send(RequestFailed{.request_id = job.request_id,
                                   .code = error.code(),
                                   .message = std::string_view{error.what()}.substr(0, maximum_failure_message)});
    } catch (const std::bad_alloc &) {
      job.reply.send(RequestFailed{.request_id = job.request_id,
                                   .code = FailureCode::resource_limit,
                                   .message = "Background request exceeded its memory budget"});
    } catch (...) {
      job.reply.send(RequestFailed{.request_id = job.request_id,
                                   .code = FailureCode::invalid_request,
                                   .message = "Background request failed"});
    }
  }

  Memory &memory_;
  static constexpr std::size_t maximum_failure_message = 192;
  Service &service_;
  CompletionSignal signal_;
  pthread_t thread_{};
  mutable std::mutex mutex_;
  std::condition_variable ready_;
  std::condition_variable completion_available_;
  RequestQueue<Job, request_capacity, Memory> requests_;
  RequestQueue<Job, request_capacity, Memory> batch_;
  RequestQueue<Completion, completion_capacity, Memory> completions_;
  std::size_t outstanding_ = 0;
  bool stopping_ = false;
  std::uint64_t active_client_ = 0;
  std::atomic<bool> active_cancelled_{false};
  std::atomic<std::uint64_t> internal_failures_{0};
#if TELAR_DIAGNOSTICS
  diagnostics::RequestQueueSnapshot queue_metrics_;
#endif
};

}
