#pragma once

#include "../diagnostics/trace.hpp"
#include "../transport/encoded_reply.hpp"
#include "fuzzy_match.hpp"
#include "index_builder.hpp"

namespace telar::runtime {

template <Allocator Memory>
class PathIndex {
public:
  explicit PathIndex(Memory &memory)
      : root_(AllocatorRef<char, Memory>{memory}),
        storage_(memory),
        builder_(memory, storage_),
        matcher_(memory) {
    root_.reserve(4096);
  }

  void stop() noexcept {
    storage_.cancelled.store(true, std::memory_order_relaxed);
  }

  std::string_view root() const noexcept {
    return root_;
  }

  void reset(std::string_view root) {
    root_.assign(root);
    storage_.reset();
  }

  void build() noexcept {
    builder_.build(root_.c_str());
  }

  bool complete() const noexcept {
    return storage_.complete.load(std::memory_order_acquire);
  }

  bool canQueryInline(const FindPaths &request) const noexcept {
    constexpr std::size_t maximum_inline_entries = 256;
    constexpr std::size_t maximum_inline_steps = 16 * 1024;
    const auto query_length = std::max<std::size_t>(1, request.query.size());
    return complete() && !request.refresh && root_ == request.root && storage_.count <= maximum_inline_entries && storage_.bytes_used <= maximum_inline_steps / query_length;
  }

  template <typename Reply>
  void query(const FindPaths &request, Reply &reply) {
    if (!complete() || root_ != request.root || request.refresh) {
      reset(request.root);
      build();
    }
    queryPublished(request, reply);
  }

  template <typename Reply>
  bool queryPublished(const FindPaths &request, Reply &reply) {
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
      const auto &entry = storage_.entry(index);
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
      const auto &entry = storage_.entry(ranked[index].entry);
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

  std::string_view path(const IndexedPath &entry) const noexcept {
    return storage_.path(entry);
  }

  static std::size_t depth(std::string_view path) noexcept {
    if (path.ends_with('/')) {
      path.remove_suffix(1);
    }

    return std::count(path.begin(), path.end(), '/');
  }

  bool better(const Candidate &left, const Candidate &right, bool browse) const noexcept {
    const auto &left_entry = storage_.entry(left.entry);
    const auto &right_entry = storage_.entry(right.entry);
    const auto left_path = path(left_entry);
    const auto right_path = path(right_entry);
    if (browse) {
      if (depth(left_path) != depth(right_path)) {
        return depth(left_path) < depth(right_path);
      }
      if (left_entry.kind != right_entry.kind) {
        return left_entry.kind == PathKind::directory;
      }
    } else {
      if (left.score != right.score) {
        return left.score > right.score;
      }
      if (left_path.size() != right_path.size()) {
        return left_path.size() < right_path.size();
      }
    }

    return left_path < right_path;
  }

  String<Memory> root_;
  PathIndexStorage<Memory> storage_;
  PathIndexBuilder<Memory> builder_;
  FuzzyMatch<Memory> matcher_;
};

}
