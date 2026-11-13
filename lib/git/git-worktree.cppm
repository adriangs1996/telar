module;
#include <cerrno>
#include <fcntl.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

export module telar.git:worktree;

import std;
import telar.base.memory;
import telar.base.text;
import telar.platform.primitives;
import :format;
import :objects;

// The index (versions 2 to 4) and the two comparisons git status makes with
// it: HEAD's tree against the index (staged) and the index against the
// working tree (unstaged). Paths come from the index, so they are untrusted:
// the working tree is walked with openat and O_NOFOLLOW, one directory
// descriptor per component, and never through a symlink.

export namespace telar::git {

// Paths counted per kind, as `git status --porcelain=v2` reports them with
// renames off, untracked files hidden and submodule work trees not inspected.
struct ChangeCounts {
  std::uint32_t staged_added = 0;
  std::uint32_t staged_modified = 0;   // content, mode or type
  std::uint32_t staged_deleted = 0;
  std::uint32_t unstaged_modified = 0; // content, mode or type
  std::uint32_t unstaged_deleted = 0;
  std::uint32_t intent_to_add = 0;     // `git add -N` entries
  std::uint32_t conflicted = 0;
};

}

namespace telar::git {

struct IndexEntry {
  std::uint32_t changed_seconds;
  std::uint32_t changed_nanoseconds;
  std::uint32_t modified_seconds;
  std::uint32_t modified_nanoseconds;
  std::uint32_t device;
  std::uint32_t inode;
  std::uint32_t mode;
  std::uint32_t user;
  std::uint32_t group;
  std::uint32_t size;
  ObjectId id;
  std::uint32_t path_offset;
  std::uint16_t path_length;
  std::uint16_t flags;
  std::uint16_t extended;

  inline unsigned stage() const noexcept { return (flags >> 12) & 3u; }
  inline bool assumeValid() const noexcept { return (flags & 0x8000u) != 0; }
  inline bool skipWorktree() const noexcept { return (extended & 0x4000u) != 0; }
  inline bool intentToAdd() const noexcept { return (extended & 0x2000u) != 0; }
};

// One cache-tree node of the TREE extension; `end` is the index past its subtree.
struct CacheTreeNode {
  std::string_view name;
  std::int32_t entries = -1;
  std::uint32_t end = 0;
  ObjectId id;
};

enum class IndexState : std::uint8_t {
  ready,
  unsupported,
  invalid
};

// git's verify_path, reduced to what keeps a path inside the work tree.
inline bool validIndexPath(std::string_view path) noexcept {
  if (path.empty() || path.front() == '/' || path.back() == '/') {
    return false;
  }
  std::size_t start = 0;
  for (std::size_t index = 0; index <= path.size(); ++index) {
    if (index != path.size() && path[index] != '/') {
      continue;
    }
    const auto component = path.substr(start, index - start);
    if (component.empty() || component == "." || component == ".." || telar::runtime::asciiEqualIgnoreCase(component, ".git")) {
      return false;
    }
    start = index + 1;
  }
  return true;
}

template <Allocator Memory>
class Index {
public:
  inline explicit Index(Memory &memory) noexcept
      : entries(AllocatorRef<IndexEntry, Memory>{memory}),
        tree(AllocatorRef<CacheTreeNode, Memory>{memory}),
        bytes_(AllocatorRef<char, Memory>{memory}),
        paths_(AllocatorRef<char, Memory>{memory}) {}

  // Parses <gitdir>/index again when its fingerprint changed. A missing
  // index is an empty one, as in a repository nobody added files to yet.
  inline IndexState load(int gitdir, ObjectFormat format, const Limits &limits) {
    const auto identity = fingerprintAt(gitdir, "index");
    if (loaded_ && identity == fingerprint && format == format_) {
      return state;
    }
    loaded_ = true;
    format_ = format;
    entries.clear();
    tree.clear();
    paths_.clear();
    fingerprint = identity;
    if (!identity.present) {
      state = IndexState::ready;
      return state;
    }
    Fingerprint read_identity;
    const auto read = readWhole(gitdir, "index", bytes_, limits.index_file, &read_identity);
    if (read != ReadStatus::ok) {
      state = read == ReadStatus::missing ? IndexState::ready : IndexState::invalid;
      fingerprint = read == ReadStatus::missing ? Fingerprint{} : identity;
      return state;
    }
    fingerprint = read_identity;
    state = parse(limits);
    if (state != IndexState::ready) {
      entries.clear();
      tree.clear();
    }
    return state;
  }

