module;
#include "tbc/annotations.hpp"
#include "telar_base/diagnostics/config.hpp"

export module telar.runtime.workers.request_worker;

import std;
import telar.tbc;

import telar.runtime.host.signals;

import telar.runtime.diagnostics.operation;
import telar.runtime.workers.background_executor;
import telar.runtime.transport.connection;

import telar.wire.vocabulary;
import telar.wire.editor;
import telar.wire.history;
import telar.wire.runtime;
import telar.base.text.json;
import telar.client;
import telar.platform.thread;
import telar.base.memory.allocators;
import telar.base.ds;

// Interface: platform/observation_worker.cppm
export {
  namespace telar::runtime {

    template <typename Service>
    concept ObservationService = requires(Service& service, const Service::Request& request) {
      { service.observe(request) } noexcept -> std::same_as<typename Service::Result>;
      { service.stop() } noexcept -> std::same_as<void>;
    };

    // Runs a service on its own thread. The worker owns the service, built in place from the arguments,
    // as a Rust thread owns what its closure moves in: the caller's thread never reaches it again. A
    // reference type as `Service` lends the worker a service its caller keeps instead.
    //
    // The request, the service and the result cross threads only under the mutex: a request is taken
    // when the worker is idle, and its result, which may view the service, is consumed before the next
    // request is accepted. That protocol is audited here, as the unsafe code behind a Rust channel is, so
    // the worker is TBC_SHARED; callers still see that it keeps what they submit.
    //
    // Kept whole: tests instantiate it with their own fake Service (descent_test's DescentProbe over a
    // GatedLineageInspector).
    template <typename Service>
      requires ObservationService<std::remove_reference_t<Service>>
    class TBC_SHARED TBC_GENERIC ObservationWorker {
      using Request = std::remove_reference_t<Service>::Request;
      using Result = std::remove_reference_t<Service>::Result;

    public:
      template <typename... Arguments>
      inline explicit ObservationWorker(std::in_place_t /*in_place*/, Arguments&&... arguments)
          : ObservationWorker(nullptr, std::in_place, std::forward<Arguments>(arguments)...) {}

      // The completion is signaled after every result, besides the worker's own descriptor.
      template <typename... Arguments>
      inline ObservationWorker(CompletionSignal* completion, std::in_place_t /*in_place*/, Arguments&&... arguments)
          : service_(std::forward<Arguments>(arguments)...),
            completion_(completion),
            thread_(startThread("Start observation worker", [this] {
              run();
            })) {}

      inline ~ObservationWorker() {
        {
          const std::scoped_lock lock{mutex_};

          stopping_ = true;
        }

        service_.stop();
        ready_.notify_one();
        thread_.join();
      }

      ObservationWorker(const ObservationWorker&) = delete;
      ObservationWorker& operator=(const ObservationWorker&) = delete;
      ObservationWorker(ObservationWorker&&) = delete;
      ObservationWorker& operator=(ObservationWorker&&) = delete;

      // The worker keeps the request, region `a`, until its result is collected.
      inline bool submit(tbc::val_a<Request> request) {
        const std::scoped_lock lock{mutex_};

        if (busy_ || stopping_) {
          return false;
        }

        request_ = std::move(request);
        busy_ = true;
        ready_.notify_one();
        return true;
      }

      template <typename Consumer>
      inline void collect(Consumer&& consume) {
        if (!result_ready_.load(std::memory_order_acquire)) {
          return;
        }

        ds::Option<Result> result;

        // The worker holds its lock only to hand a request or a result over, never while it
        // observes, so waiting for it costs as little as trying would, and the wake that saw the
        // result takes it instead of leaving it for another.
        {
          const std::scoped_lock lock{mutex_};

          result = std::move(result_);
          result_.reset();
          busy_ = false;
          result_ready_.store(false, std::memory_order_relaxed);
        }

        signal_.drain();
        std::forward<Consumer>(consume)(result.getMut());
      }

      inline int descriptor() const noexcept {
        return signal_.descriptor();
      }

      template <typename Consumer>
      inline void wait(Consumer&& consume) {
        ds::Option<Result> result;

        {
          std::unique_lock lock{mutex_};

          if (!busy_) {
            return;
          }

          completed_.wait(lock, [&] {
            return result_.hasValue();
          });

          result = std::move(result_);
          result_.reset();
          busy_ = false;
          result_ready_.store(false, std::memory_order_relaxed);
        }

        signal_.drain();
        std::forward<Consumer>(consume)(*result);
      }

    private:
      inline void run() noexcept {
        for (;;) {
          {
            std::unique_lock lock{mutex_};

            ready_.wait(lock, [&] {
              return stopping_ || request_.hasValue();
            });

            if (stopping_) {
              return;
            }

            processing_ = std::move(request_);
            request_.reset();
          }

          // A result may view the request it answers, which stays here until the next one is accepted.
          auto result = service_.observe(*processing_);

          // Published and signalled under the lock a collect takes. A collect the signal wakes finds
          // the result published, where a signal raised first left it a moment with nothing to take;
          // and one that sees the result published waits for the lock, so it finds the signal raised
          // and drains it, where a result published first left the signal up with nothing behind it.
          {
            const std::scoped_lock lock{mutex_};

            result_ = std::move(result);
            result_ready_.store(true, std::memory_order_release);
            signal_.notify();
          }

          if (completion_ != nullptr) {
            completion_->notify();
          }

          completed_.notify_one();
        }
      }

      Service service_;
      CompletionSignal* completion_;
      CompletionSignal signal_;
      std::mutex mutex_;
      std::condition_variable ready_;
      std::condition_variable completed_;
      tbc::val_a<ds::Option<Request>> request_;
      // Only the worker's thread touches the request it is answering.
      tbc::val_a<ds::Option<Request>> processing_;
      // May view the request processing_ holds, which is replaced only once the result is collected;
      // the worker never moves, as its mutex and thread do not.
      tbc::val_self<ds::Option<Result>> result_;
      bool busy_ = false;
      std::atomic<bool> result_ready_{false};
      bool stopping_ = false;
      // Last, so the thread starts once every member it reads is built.
      std::jthread thread_;
    };

  }
}

