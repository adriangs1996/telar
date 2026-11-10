export module telar.git:history;

import std;
import telar.base.memory;
import :format;
import :objects;

// Counts how far two commits diverged, as `git rev-list --left-right --count
// left...right` does: commits reachable from one side and not the other.

namespace telar::git {

// The commits a shallow clone cut off from their parents.
template <Allocator Memory>
class ShallowCommits {
public:
  inline explicit ShallowCommits(Memory &memory) noexcept
      : ids_(AllocatorRef<ObjectId, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}) {}

  // Reloads <common>/shallow when it changed; false if it is unreadable.
  inline bool load(int common, ObjectFormat format, const Limits &limits) {
    const auto identity = fingerprintAt(common, "shallow");
    if (loaded_ && identity == identity_ && format == format_) {
      return valid_;
    }
    loaded_ = true;
    identity_ = identity;
    format_ = format;
    ids_.clear();
    valid_ = true;
    if (!identity.present) {
      return true;
    }
    if (readWhole(common, "shallow", bytes_, limits.shallow_file) != ReadStatus::ok) {
      valid_ = false;
      return false;
    }
    std::string_view lines{bytes_};
    while (!lines.empty()) {
      const auto end = lines.find('\n');
      const auto id = ObjectId::fromHex(lines.substr(0, end), format);
      if (!id) {
        ids_.clear();
        valid_ = false;
        return false;
      }
      ids_.push_back(*id);
      lines.remove_prefix(end == std::string_view::npos ? lines.size() : end + 1);
    }
    std::ranges::sort(ids_, [](const ObjectId &left, const ObjectId &right) { return compareBytes(left.view(), right.view()) < 0; });
    bytes_.clear();
    return true;
  }

  inline bool empty() const noexcept { return ids_.empty(); }

  inline bool contains(const ObjectId &id) const noexcept {
    return std::ranges::binary_search(ids_, id, [](const ObjectId &left, const ObjectId &right) { return compareBytes(left.view(), right.view()) < 0; });
  }

private:
  Vector<ObjectId, Memory> ids_;
  String<Memory> bytes_;
  Fingerprint identity_;
  ObjectFormat format_ = ObjectFormat::sha1;
  bool loaded_ = false;
  bool valid_ = true;
};

struct Divergence {
  std::uint32_t ahead = 0;
  std::uint32_t behind = 0;
};

template <Allocator Memory>
class DivergenceWalk {
public:
  inline explicit DivergenceWalk(Memory &memory) noexcept
      : nodes_(AllocatorRef<Node, Memory>{memory}),
        slots_(AllocatorRef<std::uint32_t, Memory>{memory}),
        parents_(AllocatorRef<ObjectId, Memory>{memory}),
        graph_parents_(AllocatorRef<std::uint32_t, Memory>{memory}),
        heap_(AllocatorRef<Queued, Memory>{memory}),
        object_(AllocatorRef<char, Memory>{memory}) {}

  // Counts the commits only `left` reaches (ahead) and only `right` reaches
  // (behind). Returns nullopt when an object is unreadable or the walk would
  // visit more than limits.walk_commits commits.
  inline std::optional<Divergence> count(ObjectDatabase<Memory> &objects, const CommitGraph<Memory> &graph, const ShallowCommits<Memory> &shallow, const Limits &limits, const ObjectId &left, const ObjectId &right) {
    if (left == right) {
      return Divergence{};
    }
    objects_ = &objects;
    graph_ = &graph;
    shallow_ = &shallow;
    limits_ = &limits;
    reset();
    const auto left_node = insert(left, std::nullopt);
    const auto right_node = insert(right, std::nullopt);
    if (!left_node || !right_node) {
      return std::nullopt;
    }
    mark(*left_node, left_flag);
    mark(*right_node, right_flag);
    const auto result = walk(graph);
    release();
    return result;
  }

