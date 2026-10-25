#pragma once

#include "../memory/fixed_text.hpp"
#include "path_index.hpp"

namespace telar::runtime {

template <typename Index, typename Memory>
concept PathSearchIndex = Allocator<Memory> && requires(Index &index, const FindPaths &request, EncodedReply<Memory> &reply) {
  { index.root() } noexcept -> std::same_as<std::string_view>;
  { index.reset(request.root) } -> std::same_as<void>;
  { index.build() } noexcept -> std::same_as<void>;
  { index.stop() } noexcept -> std::same_as<void>;
  { index.complete() } noexcept -> std::same_as<bool>;
  { index.canQueryInline(request) } noexcept -> std::same_as<bool>;
  { index.queryPublished(request, reply) } -> std::same_as<bool>;
};

struct OwnedPathQuery {
  void assign(const FindPaths &request) {
    request_id = request.request_id;
    root.assign(request.root);
    query.assign(request.query);
    kind = request.kind;
    limit = request.limit;
  }

  FindPaths view() const noexcept {
    return FindPaths{.request_id = request_id, .root = root.view(), .query = query.view(), .kind = kind, .limit = limit};
  }

  std::uint64_t request_id = 0;
  FixedText<4096> root;
  FixedText<64> query;
  PathKindFilter kind = PathKindFilter::any;
  std::uint16_t limit = 50;
};

template <Allocator Memory, typename Index = PathIndex<Memory>>
  requires PathSearchIndex<Index, Memory>
class PathQueryTask {
public:
  using Request = OwnedPathQuery;

  struct Result {
    bool complete;
    std::span<const Byte> payload;
  };

  explicit PathQueryTask(Memory &memory, Index &index)
      : index_(index),
        reply_(memory) {}

  void stop() noexcept {
    index_.stop();
  }

  Result observe(const Request &request) noexcept {
    try {
      const bool complete = index_.queryPublished(request.view(), reply_);
      return {complete, reply_.payload()};
    } catch (const RequestError &error) {
      reply_.send(RequestFailed{.request_id = request.request_id, .code = error.code(), .message = error.what()});
    } catch (...) {
      reply_.send(RequestFailed{.request_id = request.request_id, .code = FailureCode::resource_limit, .message = "Path query memory is unavailable"});
    }

    return {true, reply_.payload()};
  }

private:
  Index &index_;
  EncodedReply<Memory> reply_;
};

template <typename Index>
class PathBuildTask {
public:
  using Request = bool;
  using Result = bool;

  explicit PathBuildTask(Index &index)
      : index_(index) {}

  void stop() noexcept {
    index_.stop();
  }

  bool observe(bool) noexcept {
    index_.build();
    return true;
  }

private:
  Index &index_;
};

}