// Interface: platform/serial_queue.cppm
export {
  namespace telar::runtime {

    // One observation at a time on a worker its owner keeps. Requests that arrive while one runs wait
    // in order, without a bound, and the next one goes in as each result is collected.
    //
    // Generic over the caller's request, worker and consumer, so it stays whole here.
    template <typename Request>
    class TBC_GENERIC SerialQueue {
    public:
      inline explicit SerialQueue(ConcurrentMemory& memory)
          : waiting_(memory) {}

      // Starts `request` on `worker` when it is idle, else queues it behind the waiting ones.
      template <typename Worker>
      inline void request(Worker& worker, const Request& request) {
        if (!busy_ && worker.submit(request)) {
          busy_ = true;
          return;
        }

        waiting_.push(request);
      }

      inline std::span<const Request> waiting() const noexcept {
        return waiting_.view();
      }

      template <typename Predicate>
      inline void dropWaiting(const Predicate& matches) {
        waiting_.retain([&](const Request& entry) {
          return !matches(entry);
        });
      }

      template <typename Worker, typename Consumer>
      inline void collect(Worker& worker, Consumer&& consume) {
        worker.collect([&](const auto& result) {
          busy_ = false;
          std::forward<Consumer>(consume)(result);
        });

        while (!busy_ && !waiting_.empty()) {
          const auto next = waiting_.remove(0);

          busy_ = worker.submit(next);
        }
      }

    private:
      ds::Vec<Request, ConcurrentMemory> waiting_;
      bool busy_ = false;
    };

  }
}

