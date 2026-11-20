module telar.git;

import std;
import telar.base.ds;

namespace telar::git {

  namespace {

    std::uint64_t hashOf(const ObjectId& id) noexcept {
      ds::Array<std::uint8_t, sizeof(std::uint64_t)> head{};

      std::ranges::copy(id.bytes.view().first<sizeof(std::uint64_t)>(), head.viewMut().begin());
      return std::bit_cast<std::uint64_t>(head);
    }

  }

  ShallowCommits::ShallowCommits(Memory& memory) noexcept
      : ids_(memory),
        bytes_(memory) {}

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

      ids_.push(*id);
      lines.remove_prefix(end == std::string_view::npos ? lines.size() : end + 1);
    }

    std::ranges::sort(ids_.viewMut(), [](const ObjectId& left, const ObjectId& right) {
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
      : nodes_(memory),
        slots_(memory),
        parents_(memory),
        graph_parents_(memory),
        heap_(memory),
        object_(memory) {}

  ds::Option<Divergence> DivergenceWalk::count(Sources sources, const ObjectId& left, const ObjectId& right) {
    if (left == right) {
      return Divergence{};
    }

    reset();
    const auto left_node = insert(sources, left, ds::none);
    const auto right_node = insert(sources, right, ds::none);
    if (!left_node || !right_node) {
      return ds::none;
    }

    mark(*left_node, Reach::left);
    mark(*right_node, Reach::right);
    const auto result = walk(sources);

    release();
    return result;
  }

  ds::Option<Divergence> DivergenceWalk::walk(Sources& sources) {
    // Generation numbers make the order exact (commits outside the graph are
    // newer than all of it and come first); commit dates may be skewed, so
    // like git's limit_list the walk drains a few stale commits past the end.
    constexpr unsigned slop = 5;
    unsigned remaining_slop = slop;

    while (!heap_.empty()) {
      if (interesting_ == 0) {
        if (!sources.graph.empty() && nodes_[heap_.front().node].graph != no_position) {
          break;
        }

        if (remaining_slop-- == 0) {
          break;
        }
      } else {
        remaining_slop = slop;
      }

      std::ranges::pop_heap(heap_.viewMut(), std::less{}, &Queued::key);
      const auto index = heap_.back().node;

      heap_.truncate(heap_.size() - 1);
      auto& node = nodes_.atMut(index);

      node.queued = false;
      if (node.reach != Reach::both) {
        --interesting_;
      }

      if (!expand(sources, index)) {
        return ds::none;
      }
    }

    return Divergence{.ahead = ahead_, .behind = behind_};
  }

  std::uint64_t DivergenceWalk::commitsRead() const noexcept {
    return commits_read_;
  }

  void DivergenceWalk::resetCommitsRead() noexcept {
    commits_read_ = 0;
  }

  void DivergenceWalk::reset() {
    nodes_.clear();
    parents_.clear();
    heap_.clear();
    ahead_ = 0;
    behind_ = 0;
    interesting_ = 0;
    slots_.clear();
    slots_.resize(initial_slots, 0);
  }

  void DivergenceWalk::release() {
    constexpr std::size_t retained = 4096;
    if (slots_.size() > retained) {
      slots_.clear();
      slots_.shrinkToFit();
      graph_parents_.clear();
      graph_parents_.shrinkToFit();
      nodes_.clear();
      nodes_.shrinkToFit();
      parents_.clear();
      parents_.shrinkToFit();
      heap_.clear();
      heap_.shrinkToFit();
    }
  }

  void DivergenceWalk::grow() {
    const auto count = slots_.size() * 2;

    slots_.clear();
    slots_.resize(count, 0);
    const auto mask = slots_.size() - 1;

    for (std::size_t node = 0; node < nodes_.size(); ++node) {
      auto index = static_cast<std::size_t>(hashOf(nodes_[node].id)) & mask;

      while (slots_[index] != 0) {
        index = (index + 1) & mask;
      }

      slots_.atMut(index) = static_cast<std::uint32_t>(node + 1);
    }
  }

  std::uint64_t DivergenceWalk::key(const CommitGraph& graph, Age age) noexcept {
    const auto seconds = static_cast<std::uint64_t>(std::max<std::int64_t>(age.time, 0)) & time_mask;

    return graph.empty() ? seconds : age.generation << time_bits | seconds;
  }

  std::uint32_t& DivergenceWalk::slot(const ObjectId& id) noexcept {
    const auto mask = slots_.size() - 1;

    for (auto index = static_cast<std::size_t>(hashOf(id)) & mask;; index = (index + 1) & mask) {
      auto& entry = slots_.atMut(index);
      if (entry == 0 || nodes_[entry - 1].id == id) {
        return entry;
      }
    }
  }

  ds::Option<std::uint32_t> DivergenceWalk::insert(Sources& sources, const ObjectId& id, ds::Option<std::uint32_t> position) {
    if (2 * (nodes_.size() + 1) > slots_.size()) {
      grow();
    }

    auto& entry = slot(id);
    if (entry != 0) {
      return entry - 1;
    }

    if (nodes_.size() >= sources.limits.walk_commits) {
      return ds::none;
    }

    Node node{.id = id};

    if (!position && !sources.graph.empty()) {
      position = sources.graph.find(id);
    }

    if (position) {
      const auto commit = sources.graph.commit(*position);
      if (!commit) {
        return ds::none;
      }

      node.graph = *position;
      node.key = key(sources.graph, {.generation = commit->generation, .time = commit->time});
    } else {
      CommitHeader header;

      node.parents_begin = static_cast<std::uint32_t>(parents_.size());
      if (!readCommit(sources, id, header)) {
        return ds::none;
      }

      if (sources.shallow.contains(id)) {
        parents_.resize(node.parents_begin);
      }

      node.parents_count = static_cast<std::uint32_t>(parents_.size() - node.parents_begin);
      node.key = key(sources.graph, {.generation = infinite_generation, .time = header.time});
    }

    nodes_.push(node);
    entry = static_cast<std::uint32_t>(nodes_.size());
    return entry - 1;
  }

  bool DivergenceWalk::readCommit(Sources& sources, const ObjectId& id, CommitHeader& header) {
    ++commits_read_;
    const auto begin = parents_.size();
    constexpr std::size_t first_prefix = 4096;

    for (const auto prefix : {std::min(first_prefix, sources.limits.commit_header), sources.limits.commit_header}) {
      ObjectType type = ObjectType::none;
      if (sources.objects.read(id, type, object_, prefix) != Lookup::found || type != ObjectType::commit) {
        return false;
      }

      if (parseCommit(object_, sources.objects.format(), sources.limits.commit_parents, header, parents_)) {
        return true;
      }

      parents_.resize(begin);
      if (object_.size() < prefix) {
        return false;
      }
    }

    return false;
  }

  void DivergenceWalk::classify(Reach reach, bool add) noexcept {
    if (reach != Reach::left && reach != Reach::right) {
      return;
    }

    auto& count = reach == Reach::left ? ahead_ : behind_;

    count = add ? count + 1 : count - 1;
  }

  void DivergenceWalk::mark(std::uint32_t index, Reach reach) {
    auto& node = nodes_.atMut(index);
    const auto previous = node.reach;
    const auto next = static_cast<Reach>(std::to_underlying(previous) | std::to_underlying(reach));
    if (next == previous) {
      return;
    }

    classify(previous, false);
    classify(next, true);
    node.reach = next;
    if (node.queued) {
      if (previous != Reach::none && next == Reach::both) {
        --interesting_;
      }

      return;
    }

    node.queued = true;
    if (next != Reach::both) {
      ++interesting_;
    }

    heap_.push({.key = node.key, .node = index});
    std::ranges::push_heap(heap_.viewMut(), std::less{}, &Queued::key);
  }

  bool DivergenceWalk::expand(Sources& sources, std::uint32_t index) {
    const auto reach = nodes_[index].reach;

    if (nodes_[index].graph != no_position) {
      const auto commit = sources.graph.commit(nodes_[index].graph);
      // The parents' buffer, taken while they are inserted: inserting mutates the walk.
      auto parents = std::move(graph_parents_);
      bool expanded = true;

      parents.clear();
      if (!commit || !sources.graph.parents(*commit, sources.limits.commit_parents, [&](std::uint32_t parent) {
            parents.push(parent);
          })) {
        expanded = false;
      }

      for (std::size_t at = 0; expanded && at < parents.size(); ++at) {
        const auto parent = parents[at];
        const auto id = sources.graph.id(parent);
        const auto node = id ? insert(sources, *id, parent) : ds::none;

        if (node) {
          mark(*node, reach);
        } else {
          expanded = false;
        }
      }

      graph_parents_ = std::move(parents);
      return expanded;
    }

    const auto begin = nodes_[index].parents_begin;
    const auto count = nodes_[index].parents_count;

    for (std::uint32_t offset = 0; offset < count; ++offset) {
      const auto parent = parents_[begin + offset];
      const auto node = insert(sources, parent, ds::none);
      if (!node) {
        return false;
      }

      mark(*node, reach);
    }

    return true;
  }

}
