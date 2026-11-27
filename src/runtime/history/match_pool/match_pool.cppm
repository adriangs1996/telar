export module telar.runtime.history.match_pool;

import std;
import telar.tbc;
import telar.base.ds;

// The threads one large history search shares its work with. A search of more commands than one
// thread matches in a keystroke splits them in chunks; the asking thread and these helpers take
// the next chunk from one counter until none is left. The helpers are a fixed few, started on the
// first search that needs them and kept, so no search creates a thread.
export namespace telar::runtime {

  class [[tbc::shared]] HistoryMatchPool {
  public:
    static constexpr std::size_t maximum_workers = 8;

    // A pool of `workers` threads, counting the one that asks, at most maximum_workers.
    explicit HistoryMatchPool(std::size_t workers) noexcept;
    ~HistoryMatchPool();

    HistoryMatchPool(const HistoryMatchPool&) = delete;
    HistoryMatchPool& operator=(const HistoryMatchPool&) = delete;
    HistoryMatchPool(HistoryMatchPool&&) = delete;
    HistoryMatchPool& operator=(HistoryMatchPool&&) = delete;

    [[nodiscard]] std::size_t workers() const noexcept;

    // Calls work(worker, chunk) once for each chunk below `chunks`, `worker` below workers() and
    // the same for one thread throughout. Returns once every call returned. A pool whose helpers
    // cannot start runs every chunk on the asking thread.
    template <typename Work>
    [[tbc::generic]] inline void run(std::size_t chunks, Work& work) {
      const Call call = [](void* context, std::size_t worker, std::size_t chunk) {
        (*static_cast<Work*>(context))(worker, chunk);
      };

      dispatch(chunks, call, &work);
    }

  private:
    using Call = void (*)(void* context, std::size_t worker, std::size_t chunk);

    void dispatch(std::size_t chunks, Call call, void* context);
    void start() noexcept;
    void help(std::size_t worker) noexcept;
    void drain(std::size_t worker) noexcept;

    std::size_t workers_;
    std::mutex mutex_;
    std::condition_variable wake_;
    std::condition_variable finished_;
    Call call_ = nullptr;
    void* context_ = nullptr;
    std::size_t chunks_ = 0;
    std::atomic<std::size_t> next_{0};
    std::size_t busy_ = 0;
    std::uint64_t generation_ = 0;
    bool started_ = false;
    bool stopping_ = false;
    std::size_t helpers_started_ = 0;
    ds::Array<std::jthread, maximum_workers - 1> helpers_;
  };

}
