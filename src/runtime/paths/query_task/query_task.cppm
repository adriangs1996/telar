module;
#include "tbc/hot_path.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.paths.query_task;

import std;
import telar.tbc;

export import telar.runtime.transport.connection;
import telar.base.diagnostics;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.sys.posix;

// Interface: paths/fuzzy_match.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class FuzzyMatch {
    public:
      explicit FuzzyMatch(Memory& memory);

      std::optional<std::int32_t> score(std::string_view path, std::string_view query, std::span<std::uint16_t> positions = {});

    private:
      static char lower(char value) noexcept;

      static std::int32_t plus(std::int32_t value, int increment) noexcept;

      static int bonus(char previous, char value) noexcept;

      std::span<std::int32_t> row(std::size_t index, bool best) noexcept;

      static constexpr std::size_t maximum_path = 1024;
      static constexpr std::size_t maximum_needle = 64;
      static constexpr int consecutive_score = 1000;
      static constexpr int leading_gap = -5;
      static constexpr int inner_gap = -10;
      static constexpr int trailing_gap = -5;
      static constexpr auto minimum_score = std::numeric_limits<std::int32_t>::min();
      Vector<std::int32_t, Memory> matrix_;
    };

    extern template class FuzzyMatch<SystemAllocator>;
    extern template class FuzzyMatch<ConcurrentMemory>;

  }
}

// Interface: paths/index_storage.cppm
export {
  namespace telar::runtime {

    struct IndexedPath {
      std::uint32_t offset;
      std::uint16_t length;
      PathKind kind;
    };

    enum class PathBuildFailure {
      none,
      unreadable,
      allocation,
    };

    template <Allocator Memory>
    class PathIndexStorage {
    public:
      static constexpr std::size_t maximum_entries = 512 * 1024;
      static constexpr std::size_t maximum_bytes = 32 * 1024 * 1024;

      explicit PathIndexStorage(Memory& memory);

      ~PathIndexStorage();

      PathIndexStorage(const PathIndexStorage&) = delete;
      PathIndexStorage& operator=(const PathIndexStorage&) = delete;

      void reset() noexcept;

      bool append(std::string_view relative, PathKind kind) noexcept;

      const IndexedPath& entry(std::size_t index) const noexcept;

      std::string_view path(const IndexedPath& entry) const noexcept;

      void finish() noexcept;

      // One builder appends to fixed storage; readers access only the released prefix.
      std::atomic<std::size_t> published{0};
      std::atomic<bool> complete{false};
      std::atomic<bool> cancelled{false};
      std::size_t count = 0;
      std::size_t bytes_used = 0;
      bool truncated = false;
      PathBuildFailure failure = PathBuildFailure::none;

    private:
      static constexpr std::size_t entry_bytes = maximum_entries * sizeof(IndexedPath);
      static constexpr std::size_t publication_batch = 1024;
      Memory& memory_;
      char* bytes_;
      IndexedPath* entries_;
    };

    extern template class PathIndexStorage<SystemAllocator>;
    extern template class PathIndexStorage<ConcurrentMemory>;

  }
}

// Interface: paths/index_builder.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class PathIndexBuilder {
    public:
      // Builds into the storage it is given; the directories it tracks view it, region `a`.
      explicit PathIndexBuilder(tbc::view<Memory&, tbc::lt::a> memory, tbc::view<PathIndexStorage<Memory>&, tbc::lt::a> storage);

      void build(const char* root) noexcept;

    private:
      using Directories = std::unordered_set<std::string_view, std::hash<std::string_view>, std::equal_to<std::string_view>, AllocatorRef<std::string_view, Memory>>;

      static bool acceptable(std::string_view relative) noexcept;

      static bool insideGit(std::string_view path) noexcept;

      bool appendTracked(std::string_view relative, tbc::view<Directories&, tbc::lt::a> directories);

      void tracked(const char* root);

      static FileDescriptor openRelative(int root, std::string_view relative);

      void walk(int root);

      void list(int directory, std::string_view prefix);

      tbc::view<Memory&, tbc::lt::a> memory_;
      tbc::view<PathIndexStorage<Memory>&, tbc::lt::a> storage_;
    };

    extern template class PathIndexBuilder<ConcurrentMemory>;

  }
}