  inline std::string_view path(const IndexEntry &entry) const noexcept {
    return {paths_.data() + entry.path_offset, entry.path_length};
  }

  // The index's own modification time: entries modified at or after it are racy.
  inline std::int64_t timestamp() const noexcept { return fingerprint.modified_seconds; }

  Vector<IndexEntry, Memory> entries;
  Vector<CacheTreeNode, Memory> tree;
  Fingerprint fingerprint;
  IndexState state = IndexState::ready;

private:
  inline IndexState parse(const Limits &limits) {
    const auto hash_size = hashSize(format_);
    const auto data = asBytes(bytes_);
    if (data.size() < 12 + hash_size || std::memcmp(data.data(), "DIRC", 4) != 0) {
      return IndexState::invalid;
    }
    const auto version = loadBig32(data.data() + 4);
    const auto count = loadBig32(data.data() + 8);
    if (version < 2 || version > 4) {
      return IndexState::unsupported;
    }
    if (count > limits.index_entries) {
      return IndexState::invalid;
    }
    const auto end = data.size() - hash_size;
    const auto checksum = data.subspan(end);
    if (std::ranges::any_of(checksum, [](std::uint8_t byte) { return byte != 0; })) {
      const auto digest = hashBytes(format_, data.first(end));
      if (!std::ranges::equal(digest.view(), checksum)) {
        return IndexState::invalid;
      }
    }

    entries.reserve(count);
    std::size_t position = 12;
    std::size_t previous_offset = 0;
    std::size_t previous_length = 0;
    const auto fixed = 40 + hash_size + 2;
    for (std::uint32_t index = 0; index < count; ++index) {
      if (!fits(end, position, fixed)) {
        return IndexState::invalid;
      }
      const auto *record = data.data() + position;
      IndexEntry entry{};
      entry.changed_seconds = loadBig32(record);
      entry.changed_nanoseconds = loadBig32(record + 4);
      entry.modified_seconds = loadBig32(record + 8);
      entry.modified_nanoseconds = loadBig32(record + 12);
      entry.device = loadBig32(record + 16);
      entry.inode = loadBig32(record + 20);
      entry.mode = loadBig32(record + 24);
      entry.user = loadBig32(record + 28);
      entry.group = loadBig32(record + 32);
      entry.size = loadBig32(record + 36);
      entry.id = ObjectId::fromBytes({record + 40, hash_size});
      entry.flags = loadBig16(record + 40 + hash_size);
      std::size_t header = fixed;
      if ((entry.flags & 0x4000u) != 0) {
        if (version < 3 || !fits(end, position, fixed + 2)) {
          return IndexState::invalid;
        }
        entry.extended = loadBig16(record + fixed);
        if ((entry.extended & ~0x6000u) != 0) {
          return IndexState::unsupported;
        }
        header += 2;
      }
      switch (entry.mode) {
      case 0100644:
      case 0100755:
      case 0120000:
      case 0160000:
        break;
      case 0040000:
        return IndexState::unsupported; // a sparse index directory
      default:
        return IndexState::invalid;
      }

      const auto declared = std::size_t{entry.flags & 0xfffu};
      const auto name_start = position + header;
      std::string_view path;
      if (version == 4) {
        std::uint64_t strip = 0;
        auto cursor = name_start;
        if (!indexVarint(data.first(end), cursor, strip) || strip > previous_length) {
          return IndexState::invalid;
        }
        const auto terminator = bytes_.find('\0', cursor);
        if (terminator == String<Memory>::npos || terminator >= end) {
          return IndexState::invalid;
        }
        const auto kept = previous_length - static_cast<std::size_t>(strip);
        const auto suffix = std::string_view{bytes_}.substr(cursor, terminator - cursor);
        if (kept + suffix.size() > limits.path_length) {
          return IndexState::invalid;
        }
        const auto offset = paths_.size();
        if (offset + kept + suffix.size() > limits.index_file) {
          return IndexState::invalid;
        }
        // Reserved first, so the kept prefix is copied from a stable buffer.
        paths_.reserve(offset + kept + suffix.size());
        paths_.append(paths_.data() + previous_offset, kept);
        paths_.append(suffix);
        path = std::string_view{paths_}.substr(offset);
        entry.path_offset = static_cast<std::uint32_t>(offset);
        position = terminator + 1;
      } else {
        const auto terminator = bytes_.find('\0', name_start);
        if (terminator == String<Memory>::npos || terminator >= end) {
          return IndexState::invalid;
        }
        const auto length = terminator - name_start;
        const auto padded = (header + length + 8) & ~std::size_t{7};
        if (length > limits.path_length || !fits(end, position, padded)) {
          return IndexState::invalid;
        }
        entry.path_offset = static_cast<std::uint32_t>(paths_.size());
        paths_.append(std::string_view{bytes_}.substr(name_start, length));
        path = std::string_view{paths_}.substr(entry.path_offset);
        position += padded;
      }
      if (path.empty()) {
        return IndexState::unsupported; // a split index writes replaced entries without names
      }
      if (paths_.size() > std::numeric_limits<std::uint32_t>::max() || (declared < 0xfffu && declared != path.size()) || !validIndexPath(path)) {
        return IndexState::invalid;
      }
      entry.path_length = static_cast<std::uint16_t>(path.size());
      if (!entries.empty()) {
        const auto &previous = entries.back();
        const auto order = this->path(previous).compare(path);
        if (order > 0 || (order == 0 && previous.stage() >= entry.stage())) {
          return IndexState::invalid;
        }
      }
      previous_offset = entry.path_offset;
      previous_length = path.size();
      entries.push_back(entry);
    }

    while (position < end) {
      if (!fits(end, position, 8)) {
        return IndexState::invalid;
      }
      const auto signature = std::string_view{bytes_}.substr(position, 4);
      const auto size = loadBig32(data.data() + position + 4);
      position += 8;
      if (!fits(end, position, size)) {
        return IndexState::invalid;
      }
      if (signature == "TREE") {
        std::size_t cursor = position;
        if (!parseTree(data.first(position + size), cursor, 0, limits) || cursor != position + size) {
          tree.clear();
        }
      } else if (signature[0] < 'A' || signature[0] > 'Z') {
        return IndexState::unsupported; // a required extension: split index, sparse directories
      }
      position += size;
    }
    return IndexState::ready;
  }