// Interface: platform/request_queue.cppm
export {
  namespace telar::runtime {

    // Generic over the caller's value (RequestWorker's jobs and completions), so it stays whole here.
    template <typename Value, std::size_t Capacity, ConcurrentAllocator Memory>
    class TBC_GENERIC RequestQueue {
      static_assert(Capacity != 0 && std::is_nothrow_move_constructible_v<Value>);

    public:
      inline explicit RequestQueue(Memory& memory)
          : slots_(memory) {
        slots_.resize(Capacity);
      }

      [[nodiscard]] inline bool empty() const noexcept {
        return count_ == 0;
      }

      [[nodiscard]] inline bool full() const noexcept {
        return count_ == Capacity;
      }

      [[nodiscard]] inline std::size_t size() const noexcept {
        return count_;
      }

      inline Value& atMut(std::size_t offset) noexcept {
        TELAR_ASSERT(offset < count_);
        return slots_.atMut((head_ + offset) % Capacity).getMut();
      }

      inline const Value& operator[](std::size_t offset) const noexcept {
        TELAR_ASSERT(offset < count_);
        return *slots_[(head_ + offset) % Capacity];
      }

      template <typename... Arguments>
      inline Value& emplace(Arguments&&... arguments) {
        TELAR_ASSERT(!full());
        auto& value = slots_.atMut((head_ + count_) % Capacity).emplace(std::forward<Arguments>(arguments)...);

        ++count_;
        return value;
      }

      inline void removeLast() noexcept {
        TELAR_ASSERT(!empty());
        --count_;
        slots_.atMut((head_ + count_) % Capacity).reset();
      }

      inline Value take() noexcept {
        TELAR_ASSERT(!empty());
        auto value = std::move(slots_.atMut(head_).getMut());

        slots_.atMut(head_).reset();
        head_ = (head_ + 1) % Capacity;
        --count_;
        return value;
      }

      inline void swap(RequestQueue& other) noexcept {
        TELAR_ASSERT(&slots_.memory() == &other.slots_.memory());
        std::swap(slots_, other.slots_);
        std::swap(head_, other.head_);
        std::swap(count_, other.count_);
      }

    private:
      ds::Vec<ds::Option<Value>, Memory> slots_;
      std::size_t head_ = 0;
      std::size_t count_ = 0;
    };

  }
}

// Interface: history/query_order.cppm
export {
  namespace telar::runtime {

    struct HistoryQueryOrder {
      explicit HistoryQueryOrder(const QueryHistory& query, bool persistent_client) noexcept;

      [[nodiscard]] bool supersededBy(const HistoryQueryOrder& newer) const noexcept;

      bool replaceable;
      bool distinct;
    };

  }
}