  std::uint64_t commits_read = 0;

private:
  inline std::optional<Divergence> walk(const CommitGraph<Memory> &graph) {
    // Generation numbers make the order exact (commits outside the graph are
    // newer than all of it and come first); commit dates may be skewed, so
    // like git's limit_list the walk drains a few stale commits past the end.
    constexpr unsigned slop = 5;
    unsigned remaining_slop = slop;
    while (!heap_.empty()) {
      if (interesting_ == 0) {
        if (!graph.empty() && nodes_[heap_.front().node].graph != no_position) {
          break;
        }
        if (remaining_slop-- == 0) {
          break;
        }
      } else {
        remaining_slop = slop;
      }
      std::ranges::pop_heap(heap_, std::less{}, &Queued::key);
      const auto index = heap_.back().node;
      heap_.pop_back();
      auto &node = nodes_[index];
      node.queued = false;
      if (node.flags != both) {
        --interesting_;
      }
      if (!expand(index)) {
        return std::nullopt;
      }
    }
    return Divergence{ahead_, behind_};
  }

  static constexpr std::uint8_t left_flag = 1;
  static constexpr std::uint8_t right_flag = 2;
  static constexpr std::uint8_t both = 3;
  static constexpr std::uint32_t no_position = std::numeric_limits<std::uint32_t>::max();
  static constexpr std::uint64_t infinite_generation = (std::uint64_t{1} << 30) - 1;
  static constexpr std::uint64_t time_mask = (std::uint64_t{1} << 34) - 1;
  static constexpr std::size_t initial_slots = 256;

  struct Node {
    ObjectId id;
    std::uint64_t key = 0;
    std::uint32_t graph = no_position;
    std::uint32_t parents_begin = 0;
    std::uint32_t parents_count = 0;
    std::uint8_t flags = 0;
    bool queued = false;
  };

  struct Queued {
    std::uint64_t key;
    std::uint32_t node;
  };

  inline void reset() {
    nodes_.clear();
    parents_.clear();
    heap_.clear();
    ahead_ = 0;
    behind_ = 0;
    interesting_ = 0;
    slots_.assign(initial_slots, 0);
  }

  // A large walk's memory is returned once it ends; small walks keep theirs.
  inline void release() {
    constexpr std::size_t retained = 4096;
    if (slots_.size() > retained) {
      slots_.clear();
      slots_.shrink_to_fit();
      graph_parents_.clear();
      graph_parents_.shrink_to_fit();
      nodes_.clear();
      nodes_.shrink_to_fit();
      parents_.clear();
      parents_.shrink_to_fit();
      heap_.clear();
      heap_.shrink_to_fit();
    }
  }

  // Doubles the open-addressing table, keeping it at most half full.
  inline void grow() {
    slots_.assign(slots_.size() * 2, 0);
    const auto mask = slots_.size() - 1;
    for (std::size_t node = 0; node < nodes_.size(); ++node) {
      auto index = static_cast<std::size_t>(hashOf(nodes_[node].id)) & mask;
      while (slots_[index] != 0) {
        index = (index + 1) & mask;
      }
      slots_[index] = static_cast<std::uint32_t>(node + 1);
    }
  }

  inline static std::uint64_t hashOf(const ObjectId &id) noexcept {
    std::uint64_t hash;
    std::memcpy(&hash, id.bytes.data(), sizeof(hash));
    return hash;
  }

  inline std::uint64_t key(std::uint64_t generation, std::int64_t time) const noexcept {
    const auto seconds = static_cast<std::uint64_t>(std::max<std::int64_t>(time, 0)) & time_mask;
    return graph_->empty() ? seconds : generation << 34 | seconds;
  }

  inline std::uint32_t &slot(const ObjectId &id) noexcept {
    const auto mask = slots_.size() - 1;
    for (auto index = static_cast<std::size_t>(hashOf(id)) & mask;; index = (index + 1) & mask) {
      auto &entry = slots_[index];
      if (entry == 0 || nodes_[entry - 1].id == id) {
        return entry;
      }
    }
  }

