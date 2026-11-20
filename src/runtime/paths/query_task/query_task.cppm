module;
#include "tbc/annotations.hpp"
#include "telar_platform/trace_macro.hpp"

export module telar.runtime.paths.query_task;

import std;
import telar.tbc;

import telar.runtime.transport.connection;
import telar.wire.vocabulary;
import telar.wire.editor;
import telar.wire.runtime;
import telar.platform.primitives;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.base.ds;

// Interface: paths/fuzzy_match.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class FuzzyMatch {
    public:
      explicit FuzzyMatch(Memory& memory);

      ds::Option<std::int32_t> score(std::string_view path, std::string_view query, std::span<std::uint16_t> positions = {});

    private:
      static char lower(char value) noexcept;

      static std::int32_t plus(std::int32_t value, int increment) noexcept;

      static constexpr std::size_t maximum_path = 1024;
      static constexpr std::size_t maximum_needle = 64;

      static int bonus(char previous, char value) noexcept;

      // Where each of the query's characters first matches in order, written to `positions` too when
      // it is not empty; false when the path does not hold the query.
      static bool firstMatches(std::string_view path, std::string_view query, ds::Array<std::uint16_t, maximum_needle>& matches, std::span<std::uint16_t> positions) noexcept;

      // Fills the score rows of every query prefix, both of them per character when `retain_rows`
      // keeps them for tracing, else two alternating.
      void align(std::string_view path, std::string_view query, const ds::Array<std::uint16_t, maximum_needle>& first_matches, const ds::Array<std::int32_t, maximum_path>& bonuses, bool retain_rows) noexcept;

      // Walks the retained rows back from the path's end to where the best alignment places each character.
      void trace(std::size_t path_size, std::span<const std::uint16_t> first_matches, std::span<std::uint16_t> positions) noexcept;

      std::span<std::int32_t> row(std::size_t index, bool best) noexcept;

      static constexpr int consecutive_score = 1000;
      static constexpr int leading_gap = -5;
      static constexpr int inner_gap = -10;
      static constexpr int trailing_gap = -5;
      static constexpr auto minimum_score = std::numeric_limits<std::int32_t>::min();
      ds::Vec<std::int32_t, Memory> matrix_;
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

    enum class PathBuildFailure : std::uint8_t {
      none,
      unreadable,
      allocation,
    };

    // Paths in storage reserved whole when it is built, which never moves: one builder appends while
    // readers read the prefix it published, and a path handed out stays where it is until the index is
    // reset for another root, between queries, which send their answers before then.
    template <Allocator Memory>
    class TBC_SHARED PathIndexStorage {
    public:
      static constexpr std::size_t maximum_entries = std::size_t{512} * 1024;
      static constexpr std::size_t maximum_bytes = std::size_t{32} * 1024 * 1024;

      explicit PathIndexStorage(Memory& memory);

      ~PathIndexStorage();

      PathIndexStorage(const PathIndexStorage&) = delete;
      PathIndexStorage& operator=(const PathIndexStorage&) = delete;
      PathIndexStorage(PathIndexStorage&&) = delete;
      PathIndexStorage& operator=(PathIndexStorage&&) = delete;

      void reset() noexcept;

      bool append(std::string_view relative, PathKind kind) noexcept;

      const IndexedPath& entry(std::size_t index) const noexcept;

      std::string_view path(const IndexedPath& entry) const noexcept;

      void finish() noexcept;

      // One builder appends to fixed storage; readers access only the released prefix. Public beside
      // the private storage: the git reader borrows `cancelled` alone while the builder appends, as
      // Rust borrows one field of a struct, where an accessor would lend the whole storage.
      // NOLINTBEGIN(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)
      std::atomic<std::size_t> published{0};
      std::atomic<bool> complete{false};
      std::atomic<bool> cancelled{false};
      std::size_t count = 0;
      std::size_t bytes_used = 0;
      bool truncated = false;
      PathBuildFailure failure = PathBuildFailure::none;
      // NOLINTEND(cppcoreguidelines-non-private-member-variables-in-classes,misc-non-private-member-variables-in-classes)

    private:
      static constexpr std::size_t entry_bytes = maximum_entries * sizeof(IndexedPath);
      static constexpr std::size_t publication_batch = 1024;
      Memory& memory_;
      std::span<char> bytes_;
      std::span<IndexedPath> entries_;
    };

    extern template class PathIndexStorage<SystemAllocator>;
    extern template class PathIndexStorage<ConcurrentMemory>;

  }
}

// Interface: paths/index_builder.cppm
export {
  namespace telar::runtime {

    class PathIndexBuilder {
    public:
      // Builds into the storage it is given; the directories it tracks view it, region `a`.
      explicit PathIndexBuilder(tbc::mut_a<ConcurrentMemory> memory, tbc::mut_a<PathIndexStorage<ConcurrentMemory>> storage);

      void build(const char* root) noexcept;

    private:
      // A set of the directories appended, viewing the storage: each maps to nothing.
      using Directories = ds::Map<std::string_view, bool, ConcurrentMemory>;

      static bool acceptable(std::string_view relative) noexcept;

      static bool insideGit(std::string_view path) noexcept;

      bool appendTracked(std::string_view relative, tbc::mut_a<Directories> directories);

      void tracked(const char* root);

      static FileDescriptor openRelative(int root, std::string_view relative);

      void walk(int root);

      void list(int directory, std::string_view prefix);

      tbc::mut_a<ConcurrentMemory> memory_;
      tbc::mut_a<PathIndexStorage<ConcurrentMemory>> storage_;
    };

  }
}

