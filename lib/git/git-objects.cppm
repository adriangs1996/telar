module;
#include "tbc/annotations.hpp"

export module telar.git:objects;

import std;
import telar.base.memory.allocators;
import telar.base.memory.containers;
import telar.native.zlib;
import telar.platform.primitives;
import :format;
import telar.base.ds;
import telar.tbc;

// The object database: loose objects, packfiles with their v2 indexes and
// delta chains, and the commit-graph. Reads use pread on descriptors rather
// than mmap: a file truncated under a mapping would raise SIGBUS in the caller.

namespace telar::git {

  enum class ObjectType : std::uint8_t {
    none = 0,
    commit = 1,
    tree = 2,
    blob = 3,
    tag = 4,
  };

  enum class Lookup : std::uint8_t {
    found,
    missing,
    invalid,
  };

  // Routes zlib's allocations to the reader's allocator. zlib frees without a
  // size, which CAllocationBlocks records in front of each block.
  class Inflater {
  public:
    explicit Inflater(Memory& memory) noexcept;
    ~Inflater();
    Inflater(const Inflater&) = delete;
    Inflater& operator=(const Inflater&) = delete;
    Inflater(Inflater&&) = delete;
    Inflater& operator=(Inflater&&) = delete;

    // Starts a new stream, keeping zlib's window allocated between objects.
    bool start() noexcept;

    z_stream& stream() noexcept;

  private:
    static voidpf allocate(voidpf opaque, uInt items, uInt size) noexcept;
    static void release(voidpf opaque, voidpf address) noexcept;

    CAllocationBlocks<Memory> blocks_;
    z_stream stream_{};
    bool ready_ = false;
  };

  // Sizes `string` without zeroing it; the inflater overwrites every byte.
  void resizeForOverwrite(ds::String<Memory>& string, std::size_t size);

  struct CommitHeader {
    ObjectId tree;
    std::int64_t time = 0;
  };

  // Parses the header of a commit, or of its first bytes: the tree, the
  // parents (appended to `parents`) and the committer time.
  bool parseCommit(std::string_view content, ObjectFormat format, std::size_t maximum_parents, CommitHeader& header, ds::Vec<ObjectId, Memory>& parents);

  inline constexpr std::uint32_t mode_type_mask = 0170000;
  inline constexpr std::uint32_t mode_directory = 0040000;
  inline constexpr std::uint32_t mode_regular = 0100000;
  inline constexpr std::uint32_t mode_symlink = 0120000;
  inline constexpr std::uint32_t mode_gitlink = 0160000;
  inline constexpr std::uint32_t mode_file = 0100644;
  inline constexpr std::uint32_t mode_executable = 0100755;

  // A file mode old gits wrote, which reads as mode_file.
  inline constexpr std::uint32_t mode_group_writable = 0100664;

  struct TreeEntry {
    std::uint32_t mode = 0;
    std::string_view name;
    ObjectId id;

    [[nodiscard]] bool directory() const noexcept;
  };

  // git's tree order: a directory sorts as if its name ended with '/'.
  int compareTreeNames(std::string_view left, bool left_directory, std::string_view right, bool right_directory) noexcept;

  // Iterates the entries of a tree object, refusing malformed or unordered ones.
  class TreeReader {
  public:
    TreeReader(tbc::val_a<std::string_view> content, ObjectFormat format) noexcept;

    // False at the end, or when `failed()` because the tree is malformed.
    bool next(tbc::mut_a<TreeEntry> entry) noexcept;

    [[nodiscard]] bool failed() const noexcept;

  private:
    bool fail() noexcept;

    tbc::val_a<std::string_view> rest_;
    std::size_t hash_size_;
    tbc::val_a<std::string_view> previous_;
    bool previous_directory_ = false;
    bool have_previous_ = false;
    bool failed_ = false;
  };

  // A base-128 number: seven bits a byte, the high bit set on every byte but the last.
  inline constexpr unsigned varint_payload_bits = 7;
  inline constexpr std::uint8_t varint_payload = 0x7f;
  inline constexpr std::uint8_t varint_continues = 0x80;