  // The prefix-compression length of index v4, encoded like OFS_DELTA offsets.
  inline static bool indexVarint(std::span<const std::uint8_t> data, std::size_t &position, std::uint64_t &value) noexcept {
    if (position >= data.size()) {
      return false;
    }
    auto byte = data[position++];
    value = byte & 0x7fu;
    while ((byte & 0x80) != 0) {
      if (position >= data.size() || value >= (std::uint64_t{1} << 56)) {
        return false;
      }
      byte = data[position++];
      value = ((value + 1) << 7) | (byte & 0x7fu);
    }
    return true;
  }

  inline bool parseTree(std::span<const std::uint8_t> data, std::size_t &position, std::size_t depth, const Limits &limits) {
    if (depth > limits.path_depth || tree.size() >= entries.size() + 1 + limits.path_depth) {
      return false;
    }
    const auto text = asText(data);
    const auto name_end = text.find('\0', position);
    if (name_end == std::string_view::npos) {
      return false;
    }
    CacheTreeNode node;
    node.name = std::string_view{bytes_}.substr(position, name_end - position);
    const auto line_end = text.find('\n', name_end + 1);
    if (line_end == std::string_view::npos) {
      return false;
    }
    const auto line = text.substr(name_end + 1, line_end - name_end - 1);
    const auto space = line.find(' ');
    if (space == std::string_view::npos) {
      return false;
    }
    std::int32_t entry_count = 0;
    std::uint32_t subtrees = 0;
    const auto first = line.substr(0, space);
    const auto second = line.substr(space + 1);
    if (std::from_chars(first.data(), first.data() + first.size(), entry_count).ptr != first.data() + first.size() ||
        std::from_chars(second.data(), second.data() + second.size(), subtrees).ptr != second.data() + second.size() || first.empty() || second.empty()) {
      return false;
    }
    position = line_end + 1;
    node.entries = entry_count;
    if (entry_count >= 0) {
      const auto hash_size = hashSize(format_);
      if (!fits(data.size(), position, hash_size)) {
        return false;
      }
      node.id = ObjectId::fromBytes(data.subspan(position, hash_size));
      position += hash_size;
    }
    const auto index = tree.size();
    tree.push_back(node);
    for (std::uint32_t child = 0; child < subtrees; ++child) {
      if (!parseTree(data, position, depth + 1, limits)) {
        return false;
      }
    }
    tree[index].end = static_cast<std::uint32_t>(tree.size());
    return true;
  }