// Interface: platform/request_worker.cppm
export {
  namespace telar::runtime {

    template <typename Service, typename = void>
    struct InternalRequestType {
      using Type = std::monostate;
    };

    template <typename Service>
    struct InternalRequestType<Service, std::void_t<typename Service::InternalRequest>> {
      using Type = Service::InternalRequest;
    };

    template <typename Service, typename Memory>
    concept RequestService = ConcurrentAllocator<Memory> && requires(Service& service, std::span<const Byte> request, EncodedReply<Memory>& reply) {
      { service.process(request, reply) } -> std::same_as<void>;
    };

    // Kept whole: tests instantiate it with their own fake Service (history_capacity_test's
    // ControlledHistoryService).
    template <ConcurrentAllocator Memory, typename Service>
      requires RequestService<Service, Memory>
    class TBC_GENERIC RequestWorker {
    public:
      inline explicit RequestWorker(Memory& memory, Service& service)
          : memory_(memory),
            service_(service),
            requests_(memory),
            batch_(memory),
            completions_(memory),
            thread_(startThread("start request worker", [this] {
              run();
            })) {}

      inline ~RequestWorker() {
        {
          const std::scoped_lock lock{mutex_};

          stopping_ = true;
          active_cancelled_ = true;
          cancelQueued([](const Job&) {
            return true;
          });
        }

        if constexpr (requires { service_.stop(); }) {
          service_.stop();
        }

        ready_.notify_one();
        completion_available_.notify_one();
        thread_.join();
      }

      RequestWorker(const RequestWorker&) = delete;
      RequestWorker& operator=(const RequestWorker&) = delete;
      RequestWorker(RequestWorker&&) = delete;
      RequestWorker& operator=(RequestWorker&&) = delete;

      template <typename Message>
      inline void submit(std::uint64_t client, const Message& message, RequestContext context = {}) {
        static_assert(MessageSchema<Message>::direction == Direction::client);
        const std::scoped_lock lock{mutex_};

        if constexpr (std::same_as<Message, FindPaths>) {
          if (replaceQueued(client, message)) {
            return;
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

        auto& job = requests_.emplace(memory_, JobOrigin{.client = client, .request_id = message.request_id});

        try {
          // The job owns its texts; the views the caller's context carries are rebuilt from them when it runs.
          job.context = RequestContext{
              .location = context.location,
              .history_session = context.history_session,
              .received_at_ms = context.received_at_ms,
              .editor_candidates = context.editor_candidates,
              .editor_candidate_count = context.editor_candidate_count,
              .persistent_client = context.persistent_client,
          };

          if constexpr (std::same_as<Message, QueryHistory>) {
            job.history_query.emplace(message, context.persistent_client);
          }

          job.workspace_path.assign(context.workspace_path);
          job.prompt.assign(context.prompt);
          job.request.resize(Codec::encodedSize(message));
          Codec::encode(message, job.request.viewMut());
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
      inline void collect(const Consumer& consume) {
        signal_.drain();

        for (;;) {
          ds::Option<Completion> completed;

          {
            const std::scoped_lock lock{mutex_};

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
      inline void submitInternal(const Event& event) {
        if constexpr (requires { { service_.acceptsInternal(event) } noexcept -> std::same_as<bool>; }) {
          if (!service_.acceptsInternal(event)) {
            return;
          }
        }

        const std::scoped_lock lock{mutex_};

        if (admissionFull() || stopping_) {
          TELAR_DIAGNOSTIC(++queue_metrics_.dropped);
          throw RequestError{FailureCode::resource_limit, queue_full_message};
        }

        auto& job = requests_.emplace(memory_, JobOrigin{});

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

      inline std::uint64_t takeInternalFailures() noexcept {
        return internal_failures_.exchange(0, std::memory_order_relaxed);
      }

      inline void cancel(std::uint64_t client) noexcept {
        const std::scoped_lock lock{mutex_};

        if (active_client_ == client) {
          active_cancelled_ = true;
        }

        cancelQueued([&](const Job& job) {
          return job.client == client;
        });
      }

      inline bool pending() noexcept {
        const std::scoped_lock lock{mutex_};

        return outstanding_ != 0;
      }

      inline int descriptor() const noexcept {
        return signal_.descriptor();
      }

#if TELAR_DIAGNOSTICS
      inline diagnostics::RequestQueueSnapshot queueMetrics() const noexcept {
        const std::scoped_lock lock{mutex_};
        auto snapshot = queue_metrics_;

        snapshot.depth = queuedCount();
        return snapshot;
      }
#endif

    private:
      static constexpr bool history_queue = !std::same_as<typename InternalRequestType<Service>::Type, std::monostate>;
      static constexpr std::size_t request_capacity = history_queue ? 64 : 32;
      static constexpr std::size_t completion_capacity = history_queue ? 4 : 32;
      static constexpr const char* queue_full_message = history_queue ? "history queue is full" : "Background request queue is full";

      // The client a job answers and the request it carries; zero for the worker's own jobs.
      struct JobOrigin {
        std::uint64_t client = 0;
        std::uint64_t request_id = 0;
      };

      // What the worker does once it wakes.
      enum class Step : std::uint8_t {
        run,
        idle,
        skip,
        stop,
      };

      struct Job {
        inline explicit Job(Memory& memory, JobOrigin origin)
            : client(origin.client),
              request_id(origin.request_id),
              request(memory),
              reply(memory),
              workspace_path(memory),
              prompt(memory) {}

        bool cancelled = false;
        bool superseded = false;
        ds::Option<HistoryQueryOrder> history_query;

        [[nodiscard]] inline bool durable() const noexcept {
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
        ds::Vec<Byte, Memory> request;
        EncodedReply<Memory> reply;
        RequestContext context;
        ds::String<Memory> workspace_path;
        ds::String<Memory> prompt;
        ds::Option<typename InternalRequestType<Service>::Type> internal;
      };

      struct Completion {
        // Takes the job's reply.
        inline explicit Completion(Job& job) noexcept
            : client(job.client),
              tag(static_cast<ClientTag>(job.request.front())),
              reply(std::move(job.reply)) {}

        std::uint64_t client;
        ClientTag tag;
        EncodedReply<Memory> reply;
      };

      inline bool admissionFull() const noexcept {
        return history_queue ? requests_.full() : outstanding_ == request_capacity;
      }

      inline std::size_t queuedCount() const noexcept {
        return requests_.size() + (history_queue ? 0 : batch_.size());
      }

      // A client's newer path query takes the place of the one it still has queued.
      inline bool replaceQueued(std::uint64_t client, const FindPaths& message) {
        for (auto* queue : {&batch_, &requests_}) {
          for (std::size_t index = 0; index < queue->size(); ++index) {
            auto& queued = (*queue)[index];
            if (!queued.cancelled && queued.client == client) {
              queued.request.resize(Codec::encodedSize(message));
              Codec::encode(message, queued.request);
              queued.request_id = message.request_id;
              return true;
            }
          }
        }

        return false;
      }

      template <typename Predicate>
      inline void cancelQueued(const Predicate& matches) noexcept {
        for (auto* queue : {&batch_, &requests_}) {
          for (std::size_t index = 0; index < queue->size(); ++index) {
            auto& job = queue->atMut(index);
            if (matches(job) && !job.durable()) {
              job.cancelled = true;
            }
          }
        }
      }

      inline void run() noexcept {
        for (;;) {
          ds::Option<Job> job;
          const auto step = take(job);
          if (step == Step::stop) {
            return;
          }

          if (step == Step::idle) {
            if constexpr (requires { service_.idle(); }) {
              service_.idle();
            }

            continue;
          }

          if (step == Step::run) {
            execute(job.getMut());
            complete(job.getMut());
          }
        }
      }

      // Waits up to a second for a job and moves the next one into `job`, under the lock.
      inline Step take(ds::Option<Job>& job) noexcept {
        std::unique_lock lock{mutex_};

        ready_.wait_for(lock, std::chrono::seconds{1}, [&] {
          return stopping_ || !batch_.empty() || !requests_.empty();
        });

        if (stopping_ && batch_.empty() && requests_.empty()) {
          return Step::stop;
        }

        if (batch_.empty() && requests_.empty()) {
          return Step::idle;
        }

        if (batch_.empty()) {
          batch_.swap(requests_);
        }

        job.emplace(batch_.take());
        if (job->cancelled) {
          --outstanding_;
          return Step::skip;
        }

        job.getMut().superseded = historySuperseded(*job);
        active_client_ = job->client;
        active_cancelled_ = false;
        return Step::run;
      }

      inline void complete(Job& job) noexcept {
        std::unique_lock lock{mutex_};

        active_client_ = 0;
        const bool acknowledged_import = history_queue && !job.request.empty() && job.request.front() == static_cast<Byte>(ClientTag::import_history);
        if (job.internal || acknowledged_import) {
          --outstanding_;
          return;
        }

        completion_available_.wait(lock, [&] {
          return stopping_ || !completions_.full();
        });

        if (stopping_) {
          --outstanding_;
          return;
        }

        completions_.emplace(job);
        lock.unlock();
        signal_.notify();
      }

      inline bool historySuperseded(const Job& job) const noexcept {
        if (!job.history_query || !job.history_query->replaceable) {
          return false;
        }

        // Only the current batch participates; writes and other requests preserve ordering.
        for (std::size_t offset = 0; offset < batch_.size(); ++offset) {
          const auto& newer = batch_[offset];
          if (!newer.history_query) {
            break;
          }

          if (job.client == newer.client && job.request_id != newer.request_id && job.history_query->supersededBy(*newer.history_query)) {
            return true;
          }
        }

        return false;
      }

      inline void execute(Job& job) noexcept {
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
            auto context = job.context;

            context.workspace_path = job.workspace_path;
            context.prompt = job.prompt;
            context.cancelled = &active_cancelled_;
            service_.process(job.request, job.reply, context);
          } else {
            service_.process(job.request, job.reply);
          }
        } catch (const RequestError& error) {
          job.reply.send(RequestFailed{.request_id = job.request_id, .code = error.code(), .message = std::string_view{error.what()}.substr(0, maximum_failure_message)});
        } catch (const JsonError& error) {
          job.reply.send(RequestFailed{.request_id = job.request_id, .code = FailureCode::invalid_request, .message = error.what()});
        } catch (const std::bad_alloc&) {
          job.reply.send(RequestFailed{.request_id = job.request_id, .code = FailureCode::resource_limit, .message = "Background request exceeded its memory budget"});
        } catch (...) {
          job.reply.send(RequestFailed{.request_id = job.request_id, .code = FailureCode::invalid_request, .message = "Background request failed"});
        }
      }

      Memory& memory_;
      static constexpr std::size_t maximum_failure_message = 192;
      Service& service_;
      CompletionSignal signal_;
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
      // Last, so the thread starts once every member it reads is built.
      std::jthread thread_;
    };

  }
}