  // The value of an offset-encoded number, as OFS_DELTA distances and index v4 prefix lengths, that
  // one more byte would overflow.
  inline constexpr std::uint64_t maximum_offset_varint = std::uint64_t{1} << 56U;

  // A fanout table: how many objects sort at or before each first byte of an id.
  inline constexpr std::size_t fanout_entries = 256;

  struct Pack {
    FileDescriptor index;
    FileDescriptor data;
    std::uint64_t index_size = 0;
    std::uint64_t data_size = 0;
    std::uint64_t large_offsets = 0;
    std::uint32_t count = 0;
    ds::Array<std::uint32_t, fanout_entries> fanout{};
  };

  // A v2 pack index starts with its signature and version, then its fanout table.
  inline constexpr std::size_t pack_index_fanout = 8;
  inline constexpr std::size_t pack_index_header = pack_index_fanout + (fanout_entries * sizeof(std::uint32_t));

  class ObjectDatabase {
  public:
    explicit ObjectDatabase(Memory& memory) noexcept;

    // Opens `<common>/objects` and refreshes the pack list when objects/pack changed.
    bool open(int common, ObjectFormat format, const Limits& limits);

    void close() noexcept;
    [[nodiscard]] int objects() const noexcept;
    [[nodiscard]] ObjectFormat format() const noexcept;

    // Reads object `id` into `output`. With a non-zero `prefix`, only its first
    // `prefix` bytes are kept, and an undeltified object is inflated no further.
    Lookup read(const ObjectId& id, ObjectType& type, ds::String<Memory>& output, std::size_t prefix = 0);

    // Releases buffers that one large object grew, so the cache stays small.
    void trim();

    // The objects read since the last resetObjectsRead().
    [[nodiscard]] std::uint64_t objectsRead() const noexcept;
    void resetObjectsRead() noexcept;

  private:
    static constexpr std::uint32_t loose = std::numeric_limits<std::uint32_t>::max();

    struct Link {
      std::uint32_t pack;
      std::uint64_t data_offset;
      std::uint64_t size;
    };

    // Where an object is: a pack and the offset of its entry, or `loose`.
    struct Location {
      std::uint32_t pack = 0;
      std::uint64_t offset = 0;
    };

    struct Entry {
      std::uint8_t kind = 0;
      std::uint64_t size = 0;
      std::uint64_t data_offset = 0;
      std::uint64_t base_offset = 0;
      ObjectId base;
    };

    // A packed object to inflate: its pack, where its compressed bytes start, and the bytes it
    // inflates into, all of its bytes when `whole`, else only their prefix.
    struct Inflation {
      const Pack& pack;
      std::uint64_t data_offset = 0;
      std::span<std::uint8_t> output;
      bool whole = false;
    };

    static constexpr std::size_t block_bytes = 8192;
    static constexpr std::size_t chunk_bytes = 16384;

    void refreshPacks();
    bool openPack(int directory, std::string_view index_name, Pack& pack) noexcept;

    // The position of `id` in a pack index, by binary search over pread blocks.
    // The helpers below are static and take the fields they use, so a call borrows those fields apart
    // from the pack it reads.
    static ds::Option<std::uint32_t> findInPack(std::span<std::uint8_t> block, const Pack& pack, const ObjectId& id) noexcept;

    static ds::Option<std::uint64_t> packOffset(ObjectFormat format, const Pack& pack, std::uint32_t position) noexcept;
    Lookup locate(const ObjectId& id, Location& location);
    static bool entryAt(ObjectFormat format, const Pack& pack, std::uint64_t offset, Entry& entry) noexcept;
    static bool inflatePacked(Inflater& inflater, std::span<std::uint8_t> chunk, ObjectFormat format, Inflation inflation);
    Lookup readPacked(Location location, ObjectType& type, ds::String<Memory>& output, std::size_t prefix);

    // Follows the delta chain of the object at `location` down to its base, recording each delta in
    // chain_. It leaves `location` and `entry` on the base when the base is packed, and sets
    // `loose_base` to its id when it is a loose object.
    bool chainToBase(Location& location, Entry& entry, ds::Option<ObjectId>& loose_base);