  String<Memory> bytes_;
  String<Memory> paths_;
  ObjectFormat format_ = ObjectFormat::sha1;
  bool loaded_ = false;
};

inline constexpr std::uint32_t no_cache_tree = std::numeric_limits<std::uint32_t>::max();

// The cache-tree child of `parent` named `name`, if the extension has one.
inline std::uint32_t cacheTreeChild(std::span<const CacheTreeNode> tree, std::uint32_t parent, std::string_view name) noexcept {
  if (parent == no_cache_tree) {
    return no_cache_tree;
  }
  for (auto child = parent + 1; child < tree[parent].end; child = tree[child].end) {
    if (tree[child].name == name) {
      return child;
    }
  }
  return no_cache_tree;
}

// Compares HEAD's tree with the index, recursing only into trees whose
// cache-tree entry is missing, invalid or different.
template <Allocator Memory>
class StagedComparison {
public:
  inline explicit StagedComparison(Memory &memory) noexcept
      : trees_(AllocatorRef<String<Memory>, Memory>{memory}),
        memory_(memory) {}

  // `tree` is HEAD's root tree, or nullopt on an unborn branch.
  inline bool compare(ObjectDatabase<Memory> &objects, const Index<Memory> &index, std::optional<ObjectId> tree, const Limits &limits, ChangeCounts &counts) {
    objects_ = &objects;
    index_ = &index;
    limits_ = &limits;
    counts_ = &counts;
    trees_read_ = 0;
    while (trees_.size() < limits.path_depth + 2) {
      trees_.emplace_back(AllocatorRef<char, Memory>{memory_});
    }
    const auto end = static_cast<std::uint32_t>(index.entries.size());
    if (!tree) {
      addRange(0, end);
      return true;
    }
    const auto complete = compareTree(*tree, 0, 0, end, index.tree.empty() ? no_cache_tree : 0, 0);
    constexpr std::size_t retained = 256 << 10;
    for (auto &buffer : trees_) {
      if (buffer.capacity() > retained) {
        buffer.clear();
        buffer.shrink_to_fit();
      }
    }
    return complete;
  }

  std::uint64_t trees_read = 0;

private:
  // One tree buffer per depth, allocated before the walk: a reader at one
  // depth keeps viewing its buffer while deeper trees are read.
  inline String<Memory> &buffer(std::size_t depth) noexcept { return trees_[depth]; }

  inline bool readTree(const ObjectId &id, std::size_t depth) {
    if (++trees_read_ > limits_->tree_objects || depth > limits_->path_depth) {
      return false;
    }
    ++trees_read;
    ObjectType type = ObjectType::none;
    return objects_->read(id, type, buffer(depth)) == Lookup::found && type == ObjectType::tree;
  }

