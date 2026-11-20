export module telar.git:history;

import std;
import telar.base.memory.allocators;
import :format;
import :objects;
import telar.base.ds;

// Counts how far two commits diverged, as `git rev-list --left-right --count
// left...right` does: commits reachable from one side and not the other.

namespace telar::git {

  // The commits a shallow clone cut off from their parents.
  class ShallowCommits {
  public:
    explicit ShallowCommits(Memory& memory) noexcept;

    // Reloads <common>/shallow when it changed; false if it is unreadable.
    bool load(int common, ObjectFormat format, const Limits& limits);

    [[nodiscard]] bool empty() const noexcept;
    [[nodiscard]] bool contains(const ObjectId& id) const noexcept;

  private:
    ds::Vec<ObjectId, Memory> ids_;
    ds::String<Memory> bytes_;
    Fingerprint identity_;
    ObjectFormat format_ = ObjectFormat::sha1;
    bool loaded_ = false;
    bool valid_ = true;
  };

  struct Divergence {
    std::uint32_t ahead = 0;
    std::uint32_t behind = 0;
  };

  class DivergenceWalk {
  public:
    explicit DivergenceWalk(Memory& memory) noexcept;

    // Counts the commits only `left` reaches (ahead) and only `right` reaches
    // (behind). Returns nullopt when an object is unreadable or the walk would
    // visit more than limits.walk_commits commits.
    ds::Option<Divergence> count(ObjectDatabase& objects, const CommitGraph& graph, const ShallowCommits& shallow, const Limits& limits, const ObjectId& left, const ObjectId& right);

    std::uint64_t commits_read = 0;

  private:
    // What one walk reads, handed to each step rather than kept between walks.
    struct Sources {
      ObjectDatabase& objects;
      const CommitGraph& graph;
      const ShallowCommits& shallow;
      const Limits& limits;
    };

    ds::Option<Divergence> walk(Sources& sources);

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

    void reset();

    // A large walk's memory is returned once it ends; small walks keep theirs.
    void release();

    // Doubles the open-addressing table, keeping it at most half full.
    void grow();

    static std::uint64_t key(const CommitGraph& graph, std::uint64_t generation, std::int64_t time) noexcept;
    std::uint32_t& slot(const ObjectId& id) noexcept;

    // The node of commit `id`, read on first sight so its order key is known.
    ds::Option<std::uint32_t> insert(Sources& sources, const ObjectId& id, ds::Option<std::uint32_t> position);

    bool readCommit(Sources& sources, const ObjectId& id, CommitHeader& header);
    void classify(std::uint8_t flags, bool add) noexcept;

    // Adds `flags` to a node, keeps the counts, and queues it when it changed.
    void mark(std::uint32_t index, std::uint8_t flags);

    bool expand(Sources& sources, std::uint32_t index);

    ds::Vec<Node, Memory> nodes_;
    ds::Vec<std::uint32_t, Memory> slots_;
    ds::Vec<ObjectId, Memory> parents_;
    ds::Vec<std::uint32_t, Memory> graph_parents_;
    ds::Vec<Queued, Memory> heap_;
    ds::String<Memory> object_;
    std::uint32_t ahead_ = 0;
    std::uint32_t behind_ = 0;
    std::size_t interesting_ = 0;
  };

}