    // Applies chain_'s deltas to base_, the one nearest the base first.
    bool applyChain();
    Lookup readLoose(const ObjectId& id, ObjectType& type, ds::String<Memory>& output, std::size_t prefix);

    // Counts bytes against the per-read budget, so that a crafted delta chain
    // cannot make one read inflate gigabytes.
    static bool charge(std::uint64_t& inflated, std::uint64_t limit, std::uint64_t bytes) noexcept;

    Limits limits_;
    std::uint64_t inflated_ = 0;
    ObjectFormat format_ = ObjectFormat::sha1;
    FileDescriptor objects_;
    Fingerprint packs_identity_;
    Inflater inflater_;
    ds::Vec<Pack, Memory> packs_;
    ds::Vec<Link, Memory> chain_;
    std::size_t last_pack_ = 0;
    ds::String<Memory> compressed_;
    ds::String<Memory> base_;
    ds::String<Memory> target_;
    ds::String<Memory> delta_;
    std::uint64_t objects_read_ = 0;
    ds::Array<std::uint8_t, block_bytes> block_{};
    ds::Array<std::uint8_t, chunk_bytes> chunk_{};
  };

  // The commit-graph file, or the layers of a split chain. Only each layer's
  // fanout is kept in memory; commits are read with pread when the walk needs
  // them, so a large graph costs a descriptor, not its size, per reader.
  // Positions are global across layers, lower layers first.
  class CommitGraph {
  public:
    static constexpr std::uint32_t no_parent = 0x70000000U;

    struct Layer {
      FileDescriptor file;
      std::uint64_t size = 0;
      std::uint32_t base = 0;
      std::uint32_t count = 0;
      std::uint64_t names = 0;
      std::uint64_t commits = 0;
      std::uint64_t edges = 0;
      std::uint64_t edges_size = 0;
      ds::Array<std::uint32_t, fanout_entries> fanout{};
    };

    struct Commit {
      std::uint32_t generation = 0;
      std::int64_t time = 0;
      std::uint32_t first = no_parent;
      std::uint32_t second = no_parent;
      const Layer* layer = nullptr;
    };

    explicit CommitGraph(Memory& memory) noexcept;

    // Reopens the graph when the commit-graph file or the chain file changed.
    // Any invalid layer leaves the graph empty: the walk then reads commits.
    void load(int objects, ObjectFormat format, const Limits& limits, bool disabled);

    void clear() noexcept;
    [[nodiscard]] bool empty() const noexcept;

    // The global position of `id`, nullopt when absent or unreadable.
    [[nodiscard]] ds::Option<std::uint32_t> find(const ObjectId& id) const noexcept;

    // `position` must come from find() or parents().
    [[nodiscard]] ds::Option<ObjectId> id(std::uint32_t position) const noexcept;

    // The commit at `position`. A generation of 0, which no released git
    // writes, would break the walk's order, so it reads as unreadable.
    [[nodiscard]] ds::Option<Commit> commit(std::uint32_t position) const noexcept;

    // Calls `output` with each parent of `commit`; false when the graph is malformed.
    template <typename Output>
    TBC_GENERIC bool parents(const Commit& commit, std::size_t maximum, Output&& output) const {
      // Stays generic over the caller's output, which the walk calls through a function pointer.
      using Target = std::remove_reference_t<Output>;

      auto&& visitor = std::forward<Output>(output);

      return visitParents(commit, maximum, tbc::raw(const_cast<std::remove_const_t<Target>*>(std::addressof(visitor))), [](void* target, std::uint32_t parent) {
        (*static_cast<Target*>(target))(parent);
      });
    }

  private:
    [[nodiscard]] const Layer* layerOf(std::uint32_t position) const noexcept;
    static bool visitParents(const Commit& commit, std::size_t maximum, void* target, void (*output)(void*, std::uint32_t));

    // Validates the header, the chunk table and the fanout of one layer.
    bool addLayer(int objects, const char* path);

    ds::Vec<Layer, Memory> layers_;
    ds::String<Memory> chain_;
    Fingerprint single_;
    Fingerprint chain_identity_;
    ObjectFormat format_ = ObjectFormat::sha1;
    bool loaded_ = false;
  };

}