  inline std::string_view relative(std::uint32_t entry, std::size_t prefix) const noexcept {
    return index_->path(index_->entries[entry]).substr(prefix);
  }

  // The index entries [begin, end) are new to HEAD.
  inline void addRange(std::uint32_t begin, std::uint32_t end) noexcept {
    for (auto entry = begin; entry < end; ++entry) {
      const auto &item = index_->entries[entry];
      if (item.stage() == 0 && !item.intentToAdd()) {
        ++counts_->staged_added;
      }
    }
  }

  // Every file below tree `id` left the index.
  inline bool deleteTree(const ObjectId &id, std::size_t depth) {
    if (!readTree(id, depth)) {
      return false;
    }
    TreeReader reader{buffer(depth), objects_->format()};
    TreeEntry entry;
    while (reader.next(entry)) {
      if (entry.directory()) {
        const auto child = entry.id;
        if (!deleteTree(child, depth + 1)) {
          return false;
        }
      } else {
        ++counts_->staged_deleted;
      }
    }
    return !reader.failed();
  }

  inline bool compareTree(const ObjectId &id, std::size_t prefix, std::uint32_t begin, std::uint32_t end, std::uint32_t cache, std::size_t depth) {
    if (cache != no_cache_tree) {
      const auto &node = index_->tree[cache];
      if (node.entries >= 0 && node.id == id) {
        return true;
      }
    }
    if (!readTree(id, depth)) {
      return false;
    }
    TreeReader reader{buffer(depth), objects_->format()};
    TreeEntry entry;
    auto current = begin;
    while (reader.next(entry)) {
      const auto name = entry.name;
      const auto directory = entry.directory();
      const auto tree_mode = entry.mode;
      const auto tree_id = entry.id;
      int order = 1;
      while (current < end) {
        const auto rest = relative(current, prefix);
        const auto slash = rest.find('/');
        const auto component = rest.substr(0, slash);
        const bool nested = slash != std::string_view::npos;
        order = compareTreeNames(component, nested, name, directory);
        if (order >= 0) {
          break;
        }
        const auto group_end = nested ? groupEnd(current, end, prefix, component) : pathEnd(current, end);
        addRange(current, group_end);
        current = group_end;
      }
      if (current < end && order == 0) {
        if (directory) {
          const auto group_end = groupEnd(current, end, prefix, name);
          const auto child = cacheTreeChild(index_->tree, cache, name);
          if (!compareTree(tree_id, prefix + name.size() + 1, current, group_end, child, depth + 1)) {
            return false;
          }
          current = group_end;
        } else {
          const auto path_end = pathEnd(current, end);
          const auto &item = index_->entries[current];
          if (path_end - current == 1 && item.stage() == 0 && !item.intentToAdd() && (item.mode != tree_mode || item.id != tree_id)) {
            ++counts_->staged_modified;
          }
          current = path_end;
        }
        continue;
      }
      if (directory) {
        if (!deleteTree(tree_id, depth + 1)) {
          return false;
        }
      } else {
        ++counts_->staged_deleted;
      }
    }
    if (reader.failed()) {
      return false;
    }
    addRange(current, end);
    return true;
  }

  // Past the stages of the entry at `begin`.
  inline std::uint32_t pathEnd(std::uint32_t begin, std::uint32_t end) const noexcept {
    const auto path = index_->path(index_->entries[begin]);
    auto current = begin + 1;
    while (current < end && index_->path(index_->entries[current]) == path) {
      ++current;
    }
    return current;
  }

  // Past the entries below directory `component` of the current prefix.
  inline std::uint32_t groupEnd(std::uint32_t begin, std::uint32_t end, std::size_t prefix, std::string_view component) const noexcept {
    auto current = begin;
    while (current < end) {
      const auto rest = relative(current, prefix);
      if (rest.size() <= component.size() || rest[component.size()] != '/' || !rest.starts_with(component)) {
        break;
      }
      ++current;
    }
    return current;
  }

