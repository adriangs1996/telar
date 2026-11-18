module telar.git;

import std;
import telar.base.ds;

namespace telar::git {

  namespace {

    std::uint64_t hashOf(const ObjectId& id) noexcept {
      std::uint64_t hash;

      std::memcpy(&hash, id.bytes.data(), sizeof(hash));
      return hash;
    }

  }

  ShallowCommits::ShallowCommits(Memory& memory) noexcept
      : ids_(AllocatorRef<ObjectId, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}) {}

  bool ShallowCommits::load(int common, ObjectFormat format, const Limits& limits) {
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

    std::ranges::sort(ids_, [](const ObjectId& left, const ObjectId& right) {
      return compareBytes(left.view(), right.view()) < 0;
    });

    bytes_.clear();
    return true;
  }

  bool ShallowCommits::empty() const noexcept {
    return ids_.empty();
  }

  bool ShallowCommits::contains(const ObjectId& id) const noexcept {
    return std::ranges::binary_search(ids_, id, [](const ObjectId& left, const ObjectId& right) {
      return compareBytes(left.view(), right.view()) < 0;
    });
  }

  DivergenceWalk::DivergenceWalk(Memory& memory) noexcept
      : nodes_(AllocatorRef<Node, Memory>{memory}),
        slots_(AllocatorRef<std::uint32_t, Memory>{memory}),
        parents_(AllocatorRef<ObjectId, Memory>{memory}),
        graph_parents_(AllocatorRef<std::uint32_t, Memory>{memory}),
        heap_(AllocatorRef<Queued, Memory>{memory}),
        object_(AllocatorRef<char, Memory>{memory}) {}

  ds::Option<Divergence> DivergenceWalk::count(ObjectDatabase& objects, const CommitGraph& graph, const ShallowCommits& shallow, const Limits& limits, const ObjectId& left, const ObjectId& right) {
    if (left == right) {
      return Divergence{};
    }

    objects_ = &objects;
    graph_ = &graph;
    shallow_ = &shallow;
    limits_ = &limits;
    reset();
    const auto left_node = insert(left, ds::none);
    const auto right_node = insert(right, ds::none);
    if (!left_node || !right_node) {
      return ds::none;
    }

    mark(*left_node, left_flag);
    mark(*right_node, right_flag);
    const auto result = walk(graph);

    release();
    return result;
  }

  ds::Option<Divergence> DivergenceWalk::walk(const CommitGraph& graph) {
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
      auto& node = nodes_[index];

      node.queued = false;
      if (node.flags != both) {
        --interesting_;
      }

      if (!expand(index)) {
        return ds::none;
      }
    }

    return Divergence{ahead_, behind_};
  }

  void DivergenceWalk::reset() {
    nodes_.clear();
    parents_.clear();
    heap_.clear();
    ahead_ = 0;
    behind_ = 0;
    interesting_ = 0;
    slots_.assign(initial_slots, 0);
  }

  void DivergenceWalk::release() {
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

  void DivergenceWalk::grow() {
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

  std::uint64_t DivergenceWalk::key(std::uint64_t generation, std::int64_t time) const noexcept {
    const auto seconds = static_cast<std::uint64_t>(std::max<std::int64_t>(time, 0)) & time_mask;

    return graph_->empty() ? seconds : generation << 34 | seconds;
  }

  std::uint32_t& DivergenceWalk::slot(const ObjectId& id) noexcept {
    const auto mask = slots_.size() - 1;

    for (auto index = static_cast<std::size_t>(hashOf(id)) & mask;; index = (index + 1) & mask) {
      auto& entry = slots_[index];
      if (entry == 0 || nodes_[entry - 1].id == id) {
        return entry;
      }
    }
  }

  ds::Option<std::uint32_t> DivergenceWalk::insert(const ObjectId& id, ds::Option<std::uint32_t> position) {
    if (2 * (nodes_.size() + 1) > slots_.size()) {
      grow();
    }

    auto& entry = slot(id);
    if (entry != 0) {
      return entry - 1;
    }

    if (nodes_.size() >= limits_->walk_commits) {
      return ds::none;
    }

    Node node{.id = id};

    if (!position && !graph_->empty()) {
      position = graph_->find(id);
    }

    if (position) {
      const auto commit = graph_->commit(*position);
      if (!commit) {
        return ds::none;
      }

      node.graph = *position;
      node.key = key(commit->generation, commit->time);
    } else {
      CommitHeader header;

      node.parents_begin = static_cast<std::uint32_t>(parents_.size());
      if (!readCommit(id, header)) {
        return ds::none;
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

  bool DivergenceWalk::readCommit(const ObjectId& id, CommitHeader& header) {
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

  void DivergenceWalk::classify(std::uint8_t flags, bool add) noexcept {
    auto* count = flags == left_flag ? &ahead_ : flags == right_flag ? &behind_
                                                                     : nullptr;
    if (count != nullptr) {
      *count = add ? *count + 1 : *count - 1;
    }
  }

  void DivergenceWalk::mark(std::uint32_t index, std::uint8_t flags) {
    auto& node = nodes_[index];
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

  bool DivergenceWalk::expand(std::uint32_t index) {
    const auto flags = nodes_[index].flags;

    if (nodes_[index].graph != no_position) {
      const auto commit = graph_->commit(nodes_[index].graph);

      graph_parents_.clear();
      if (!commit || !graph_->parents(*commit, limits_->commit_parents, [&](std::uint32_t parent) {
            graph_parents_.push_back(parent);
          })) {
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
      const auto node = insert(parent, ds::none);
      if (!node) {
        return false;
      }

      mark(*node, flags);
    }

    return true;
  }

}
