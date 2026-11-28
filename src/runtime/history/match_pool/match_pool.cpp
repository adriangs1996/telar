module telar.runtime.history.match_pool;

import std;
import telar.platform.thread;

namespace telar::runtime {

  HistoryMatchPool::HistoryMatchPool(std::size_t workers) noexcept
      : workers_(std::clamp<std::size_t>(workers, 1, maximum_workers)) {}

  HistoryMatchPool::~HistoryMatchPool() {
    {
      const std::scoped_lock lock{mutex_};

      stopping_ = true;
    }

    wake_.notify_all();
    for (auto& helper : helpers_.viewMut().first(helpers_started_)) {
      helper.join();
    }
  }

  std::size_t HistoryMatchPool::workers() const noexcept {
    return started_ ? helpers_started_ + 1 : workers_;
  }

  void HistoryMatchPool::start() noexcept {
    started_ = true;
    for (std::size_t worker = 1; worker < workers_; ++worker) {
      try {
        helpers_.atMut(worker - 1) = startThread("start history match helper", [this, worker] {
          help(worker);
        });

        ++helpers_started_;
      } catch (...) {
        // The helpers that started share the work; with none, the asking thread does it alone.
        break;
      }
    }
  }

  void HistoryMatchPool::dispatch(std::size_t chunks, Call call, void* context) {
    if (!started_) {
      start();
    }

    if (helpers_started_ == 0 || chunks < 2) {
      for (std::size_t chunk = 0; chunk < chunks; ++chunk) {
        call(context, 0, chunk);
      }

      return;
    }

    {
      const std::scoped_lock lock{mutex_};

      call_ = call;
      context_ = context;
      chunks_ = chunks;
      next_.store(0, std::memory_order_relaxed);
      busy_ = helpers_started_;
      ++generation_;
    }

    wake_.notify_all();
    drain(0);

    std::unique_lock lock{mutex_};

    finished_.wait(lock, [&] {
      return busy_ == 0;
    });

    call_ = nullptr;
    context_ = nullptr;
  }

  void HistoryMatchPool::drain(std::size_t worker) noexcept {
    for (;;) {
      const auto chunk = next_.fetch_add(1, std::memory_order_relaxed);
      if (chunk >= chunks_) {
        return;
      }

      call_(context_, worker, chunk);
    }
  }

  void HistoryMatchPool::help(std::size_t worker) noexcept {
    std::uint64_t seen = 0;

    for (;;) {
      {
        std::unique_lock lock{mutex_};

        wake_.wait(lock, [&] {
          return stopping_ || generation_ != seen;
        });

        if (stopping_) {
          return;
        }

        seen = generation_;
      }

      drain(worker);

      {
        const std::scoped_lock lock{mutex_};

        --busy_;
      }

      finished_.notify_one();
    }
  }

}