  Vector<String<Memory>, Memory> trees_;
  Memory &memory_;
  ObjectDatabase<Memory> *objects_ = nullptr;
  const Index<Memory> *index_ = nullptr;
  const Limits *limits_ = nullptr;
  ChangeCounts *counts_ = nullptr;
  std::size_t trees_read_ = 0;
};

// The verdict of a racily clean entry whose content was hashed, kept while
// neither the index nor the file changes.
struct Verified {
  Fingerprint file;
  bool modified = false;
  bool valid = false;
};

// Compares each index entry with the working tree.
template <Allocator Memory>
class UnstagedComparison {
public:
  inline explicit UnstagedComparison(Memory &memory) noexcept
      : verified_(AllocatorRef<Verified, Memory>{memory}),
        buffer_(AllocatorRef<char, Memory>{memory}) {}

  struct Options {
    ObjectFormat format = ObjectFormat::sha1;
    bool file_mode = true;
    bool symlinks = true;
  };

  inline bool compare(int worktree, const Index<Memory> &index, Options options, const Limits &limits, ChangeCounts &counts) {
    const auto complete = scan(worktree, index, options, limits, counts);
    directories_.reset(-1);
    return complete;
  }

  std::uint64_t entries_checked = 0;
  std::uint64_t files_hashed = 0;
  std::uint64_t bytes_hashed = 0;

private:
  inline bool scan(int worktree, const Index<Memory> &index, Options options, const Limits &limits, ChangeCounts &counts) {
    options_ = options;
    limits_ = &limits;
    hashed_bytes_ = 0;
    if (index.fingerprint != verified_index_) {
      verified_.clear();
      verified_index_ = index.fingerprint;
    }
    if (verified_.size() != index.entries.size()) {
      verified_.assign(index.entries.size(), Verified{});
    }
    directories_.reset(worktree);
    const auto &entries = index.entries;
    for (std::size_t current = 0; current < entries.size(); ++current) {
      const auto &entry = entries[current];
      const auto path = index.path(entry);
      if (entry.stage() != 0) {
        ++counts.conflicted;
        while (current + 1 < entries.size() && index.path(entries[current + 1]) == path) {
          ++current;
        }
        continue;
      }
      if (entry.intentToAdd()) {
        ++counts.intent_to_add;
        continue;
      }
      if (entry.skipWorktree() || entry.assumeValid() || (entry.mode & mode_type_mask) == mode_gitlink) {
        continue;
      }
      ++entries_checked;
      const auto slash = path.rfind('/');
      const auto name = slash == std::string_view::npos ? path : path.substr(slash + 1);
      const auto directory = slash == std::string_view::npos ? std::string_view{} : path.substr(0, slash);
      bool missing = false;
      const auto parent = directories_.open(directory, limits.path_depth, missing);
      if (missing) {
        ++counts.unstaged_deleted;
        continue;
      }
      if (parent < 0) {
        return false;
      }
      PathName file;
      if (!file.assign({name})) {
        return false;
      }
      struct stat status{};
      if (::fstatat(parent, file.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT || errno == ENOTDIR) {
          ++counts.unstaged_deleted;
          continue;
        }
        return false;
      }
      switch (examine(entry, index.timestamp(), parent, file.c_str(), status, verified_[current])) {
      case Verdict::clean:
        break;
      case Verdict::modified:
        ++counts.unstaged_modified;
        break;
      case Verdict::deleted:
        ++counts.unstaged_deleted;
        break;
      case Verdict::unknown:
        return false;
      }
    }
    return true;
  }

  enum class Verdict : std::uint8_t {
    clean,
    modified,
    deleted,
    unknown
  };

  // Directory descriptors of the current entry's parent path, reused while
  // consecutive index entries share a prefix.
  class Directories {
  public:
    inline void reset(int root) noexcept {
      root_ = root;
      for (std::size_t level = 0; level < depth_; ++level) {
        descriptors_[level].reset();
      }
      depth_ = 0;
      missing_ = no_missing;
    }