// Interface: paths/path_index.cppm
export {
  namespace telar::runtime {

    // A path query's text, and the matches it answers with at most.
    inline constexpr std::size_t path_query_bytes = 64;
    inline constexpr std::size_t path_result_capacity = 50;

    class PathIndex {
    public:
      explicit PathIndex(ConcurrentMemory& memory);

      void stop() noexcept;

      std::string_view root() const noexcept;

      void reset(std::string_view root);

      void build() noexcept;

      bool complete() const noexcept;

      bool canQueryInline(const FindPaths& request) const noexcept;

      // Generic over the caller's reply, as queryPublished, which it calls.
      template <typename Reply>
      TBC_GENERIC inline void query(const FindPaths& request, Reply& reply) {
        if (!complete() || root_ != request.root || request.refresh) {
          reset(request.root);
          build();
        }

        queryPublished(request, reply);
      }

      // The reply is the caller's (an encoded reply or a client connection) and it views the ranking
      // this body builds on its stack, so the whole query stays here.
      template <typename Reply>
      TBC_GENERIC inline bool queryPublished(const FindPaths& request, Reply& reply) {
        TELAR_TRACE("paths.query");
        const bool complete = this->complete();
        const auto published = storage_.published.load(std::memory_order_acquire);

        if (complete && storage_.failure == PathBuildFailure::unreadable) {
          throw RequestError{FailureCode::permission_denied, "Path root is not readable"};
        }

        if (complete && storage_.failure == PathBuildFailure::allocation) {
          throw std::bad_alloc{};
        }

        ds::Array<Candidate, path_result_capacity> ranked; // NOLINT(cppcoreguidelines-pro-type-member-init): built on every query, and only the first `count` candidates are written and read
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

          const Candidate candidate{.entry = index, .score = *score};
          std::size_t position = count;

          while (position != 0 && better(candidate, ranked[position - 1], request.query.empty())) {
            --position;
          }

          if (position >= request.limit) {
            continue;
          }

          const auto kept = std::min<std::size_t>(count, request.limit - 1);

          for (std::size_t moved = kept; moved > position; --moved) {
            ranked.atMut(moved) = ranked[moved - 1];
          }

          ranked.atMut(position) = candidate;
          count = kept + 1;
        }

        ds::Array<PathMatch, path_result_capacity> matches;
        ds::Array<ds::Array<std::uint16_t, path_query_bytes>, path_result_capacity> positions; // NOLINT(cppcoreguidelines-pro-type-member-init): built on every query, and only the positions scoring writes are read

        // Every row's positions are written before any match views them, as Rust fills the rows with
        // one mutable borrow and then lends them out shared.
        for (std::size_t index = 0; index < count; ++index) {
          matcher_.score(path(storage_.entry(ranked[index].entry)), request.query, positions.atMut(index).viewMut());
        }

        for (std::size_t index = 0; index < count; ++index) {
          const auto& entry = storage_.entry(ranked[index].entry);

          matches.atMut(index) = {.path = path(entry), .kind = entry.kind, .positions = std::span{positions[index]}.first(request.query.size())};
        }

        reply.send(PathResults{.request_id = request.request_id, .root = root_, .scanned = static_cast<std::uint32_t>(published), .complete = complete, .truncated = complete && storage_.truncated, .matches = std::span{matches}.first(count)});
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

      ds::String<ConcurrentMemory> root_;
      PathIndexStorage<ConcurrentMemory> storage_;
      // Builds into storage_.
      tbc::val_self<PathIndexBuilder> builder_;
      FuzzyMatch<ConcurrentMemory> matcher_;
    };

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

      [[nodiscard]] FindPaths view() const noexcept;

      static constexpr std::size_t root_bytes = 4096;

      std::uint64_t request_id = 0;
      FixedText<root_bytes> root;
      FixedText<path_query_bytes> query;
      PathKindFilter kind = PathKindFilter::any;
      std::uint16_t limit = path_result_capacity;
    };

    // Kept whole: path_service_test instantiates it with its own GatedPathMemory and GatedPathIndex.
    template <Allocator Memory, typename Index = PathIndex>
      requires PathSearchIndex<Index, Memory>
    class TBC_GENERIC PathQueryTask {
    public:
      using Request = OwnedPathQuery;

      struct Result {
        bool complete = false;
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
    class TBC_GENERIC PathBuildTask {
    public:
      using Request = bool;
      using Result = bool;

      inline explicit PathBuildTask(Index& index)
          : index_(index) {}

      inline void stop() noexcept {
        index_.stop();
      }

      inline bool observe(bool /*request*/) noexcept {
        index_.build();
        return true;
      }

    private:
      Index& index_;
    };

  }
}