  // The node of commit `id`, read on first sight so its order key is known.
  inline std::optional<std::uint32_t> insert(const ObjectId &id, std::optional<std::uint32_t> position) {
    if (2 * (nodes_.size() + 1) > slots_.size()) {
      grow();
    }
    auto &entry = slot(id);
    if (entry != 0) {
      return entry - 1;
    }
    if (nodes_.size() >= limits_->walk_commits) {
      return std::nullopt;
    }
    Node node{.id = id};
    if (!position && !graph_->empty()) {
      position = graph_->find(id);
    }
    if (position) {
      const auto commit = graph_->commit(*position);
      if (!commit) {
        return std::nullopt;
      }
      node.graph = *position;
      node.key = key(commit->generation, commit->time);
    } else {
      CommitHeader header;
      node.parents_begin = static_cast<std::uint32_t>(parents_.size());
      if (!readCommit(id, header)) {
        return std::nullopt;
      }
      if (shallow_->contains(id)) {
        parents_.resize(node.parents_begin);
      }
      node.parents_count = static_cast<std::uint32_t>(parents_.size() - node.parents_begin);
      node.key = key(infinite_generation, header.time);
    }
    nodes_.push_back(node);
    entry = static_cast<std::uint32_t>(nodes_.size());
    return entry - 1;
  }

  inline bool readCommit(const ObjectId &id, CommitHeader &header) {
    ++commits_read;
    const auto begin = parents_.size();
    constexpr std::size_t first_prefix = 4096;
    for (const auto prefix : {std::min(first_prefix, limits_->commit_header), limits_->commit_header}) {
      ObjectType type = ObjectType::none;
      if (objects_->read(id, type, object_, prefix) != Lookup::found || type != ObjectType::commit) {
        return false;
      }
      if (parseCommit(object_, objects_->format(), limits_->commit_parents, header, parents_)) {
        return true;
      }
      parents_.resize(begin);
      if (object_.size() < prefix) {
        return false;
      }
    }
    return false;
  }

  inline void classify(std::uint8_t flags, bool add) noexcept {
    auto *count = flags == left_flag ? &ahead_ : flags == right_flag ? &behind_ : nullptr;
    if (count != nullptr) {
      *count = add ? *count + 1 : *count - 1;
    }
  }

  // Adds `flags` to a node, keeps the counts, and queues it when it changed.
  inline void mark(std::uint32_t index, std::uint8_t flags) {
    auto &node = nodes_[index];
    const auto previous = node.flags;
    const auto next = static_cast<std::uint8_t>(previous | flags);
    if (next == previous) {
      return;
    }
    classify(previous, false);
    classify(next, true);
    node.flags = next;
    if (node.queued) {
      if (previous != 0 && next == both) {
        --interesting_;
      }
      return;
    }
    node.queued = true;
    if (next != both) {
      ++interesting_;
    }
    heap_.push_back({node.key, index});
    std::ranges::push_heap(heap_, std::less{}, &Queued::key);
  }

  inline bool expand(std::uint32_t index) {
    const auto flags = nodes_[index].flags;
    if (nodes_[index].graph != no_position) {
      const auto commit = graph_->commit(nodes_[index].graph);
      graph_parents_.clear();
      if (!commit || !graph_->parents(*commit, limits_->commit_parents, [&](std::uint32_t parent) { graph_parents_.push_back(parent); })) {
        return false;
      }
      for (const auto parent : graph_parents_) {
        const auto id = graph_->id(parent);
        if (!id) {
          return false;
        }
        const auto node = insert(*id, parent);
        if (!node) {
          return false;
        }
        mark(*node, flags);
      }
      return true;
    }
    const auto begin = nodes_[index].parents_begin;
    const auto count = nodes_[index].parents_count;
    for (std::uint32_t offset = 0; offset < count; ++offset) {
      const auto parent = parents_[begin + offset];
      const auto node = insert(parent, std::nullopt);
      if (!node) {
        return false;
      }
      mark(*node, flags);
    }
    return true;
  }

  ObjectDatabase<Memory> *objects_ = nullptr;
  const CommitGraph<Memory> *graph_ = nullptr;
  const ShallowCommits<Memory> *shallow_ = nullptr;
  const Limits *limits_ = nullptr;
  Vector<Node, Memory> nodes_;
  Vector<std::uint32_t, Memory> slots_;
  Vector<ObjectId, Memory> parents_;
  Vector<std::uint32_t, Memory> graph_parents_;
  Vector<Queued, Memory> heap_;
  String<Memory> object_;
  std::uint32_t ahead_ = 0;
  std::uint32_t behind_ = 0;
  std::size_t interesting_ = 0;
};

}