    // The descriptor of `directory`, `missing` if a component is absent, a
    // symlink or not a directory, or -1 on any other failure.
    inline int open(std::string_view directory, std::size_t maximum_depth, bool &missing) noexcept {
      if (directory.size() > path_.size()) {
        return -1;
      }
      std::size_t keep = 0;
      while (keep < depth_) {
        const auto end = ends_[keep];
        if (directory.size() < end || std::memcmp(directory.data(), path_.data(), end) != 0 || (directory.size() > end && directory[end] != '/')) {
          break;
        }
        ++keep;
      }
      for (auto level = keep; level < depth_; ++level) {
        descriptors_[level].reset();
      }
      depth_ = keep;
      if (missing_ != no_missing && missing_ >= depth_) {
        missing_ = no_missing;
      }
      // The kept prefix is already in path_; the rest, from its separator on, is copied.
      const auto copied = depth_ == 0 ? std::size_t{0} : ends_[depth_ - 1];
      std::copy(directory.begin() + static_cast<std::ptrdiff_t>(copied), directory.end(), path_.begin() + static_cast<std::ptrdiff_t>(copied));
      auto start = depth_ == 0 ? std::size_t{0} : copied + 1;
      while (start < directory.size()) {
        if (depth_ >= maximum_depth || depth_ >= descriptors_.size()) {
          return -1;
        }
        const auto slash = directory.find('/', start);
        const auto stop = slash == std::string_view::npos ? directory.size() : slash;
        ends_[depth_] = stop;
        if (missing_ == no_missing) {
          PathName component;
          if (!component.assign({directory.substr(start, stop - start)})) {
            return -1;
          }
          const auto parent = depth_ == 0 ? root_ : descriptors_[depth_ - 1].get();
          descriptors_[depth_].reset(::openat(parent, component.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC));
          if (!descriptors_[depth_]) {
            if (errno != ENOENT && errno != ENOTDIR && errno != ELOOP) {
              ++depth_;
              return -1;
            }
            missing_ = depth_;
          }
        }
        ++depth_;
        start = stop + 1;
      }
      if (missing_ != no_missing) {
        missing = true;
        return -1;
      }
      return depth_ == 0 ? root_ : descriptors_[depth_ - 1].get();
    }

  private:
    static constexpr std::size_t no_missing = std::numeric_limits<std::size_t>::max();
    int root_ = -1;
    std::size_t depth_ = 0;
    std::size_t missing_ = no_missing;
    std::array<FileDescriptor, 128> descriptors_;
    std::array<std::size_t, 128> ends_{};
    std::array<char, 4096> path_;
  };