// Interface: paths/path_index.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class PathIndex {
    public:
      explicit PathIndex(Memory& memory);

      void stop() noexcept;

      std::string_view root() const noexcept;

      void reset(std::string_view root);

      void build() noexcept;

      bool complete() const noexcept;

      bool canQueryInline(const FindPaths& request) const noexcept;

      // Generic over the caller's reply, as queryPublished, which it calls.
      template <typename Reply>
      TBC_HOT_PATH inline void query(const FindPaths& request, Reply& reply) {
        if (!complete() || root_ != request.root || request.refresh) {
          reset(request.root);
          build();
        }

        queryPublished(request, reply);
      }

      // The reply is the caller's (an encoded reply or a client connection) and it views the ranking
      // this body builds on its stack, so the whole query stays here.
      template <typename Reply>
      TBC_HOT_PATH inline bool queryPublished(const FindPaths& request, Reply& reply) {
        TELAR_TRACE("paths.query");
        const bool complete = this->complete();
        const auto published = storage_.published.load(std::memory_order_acquire);

        if (complete && storage_.failure == PathBuildFailure::unreadable) {
          throw RequestError{FailureCode::permission_denied, "Path root is not readable"};
        }

        if (complete && storage_.failure == PathBuildFailure::allocation) {
          throw std::bad_alloc{};
        }

        std::array<Candidate, 50> ranked;
        std::size_t count = 0;

        for (std::size_t index = 0; index < published; ++index) {
          const auto& entry = storage_.entry(index);
          if ((request.kind == PathKindFilter::files && entry.kind != PathKind::file) || (request.kind == PathKindFilter::directories && entry.kind != PathKind::directory)) {
            continue;
          }

          const auto score = matcher_.score(path(entry), request.query);
          if (!score) {
            continue;
          }

          const Candidate candidate{index, *score};
          std::size_t position = count;

          while (position != 0 && better(candidate, ranked[position - 1], request.query.empty())) {
            --position;
          }

          if (position >= request.limit) {
            continue;
          }

          const auto kept = std::min<std::size_t>(count, request.limit - 1);

          for (std::size_t moved = kept; moved > position; --moved) {
            ranked[moved] = ranked[moved - 1];
          }

          ranked[position] = candidate;
          count = kept + 1;
        }

        std::array<PathMatch, 50> matches;
        std::array<std::array<std::uint16_t, 64>, 50> positions;

        for (std::size_t index = 0; index < count; ++index) {
          const auto& entry = storage_.entry(ranked[index].entry);
          const auto value = path(entry);

          matcher_.score(value, request.query, positions[index]);
          matches[index] = {value, entry.kind, std::span{positions[index]}.first(request.query.size())};
        }

        reply.send(PathResults{request.request_id, root_, static_cast<std::uint32_t>(published), complete, complete && storage_.truncated, std::span{matches}.first(count)});
        return complete;
      }

    private:
      struct Candidate {
        std::size_t entry;
        std::int32_t score;
      };

      std::string_view path(const IndexedPath& entry) const noexcept;

      static std::size_t depth(std::string_view path) noexcept;

      bool better(const Candidate& left, const Candidate& right, bool browse) const noexcept;

      String<Memory> root_;
      PathIndexStorage<Memory> storage_;
      // Builds into storage_.
      tbc::view<PathIndexBuilder<Memory>, tbc::lt::self> builder_;
      FuzzyMatch<Memory> matcher_;
    };

    extern template class PathIndex<ConcurrentMemory>;

  }
}

// Interface: paths/query_task.cppm
export {
  namespace telar::runtime {

    template <typename Index, typename Memory>
    concept PathSearchIndex = Allocator<Memory> && requires(Index& index, const FindPaths& request, EncodedReply<Memory>& reply) {
      { index.root() } noexcept -> std::same_as<std::string_view>;
      { index.reset(request.root) } -> std::same_as<void>;
      { index.build() } noexcept -> std::same_as<void>;
      { index.stop() } noexcept -> std::same_as<void>;
      { index.complete() } noexcept -> std::same_as<bool>;
      { index.canQueryInline(request) } noexcept -> std::same_as<bool>;
      { index.queryPublished(request, reply) } -> std::same_as<bool>;
    };

    struct OwnedPathQuery {
      void assign(const FindPaths& request);

      FindPaths view() const noexcept;

      std::uint64_t request_id = 0;
      FixedText<4096> root;
      FixedText<64> query;
      PathKindFilter kind = PathKindFilter::any;
      std::uint16_t limit = 50;
    };

    // Kept whole: path_service_test instantiates it with its own GatedPathMemory and GatedPathIndex.
    template <Allocator Memory, typename Index = PathIndex<Memory>>
      requires PathSearchIndex<Index, Memory>
    class TBC_HOT_PATH PathQueryTask {
    public:
      using Request = OwnedPathQuery;

      struct Result {
        bool complete;
        std::span<const Byte> payload;
      };

      inline explicit PathQueryTask(Memory& memory, Index& index)
          : index_(index),
            reply_(memory) {}

      inline void stop() noexcept {
        index_.stop();
      }

      inline Result observe(const Request& request) noexcept {
        try {
          const bool complete = index_.queryPublished(request.view(), reply_);

          return {complete, reply_.payload()};
        } catch (const RequestError& error) {
          reply_.send(RequestFailed{.request_id = request.request_id, .code = error.code(), .message = error.what()});
        } catch (...) {
          reply_.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::resource_limit, .message = "Path query memory is unavailable"});
        }

        return {true, reply_.payload()};
      }

    private:
      Index& index_;
      EncodedReply<Memory> reply_;
    };

    // Kept whole: path_service_test instantiates it with its own GatedPathIndex.
    template <typename Index>
    class TBC_HOT_PATH PathBuildTask {
    public:
      using Request = bool;
      using Result = bool;

      inline explicit PathBuildTask(Index& index)
          : index_(index) {}

      inline void stop() noexcept {
        index_.stop();
      }

      inline bool observe(bool) noexcept {
        index_.build();
        return true;
      }

    private:
      Index& index_;
    };

  }
}