  // git's ce_match_stat, then the content when stat data cannot decide.
  inline Verdict examine(const IndexEntry &entry, std::int64_t index_time, int parent, const char *name, const struct stat &status, Verified &verified) {
    const auto index_type = entry.mode & mode_type_mask;
    const auto type = static_cast<std::uint32_t>(status.st_mode) & S_IFMT;
    if (type == S_IFDIR) {
      return Verdict::deleted;
    }
    if (index_type == mode_regular) {
      if (type != S_IFREG) {
        return Verdict::modified;
      }
      if (options_.file_mode && ((entry.mode & 0100u) != 0) != ((status.st_mode & S_IXUSR) != 0)) {
        return Verdict::modified;
      }
    } else if (index_type == mode_symlink) {
      if (type != S_IFLNK && !(type == S_IFREG && !options_.symlinks)) {
        return Verdict::modified;
      }
    } else {
      return Verdict::unknown;
    }

    const auto file = fingerprintOf(status);
    const bool stat_clean = entry.size == static_cast<std::uint32_t>(status.st_size) && entry.size != 0 &&
                            entry.modified_seconds == static_cast<std::uint32_t>(file.modified_seconds) &&
                            entry.modified_nanoseconds == static_cast<std::uint32_t>(file.modified_nanoseconds) &&
                            entry.changed_seconds == static_cast<std::uint32_t>(file.changed_seconds) &&
                            entry.changed_nanoseconds == static_cast<std::uint32_t>(file.changed_nanoseconds) &&
                            entry.inode == static_cast<std::uint32_t>(status.st_ino) &&
                            entry.user == static_cast<std::uint32_t>(status.st_uid) &&
                            entry.group == static_cast<std::uint32_t>(status.st_gid);
    // Racy as git's is_racy_timestamp: modified within the second the index was written, or later.
    const bool racy = index_time <= static_cast<std::int64_t>(entry.modified_seconds);
    if (stat_clean && !racy) {
      return Verdict::clean;
    }
    if (entry.size == 0 && status.st_size == 0 && entry.id == emptyBlob(options_.format)) {
      return Verdict::clean;
    }
    if (static_cast<std::uint32_t>(status.st_size) != entry.size && entry.size != 0) {
      return Verdict::modified;
    }
    if (verified.valid && verified.file == file) {
      return verified.modified ? Verdict::modified : Verdict::clean;
    }
    const auto started = currentSeconds();
    std::optional<ObjectId> content = type == S_IFLNK ? hashLink(parent, name, status) : hashFile(parent, name, status);
    if (!content) {
      return Verdict::unknown;
    }
    const bool modified = *content != entry.id;
    // A file modified in the second it was hashed could change again unseen.
    verified = {file, modified, file.modified_seconds < started && file.changed_seconds < started};
    return modified ? Verdict::modified : Verdict::clean;
  }

  inline static std::int64_t currentSeconds() noexcept {
    timespec now{};
    ::clock_gettime(CLOCK_REALTIME, &now);
    return static_cast<std::int64_t>(now.tv_sec);
  }

  inline std::optional<ObjectId> hashLink(int parent, const char *name, const struct stat &status) {
    std::array<char, 4096> target;
    const auto length = ::readlinkat(parent, name, target.data(), target.size());
    if (length < 0 || static_cast<std::size_t>(length) >= target.size() || length != status.st_size) {
      return std::nullopt;
    }
    ++files_hashed;
    Hasher hasher{options_.format};
    hashObjectHeader(hasher, "blob", static_cast<std::uint64_t>(length));
    hasher.update(asBytes({target.data(), static_cast<std::size_t>(length)}));
    return hasher.finish();
  }

  inline std::optional<ObjectId> hashFile(int parent, const char *name, const struct stat &expected) {
    const auto size = static_cast<std::uint64_t>(expected.st_size);
    if (size > limits_->hashed_bytes - hashed_bytes_) {
      return std::nullopt;
    }
    FileDescriptor file;
    struct stat status{};
    if (openRegular(parent, name, file, status) != ReadStatus::ok || !sameFile(status, expected) || status.st_size != expected.st_size) {
      return std::nullopt;
    }
    ++files_hashed;
    hashed_bytes_ += size;
    bytes_hashed += size;
    constexpr std::size_t chunk = 64 << 10;
    if (buffer_.size() < chunk) {
      resizeForOverwrite(buffer_, chunk);
    }
    Hasher hasher{options_.format};
    hashObjectHeader(hasher, "blob", size);
    std::uint64_t remaining = size;
    while (remaining != 0) {
      const auto count = ::read(file.get(), buffer_.data(), static_cast<std::size_t>(std::min<std::uint64_t>(remaining, chunk)));
      if (count < 0 && errno == EINTR) {
        continue;
      }
      if (count <= 0) {
        return std::nullopt;
      }
      hasher.update(asBytes({buffer_.data(), static_cast<std::size_t>(count)}));
      remaining -= static_cast<std::uint64_t>(count);
    }
    return hasher.finish();
  }

  Options options_;
  const Limits *limits_ = nullptr;
  std::uint64_t hashed_bytes_ = 0;
  Fingerprint verified_index_;
  Vector<Verified, Memory> verified_;
  String<Memory> buffer_;
  Directories directories_;
};

}
