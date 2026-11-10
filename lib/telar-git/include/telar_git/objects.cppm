module;
#include <cerrno>
#include <climits>
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

export module telar.git:objects;

import std;
import telar.base.memory;
import telar.platform;
import telar.platform.primitives;
import :format;

// The object database: loose objects, packfiles with their v2 indexes and
// delta chains, and the commit-graph. Reads use pread on descriptors rather
// than mmap: a file truncated under a mapping would raise SIGBUS in the caller.

namespace telar::git {

enum class ObjectType : std::uint8_t {
  none = 0,
  commit = 1,
  tree = 2,
  blob = 3,
  tag = 4
};

enum class Lookup : std::uint8_t {
  found,
  missing,
  invalid
};

// Routes zlib's allocations to the reader's allocator. zlib frees without a
// size, which CAllocationBlocks records in front of each block.
template <Allocator Memory>
class Inflater {
public:
  inline explicit Inflater(Memory &memory) noexcept : blocks_(memory) {}

  inline ~Inflater() {
    if (ready_) {
      ::inflateEnd(&stream_);
    }
  }

  Inflater(const Inflater &) = delete;
  Inflater &operator=(const Inflater &) = delete;

  // Starts a new stream, keeping zlib's window allocated between objects.
  inline bool start() noexcept {
    if (!ready_) {
      stream_ = {};
      stream_.zalloc = &allocate;
      stream_.zfree = &release;
      stream_.opaque = &blocks_;
      ready_ = ::inflateInit(&stream_) == Z_OK;
      return ready_;
    }
    stream_.next_in = nullptr;
    stream_.avail_in = 0;
    return ::inflateReset(&stream_) == Z_OK;
  }

  inline z_stream &stream() noexcept { return stream_; }

private:
  inline static voidpf allocate(voidpf opaque, uInt items, uInt size) noexcept {
    return static_cast<CAllocationBlocks<Memory> *>(opaque)->allocateZeroed(items, size);
  }

  inline static void release(voidpf opaque, voidpf address) noexcept {
    static_cast<CAllocationBlocks<Memory> *>(opaque)->release(address);
  }

  CAllocationBlocks<Memory> blocks_;
  z_stream stream_{};
  bool ready_ = false;
};

enum class Inflated : std::uint8_t {
  full,
  ended,
  failed
};

// Compressed bytes held in memory, handed to zlib once.
struct MemorySource {
  std::span<const std::uint8_t> bytes;

  inline std::span<const std::uint8_t> next() noexcept { return std::exchange(bytes, {}); }
};

// Compressed bytes read from a packfile in chunks, up to its trailer.
struct PackSource {
  int descriptor;
  std::uint64_t offset;
  std::uint64_t end;
  std::span<std::uint8_t> buffer;

  inline std::span<const std::uint8_t> next() noexcept {
    if (offset >= end) {
      return {};
    }
    const auto count = static_cast<std::size_t>(std::min<std::uint64_t>(buffer.size(), end - offset));
    if (!readAt(descriptor, buffer.data(), count, offset)) {
      return {};
    }
    offset += count;
    return buffer.first(count);
  }
};

// Continues `stream` until `output` is full or the stream ends.
template <typename Source>
Inflated pump(z_stream &stream, Source &source, std::span<std::uint8_t> output) noexcept {
  if (output.size() > UINT_MAX) {
    return Inflated::failed;
  }
  stream.next_out = output.data();
  stream.avail_out = static_cast<uInt>(output.size());
  for (;;) {
    if (stream.avail_in == 0) {
      const auto chunk = source.next();
      if (chunk.empty()) {
        return Inflated::failed;
      }
      stream.next_in = const_cast<Bytef *>(chunk.data());
      stream.avail_in = static_cast<uInt>(chunk.size());
    }
    const auto result = ::inflate(&stream, Z_NO_FLUSH);
    if (result == Z_STREAM_END) {
      return Inflated::ended;
    }
    if (result != Z_OK && result != Z_BUF_ERROR) {
      return Inflated::failed;
    }
    if (stream.avail_out == 0) {
      return Inflated::full;
    }
    if (result == Z_BUF_ERROR && stream.avail_in != 0) {
      return Inflated::failed;
    }
  }
}

// After `output` filled, the stream must end without producing another byte.
template <typename Source>
bool endsHere(z_stream &stream, Source &source) noexcept {
  std::array<std::uint8_t, 1> sink;
  return pump(stream, source, sink) == Inflated::ended && stream.avail_out == sink.size();
}

// Inflates the first output.size() bytes of a stream at least that long.
template <typename Source>
bool inflatePrefix(z_stream &stream, Source &source, std::span<std::uint8_t> output) noexcept {
  if (output.empty()) {
    return true;
  }
  const auto result = pump(stream, source, output);
  return result == Inflated::full || (result == Inflated::ended && stream.avail_out == 0);
}

// Inflates the whole stream, which must hold exactly output.size() bytes.
template <typename Source>
bool inflateExactly(z_stream &stream, Source &source, std::span<std::uint8_t> output) noexcept {
  if (output.empty()) {
    return endsHere(stream, source);
  }
  switch (pump(stream, source, output)) {
  case Inflated::ended:
    return stream.avail_out == 0;
  case Inflated::full:
    return endsHere(stream, source);
  case Inflated::failed:
    return false;
  }
  return false;
}

inline std::span<std::uint8_t> writable(auto &string) noexcept {
  return {reinterpret_cast<std::uint8_t *>(string.data()), string.size()};
}

// Sizes `string` without zeroing it; the inflater overwrites every byte.
template <Allocator Memory>
void resizeForOverwrite(String<Memory> &string, std::size_t size) {
  string.resize_and_overwrite(size, [](char *, std::size_t count) { return count; });
}

// Little-endian base-128 size of a delta header.
inline bool deltaSize(std::span<const std::uint8_t> delta, std::size_t &position, std::uint64_t &value) noexcept {
  value = 0;
  for (unsigned shift = 0; shift < 64; shift += 7) {
    if (position >= delta.size()) {
      return false;
    }
    const auto byte = delta[position++];
    value |= std::uint64_t{byte & 0x7fu} << shift;
    if ((byte & 0x80) == 0) {
      return true;
    }
  }
  return false;
}

// Applies a git delta to `base`. Every copy is checked against both buffers.
template <Allocator Memory>
bool applyDelta(std::span<const std::uint8_t> base, std::span<const std::uint8_t> delta, String<Memory> &output, std::size_t limit) {
  std::size_t position = 0;
  std::uint64_t source_size = 0;
  std::uint64_t target_size = 0;
  if (!deltaSize(delta, position, source_size) || !deltaSize(delta, position, target_size) || source_size != base.size() || target_size > limit) {
    return false;
  }
  resizeForOverwrite(output, static_cast<std::size_t>(target_size));
  auto *target = reinterpret_cast<std::uint8_t *>(output.data());
  std::size_t written = 0;
  while (position < delta.size()) {
    const auto operation = delta[position++];
    if ((operation & 0x80) != 0) {
      std::uint64_t offset = 0;
      std::uint64_t size = 0;
      for (unsigned bit = 0; bit < 7; ++bit) {
        if ((operation & (1u << bit)) == 0) {
          continue;
        }
        if (position >= delta.size()) {
          return false;
        }
        const auto byte = std::uint64_t{delta[position++]};
        if (bit < 4) {
          offset |= byte << (8 * bit);
        } else {
          size |= byte << (8 * (bit - 4));
        }
      }
      if (size == 0) {
        size = 0x10000;
      }
      if (!fits(base.size(), offset, size) || !fits(target_size, written, size)) {
        return false;
      }
      std::memcpy(target + written, base.data() + offset, static_cast<std::size_t>(size));
      written += static_cast<std::size_t>(size);
    } else if (operation != 0) {
      if (!fits(delta.size(), position, operation) || !fits(target_size, written, operation)) {
        return false;
      }
      std::memcpy(target + written, delta.data() + position, operation);
      position += operation;
      written += operation;
    } else {
      return false;
    }
  }
  return written == target_size;
}

struct CommitHeader {
  ObjectId tree;
  std::int64_t time = 0;
};

inline std::optional<ObjectId> headerId(std::string_view &content, std::string_view label, ObjectFormat format) noexcept {
  const auto digits = 2 * hashSize(format);
  if (!content.starts_with(label) || content.size() < label.size() + digits + 1 || content[label.size() + digits] != '\n') {
    return std::nullopt;
  }
  const auto id = ObjectId::fromHex(content.substr(label.size(), digits), format);
  if (id) {
    content.remove_prefix(label.size() + digits + 1);
  }
  return id;
}

// Parses the header of a commit, or of its first bytes: the tree, the
// parents (appended to `parents`) and the committer time.
template <Allocator Memory>
bool parseCommit(std::string_view content, ObjectFormat format, std::size_t maximum_parents, CommitHeader &header, Vector<ObjectId, Memory> &parents) {
  const auto tree = headerId(content, "tree ", format);
  if (!tree) {
    return false;
  }
  header.tree = *tree;
  const auto first = parents.size();
  while (content.starts_with("parent ")) {
    const auto parent = headerId(content, "parent ", format);
    if (!parent || parents.size() - first >= maximum_parents) {
      return false;
    }
    parents.push_back(*parent);
  }
  while (!content.empty() && content.front() != '\n') {
    const auto end = content.find('\n');
    if (end == std::string_view::npos) {
      return false;
    }
    const auto line = content.substr(0, end);
    content.remove_prefix(end + 1);
    if (!line.starts_with("committer ")) {
      continue;
    }
    const auto email_end = line.rfind('>');
    if (email_end == std::string_view::npos) {
      return false;
    }
    auto rest = line.substr(email_end + 1);
    while (rest.starts_with(' ')) {
      rest.remove_prefix(1);
    }
    std::uint64_t seconds = 0;
    const auto parsed = std::from_chars(rest.data(), rest.data() + rest.size(), seconds);
    if (parsed.ec != std::errc{}) {
      return false;
    }
    header.time = static_cast<std::int64_t>(std::min<std::uint64_t>(seconds, std::numeric_limits<std::int64_t>::max()));
    return true;
  }
  return false;
}

inline constexpr std::uint32_t mode_type_mask = 0170000;
inline constexpr std::uint32_t mode_directory = 0040000;
inline constexpr std::uint32_t mode_regular = 0100000;
inline constexpr std::uint32_t mode_symlink = 0120000;
inline constexpr std::uint32_t mode_gitlink = 0160000;

struct TreeEntry {
  std::uint32_t mode = 0;
  std::string_view name;
  ObjectId id;

  inline bool directory() const noexcept { return (mode & mode_type_mask) == mode_directory; }
};

// git's tree order: a directory sorts as if its name ended with '/'.
inline int compareTreeNames(std::string_view left, bool left_directory, std::string_view right, bool right_directory) noexcept {
  const auto common = std::min(left.size(), right.size());
  if (const auto order = left.substr(0, common).compare(right.substr(0, common)); order != 0) {
    return order;
  }
  const auto left_next = left.size() > common ? static_cast<unsigned char>(left[common]) : left_directory ? '/' : 0;
  const auto right_next = right.size() > common ? static_cast<unsigned char>(right[common]) : right_directory ? '/' : 0;
  return left_next < right_next ? -1 : left_next > right_next ? 1 : 0;
}

// Iterates the entries of a tree object, refusing malformed or unordered ones.
class TreeReader {
public:
  inline TreeReader(std::string_view content, ObjectFormat format) noexcept : rest_(content), hash_size_(hashSize(format)) {}

  // False at the end, or when `failed()` because the tree is malformed.
  inline bool next(TreeEntry &entry) noexcept {
    if (rest_.empty() || failed_) {
      return false;
    }
    std::uint32_t mode = 0;
    std::size_t index = 0;
    while (index < rest_.size() && index < 7 && rest_[index] >= '0' && rest_[index] <= '7') {
      mode = mode << 3 | static_cast<std::uint32_t>(rest_[index] - '0');
      ++index;
    }
    if (index == 0 || index >= rest_.size() || rest_[index] != ' ') {
      return fail();
    }
    const auto name_start = index + 1;
    const auto name_end = rest_.find('\0', name_start);
    if (name_end == std::string_view::npos || name_end == name_start || !fits(rest_.size(), name_end + 1, hash_size_)) {
      return fail();
    }
    const auto name = rest_.substr(name_start, name_end - name_start);
    if (name == "." || name == ".." || name.contains('/')) {
      return fail();
    }
    switch (mode) {
    case 040000:
    case 0100644:
    case 0100755:
    case 0100664:
    case 0120000:
    case 0160000:
      break;
    default:
      return fail();
    }
    entry.mode = mode == 0100664 ? 0100644 : mode;
    entry.name = name;
    entry.id = ObjectId::fromBytes(asBytes(rest_.substr(name_end + 1, hash_size_)));
    if (have_previous_ && compareTreeNames(previous_, previous_directory_, name, entry.directory()) >= 0) {
      return fail();
    }
    previous_ = name;
    previous_directory_ = entry.directory();
    have_previous_ = true;
    rest_.remove_prefix(name_end + 1 + hash_size_);
    return true;
  }

  inline bool failed() const noexcept { return failed_; }

private:
  inline bool fail() noexcept {
    failed_ = true;
    return false;
  }

  std::string_view rest_;
  std::size_t hash_size_;
  std::string_view previous_;
  bool previous_directory_ = false;
  bool have_previous_ = false;
  bool failed_ = false;
};

struct Pack {
  FileDescriptor index;
  FileDescriptor data;
  std::uint64_t index_size = 0;
  std::uint64_t data_size = 0;
  std::uint64_t large_offsets = 0;
  std::uint32_t count = 0;
  std::array<std::uint32_t, 256> fanout{};
};

inline constexpr std::size_t pack_index_header = 8 + 256 * 4;

template <Allocator Memory>
class ObjectDatabase {
public:
  inline explicit ObjectDatabase(Memory &memory) noexcept
      : inflater_(memory),
        packs_(AllocatorRef<Pack, Memory>{memory}),
        chain_(AllocatorRef<Link, Memory>{memory}),
        compressed_(AllocatorRef<char, Memory>{memory}),
        base_(AllocatorRef<char, Memory>{memory}),
        target_(AllocatorRef<char, Memory>{memory}),
        delta_(AllocatorRef<char, Memory>{memory}) {}

  // Opens `<common>/objects` and refreshes the pack list when objects/pack changed.
  inline bool open(int common, ObjectFormat format, const Limits &limits) {
    limits_ = &limits;
    inflated_ = 0;
    if (format != format_ || !objects_) {
      packs_.clear();
      packs_identity_ = {};
    }
    format_ = format;
    objects_ = openDirectory(common, "objects");
    if (!objects_) {
      packs_.clear();
      return false;
    }
    refreshPacks();
    return true;
  }

  inline void close() noexcept {
    objects_.reset();
    packs_.clear();
    packs_identity_ = {};
  }

  inline int objects() const noexcept { return objects_.get(); }

  inline ObjectFormat format() const noexcept { return format_; }

  // Reads object `id` into `output`. With a non-zero `prefix`, only its first
  // `prefix` bytes are kept, and an undeltified object is inflated no further.
  inline Lookup read(const ObjectId &id, ObjectType &type, String<Memory> &output, std::size_t prefix = 0) {
    std::uint32_t pack = 0;
    std::uint64_t offset = 0;
    const auto located = locate(id, pack, offset);
    if (located != Lookup::found) {
      return located;
    }
    ++objects_read;
    if (pack == loose) {
      return readLoose(id, type, output, prefix);
    }
    return readPacked(pack, offset, type, output, prefix);
  }

  // Releases buffers that one large object grew, so the cache stays small.
  inline void trim() {
    constexpr std::size_t retained = 1 << 20;
    for (auto *buffer : {&compressed_, &base_, &target_, &delta_}) {
      if (buffer->capacity() > retained) {
        buffer->clear();
        buffer->shrink_to_fit();
      }
    }
  }

  std::uint64_t objects_read = 0;

private:
  static constexpr std::uint32_t loose = std::numeric_limits<std::uint32_t>::max();

  struct Link {
    std::uint32_t pack;
    std::uint64_t data_offset;
    std::uint64_t size;
  };

  struct Entry {
    std::uint8_t kind = 0;
    std::uint64_t size = 0;
    std::uint64_t data_offset = 0;
    std::uint64_t base_offset = 0;
    ObjectId base;
  };

  inline void refreshPacks() {
    auto directory = openDirectory(objects_.get(), "pack");
    if (!directory) {
      packs_.clear();
      packs_identity_ = {};
      return;
    }
    struct stat status{};
    if (::fstat(directory.get(), &status) != 0) {
      packs_.clear();
      return;
    }
    const auto identity = fingerprintOf(status);
    if (identity == packs_identity_) {
      return;
    }
    packs_.clear();
    packs_identity_ = {};
    telar::runtime::DirectoryStream stream{directory.get()};
    while (const auto *entry = stream.next()) {
      const std::string_view name{entry->d_name};
      if (!name.starts_with("pack-") || !name.ends_with(".idx") || name.size() > 128) {
        continue;
      }
      if (packs_.size() >= limits_->packs) {
        break;
      }
      Pack pack;
      if (openPack(directory.get(), name, pack)) {
        packs_.push_back(std::move(pack));
      }
    }
    packs_identity_ = identity;
  }

  inline bool openPack(int directory, std::string_view index_name, Pack &pack) noexcept {
    const auto hash_size = hashSize(format_);
    PathName name;
    struct stat status{};
    if (!name.assign({index_name}) || openRegular(directory, name.c_str(), pack.index, status) != ReadStatus::ok) {
      return false;
    }
    pack.index_size = static_cast<std::uint64_t>(status.st_size);
    std::array<std::uint8_t, pack_index_header> header;
    if (pack.index_size < pack_index_header + 2 * hash_size || !readAt(pack.index.get(), header.data(), header.size(), 0)) {
      return false;
    }
    if (header[0] != 0xff || header[1] != 't' || header[2] != 'O' || header[3] != 'c' || loadBig32(header.data() + 4) != 2) {
      return false;
    }
    std::uint32_t previous = 0;
    for (std::size_t index = 0; index < pack.fanout.size(); ++index) {
      pack.fanout[index] = loadBig32(header.data() + 8 + 4 * index);
      if (pack.fanout[index] < previous) {
        return false;
      }
      previous = pack.fanout[index];
    }
    pack.count = pack.fanout[255];
    const auto fixed = pack_index_header + std::uint64_t{pack.count} * (hash_size + 8) + 2 * hash_size;
    if (pack.index_size < fixed || (pack.index_size - fixed) % 8 != 0 || (pack.index_size - fixed) / 8 > pack.count) {
      return false;
    }
    pack.large_offsets = (pack.index_size - fixed) / 8;

    const auto stem = index_name.substr(0, index_name.size() - 4);
    if (!name.assign({stem, ".pack"}) || openRegular(directory, name.c_str(), pack.data, status) != ReadStatus::ok) {
      return false;
    }
    pack.data_size = static_cast<std::uint64_t>(status.st_size);
    std::array<std::uint8_t, 12> pack_header;
    if (pack.data_size < pack_header.size() + hash_size || !readAt(pack.data.get(), pack_header.data(), pack_header.size(), 0)) {
      return false;
    }
    const auto version = loadBig32(pack_header.data() + 4);
    return std::memcmp(pack_header.data(), "PACK", 4) == 0 && (version == 2 || version == 3) && loadBig32(pack_header.data() + 8) == pack.count;
  }

  // The position of `id` in a pack index, by binary search over pread blocks.
  inline std::optional<std::uint32_t> findInPack(const Pack &pack, const ObjectId &id) noexcept {
    const auto hash_size = std::size_t{id.size};
    const auto first = id.bytes[0];
    std::uint32_t low = first == 0 ? 0 : pack.fanout[first - 1];
    std::uint32_t high = pack.fanout[first];
    const auto key = id.view();
    while (high > low && std::size_t{high - low} * hash_size > block_.size()) {
      const auto middle = low + (high - low) / 2;
      std::array<std::uint8_t, maximum_hash_size> name;
      if (!readAt(pack.index.get(), name.data(), hash_size, pack_index_header + std::uint64_t{middle} * hash_size)) {
        return std::nullopt;
      }
      const auto order = compareBytes(key, {name.data(), hash_size});
      if (order == 0) {
        return middle;
      }
      if (order < 0) {
        high = middle;
      } else {
        low = middle + 1;
      }
    }
    if (high <= low) {
      return std::nullopt;
    }
    const auto count = std::size_t{high - low};
    if (!readAt(pack.index.get(), block_.data(), count * hash_size, pack_index_header + std::uint64_t{low} * hash_size)) {
      return std::nullopt;
    }
    std::size_t begin = 0;
    std::size_t end = count;
    while (begin < end) {
      const auto middle = begin + (end - begin) / 2;
      const auto order = compareBytes(key, {block_.data() + middle * hash_size, hash_size});
      if (order == 0) {
        return low + static_cast<std::uint32_t>(middle);
      }
      if (order < 0) {
        end = middle;
      } else {
        begin = middle + 1;
      }
    }
    return std::nullopt;
  }

  inline std::optional<std::uint64_t> packOffset(const Pack &pack, std::uint32_t position) noexcept {
    const auto hash_size = hashSize(format_);
    const auto offsets = pack_index_header + std::uint64_t{pack.count} * (hash_size + 4);
    std::array<std::uint8_t, 8> bytes;
    if (!readAt(pack.index.get(), bytes.data(), 4, offsets + 4 * std::uint64_t{position})) {
      return std::nullopt;
    }
    std::uint64_t offset = loadBig32(bytes.data());
    if ((offset & 0x80000000u) != 0) {
      const auto large = offset & 0x7fffffffu;
      if (large >= pack.large_offsets || !readAt(pack.index.get(), bytes.data(), 8, offsets + 4 * std::uint64_t{pack.count} + 8 * large)) {
        return std::nullopt;
      }
      offset = loadBig64(bytes.data());
    }
    if (offset < 12 || offset >= pack.data_size - hash_size) {
      return std::nullopt;
    }
    return offset;
  }

  inline Lookup locate(const ObjectId &id, std::uint32_t &pack, std::uint64_t &offset) {
    if (id.size != hashSize(format_)) {
      return Lookup::invalid;
    }
    for (std::size_t step = 0; step < packs_.size(); ++step) {
      const auto index = (last_pack_ + step) % packs_.size();
      if (const auto position = findInPack(packs_[index], id)) {
        const auto found = packOffset(packs_[index], *position);
        if (!found) {
          return Lookup::invalid;
        }
        last_pack_ = index;
        pack = static_cast<std::uint32_t>(index);
        offset = *found;
        return Lookup::found;
      }
    }
    std::array<char, 2 * maximum_hash_size> hex;
    const auto digits = id.hex(hex);
    PathName name;
    if (!name.assign({digits.substr(0, 2), "/", digits.substr(2)})) {
      return Lookup::invalid;
    }
    struct stat status{};
    if (::fstatat(objects_.get(), name.c_str(), &status, AT_SYMLINK_NOFOLLOW) != 0) {
      return errno == ENOENT || errno == ENOTDIR ? Lookup::missing : Lookup::invalid;
    }
    pack = loose;
    return Lookup::found;
  }

  inline bool entryAt(const Pack &pack, std::uint64_t offset, Entry &entry) noexcept {
    const auto hash_size = hashSize(format_);
    const auto end = pack.data_size - hash_size;
    if (offset < 12 || offset >= end) {
      return false;
    }
    std::array<std::uint8_t, 64> bytes;
    const auto available = static_cast<std::size_t>(std::min<std::uint64_t>(bytes.size(), end - offset));
    if (!readAt(pack.data.get(), bytes.data(), available, offset)) {
      return false;
    }
    std::size_t index = 0;
    auto byte = bytes[index++];
    entry.kind = (byte >> 4) & 7;
    entry.size = byte & 15u;
    unsigned shift = 4;
    while ((byte & 0x80) != 0) {
      if (index >= available || shift > 57) {
        return false;
      }
      byte = bytes[index++];
      entry.size |= std::uint64_t{byte & 0x7fu} << shift;
      shift += 7;
    }
    if (entry.kind == 6) {
      if (index >= available) {
        return false;
      }
      byte = bytes[index++];
      std::uint64_t distance = byte & 0x7fu;
      while ((byte & 0x80) != 0) {
        if (index >= available || distance >= (std::uint64_t{1} << 56)) {
          return false;
        }
        byte = bytes[index++];
        distance = ((distance + 1) << 7) | (byte & 0x7fu);
      }
      if (distance == 0 || distance > offset - 12) {
        return false;
      }
      entry.base_offset = offset - distance;
    } else if (entry.kind == 7) {
      if (!fits(available, index, hash_size)) {
        return false;
      }
      entry.base = ObjectId::fromBytes({bytes.data() + index, hash_size});
      index += hash_size;
    } else if (entry.kind == 0 || entry.kind == 5) {
      return false;
    }
    entry.data_offset = offset + index;
    return true;
  }

  inline bool inflatePacked(const Pack &pack, std::uint64_t data_offset, std::span<std::uint8_t> output, bool whole) {
    if (!inflater_.start()) {
      return false;
    }
    PackSource source{pack.data.get(), data_offset, pack.data_size - hashSize(format_), chunk_};
    if (whole) {
      return inflateExactly(inflater_.stream(), source, output);
    }
    return inflatePrefix(inflater_.stream(), source, output);
  }

  inline Lookup readPacked(std::uint32_t pack, std::uint64_t offset, ObjectType &type, String<Memory> &output, std::size_t prefix) {
    chain_.clear();
    Entry entry;
    bool loose_base = false;
    ObjectId loose_id;
    for (;;) {
      if (!entryAt(packs_[pack], offset, entry)) {
        return Lookup::invalid;
      }
      if (entry.kind >= 1 && entry.kind <= 4) {
        break;
      }
      if (chain_.size() >= limits_->delta_depth || entry.size > limits_->object_size) {
        return Lookup::invalid;
      }
      chain_.push_back({pack, entry.data_offset, entry.size});
      if (entry.kind == 6) {
        offset = entry.base_offset;
        continue;
      }
      std::uint32_t base_pack = 0;
      std::uint64_t base_offset = 0;
      if (locate(entry.base, base_pack, base_offset) != Lookup::found) {
        return Lookup::invalid;
      }
      if (base_pack == loose) {
        loose_base = true;
        loose_id = entry.base;
        break;
      }
      pack = base_pack;
      offset = base_offset;
    }

    if (chain_.empty()) {
      if (entry.size > limits_->object_size && prefix == 0) {
        return Lookup::invalid;
      }
      const auto size = static_cast<std::size_t>(prefix == 0 ? entry.size : std::min<std::uint64_t>(entry.size, prefix));
      if (!charge(size)) {
        return Lookup::invalid;
      }
      resizeForOverwrite(output, size);
      if (!inflatePacked(packs_[pack], entry.data_offset, writable(output), prefix == 0 || size == entry.size)) {
        return Lookup::invalid;
      }
      type = static_cast<ObjectType>(entry.kind);
      return Lookup::found;
    }

    if (loose_base) {
      if (readLoose(loose_id, type, base_, 0) != Lookup::found) {
        return Lookup::invalid;
      }
    } else {
      if (entry.size > limits_->object_size || !charge(entry.size)) {
        return Lookup::invalid;
      }
      resizeForOverwrite(base_, static_cast<std::size_t>(entry.size));
      if (!inflatePacked(packs_[pack], entry.data_offset, writable(base_), true)) {
        return Lookup::invalid;
      }
      type = static_cast<ObjectType>(entry.kind);
    }
    for (auto link = chain_.rbegin(); link != chain_.rend(); ++link) {
      if (!charge(link->size)) {
        return Lookup::invalid;
      }
      resizeForOverwrite(delta_, static_cast<std::size_t>(link->size));
      if (!inflatePacked(packs_[link->pack], link->data_offset, writable(delta_), true) || !applyDelta(asBytes(base_), asBytes(delta_), target_, limits_->object_size) ||
          !charge(target_.size())) {
        return Lookup::invalid;
      }
      base_.swap(target_);
    }
    output.swap(base_);
    if (prefix != 0 && output.size() > prefix) {
      output.resize(prefix);
    }
    return Lookup::found;
  }

  inline Lookup readLoose(const ObjectId &id, ObjectType &type, String<Memory> &output, std::size_t prefix) {
    std::array<char, 2 * maximum_hash_size> hex;
    const auto digits = id.hex(hex);
    PathName name;
    if (!name.assign({digits.substr(0, 2), "/", digits.substr(2)})) {
      return Lookup::invalid;
    }
    const auto read = readWhole(objects_.get(), name.c_str(), compressed_, limits_->object_size);
    if (read != ReadStatus::ok) {
      return read == ReadStatus::missing ? Lookup::missing : Lookup::invalid;
    }
    if (!inflater_.start()) {
      return Lookup::invalid;
    }
    auto &stream = inflater_.stream();
    MemorySource source{asBytes(compressed_)};
    std::array<std::uint8_t, 64> head;
    const auto first = pump(stream, source, head);
    if (first == Inflated::failed) {
      return Lookup::invalid;
    }
    const auto produced = head.size() - stream.avail_out;
    const std::string_view text{reinterpret_cast<const char *>(head.data()), produced};
    const auto space = text.find(' ');
    const auto terminator = text.find('\0');
    if (space == std::string_view::npos || terminator == std::string_view::npos || space > terminator) {
      return Lookup::invalid;
    }
    const auto kind = text.substr(0, space);
    if (kind == "commit") {
      type = ObjectType::commit;
    } else if (kind == "tree") {
      type = ObjectType::tree;
    } else if (kind == "blob") {
      type = ObjectType::blob;
    } else if (kind == "tag") {
      type = ObjectType::tag;
    } else {
      return Lookup::invalid;
    }
    const auto size_text = text.substr(space + 1, terminator - space - 1);
    std::uint64_t size = 0;
    const auto parsed = std::from_chars(size_text.data(), size_text.data() + size_text.size(), size);
    if (size_text.empty() || parsed.ec != std::errc{} || parsed.ptr != size_text.data() + size_text.size()) {
      return Lookup::invalid;
    }
    if (prefix == 0 && size > limits_->object_size) {
      return Lookup::invalid;
    }
    const auto wanted = static_cast<std::size_t>(prefix == 0 ? size : std::min<std::uint64_t>(size, prefix));
    if (!charge(wanted)) {
      return Lookup::invalid;
    }
    const auto ready = produced - terminator - 1;
    if (ready > size) {
      return Lookup::invalid;
    }
    resizeForOverwrite(output, wanted);
    const auto copied = std::min(ready, wanted);
    std::memcpy(output.data(), head.data() + terminator + 1, copied);
    auto rest = writable(output).subspan(copied);
    if (first == Inflated::ended) {
      return ready == size ? Lookup::found : Lookup::invalid;
    }
    if (wanted < size) {
      return inflatePrefix(stream, source, rest) ? Lookup::found : Lookup::invalid;
    }
    if (rest.empty()) {
      return ready == size && endsHere(stream, source) ? Lookup::found : Lookup::invalid;
    }
    return inflateExactly(stream, source, rest) ? Lookup::found : Lookup::invalid;
  }

  // Counts bytes against the per-read budget, so that a crafted delta chain
  // cannot make one read inflate gigabytes.
  inline bool charge(std::uint64_t bytes) noexcept {
    if (bytes > limits_->inflated_bytes - inflated_) {
      return false;
    }
    inflated_ += bytes;
    return true;
  }

  const Limits *limits_ = nullptr;
  std::uint64_t inflated_ = 0;
  ObjectFormat format_ = ObjectFormat::sha1;
  FileDescriptor objects_;
  Fingerprint packs_identity_;
  Inflater<Memory> inflater_;
  Vector<Pack, Memory> packs_;
  Vector<Link, Memory> chain_;
  std::size_t last_pack_ = 0;
  String<Memory> compressed_;
  String<Memory> base_;
  String<Memory> target_;
  String<Memory> delta_;
  std::array<std::uint8_t, 8192> block_;
  std::array<std::uint8_t, 16384> chunk_;
};

// The commit-graph file, or the layers of a split chain. Only each layer's
// fanout is kept in memory; commits are read with pread when the walk needs
// them, so a large graph costs a descriptor, not its size, per reader.
// Positions are global across layers, lower layers first.
template <Allocator Memory>
class CommitGraph {
public:
  static constexpr std::uint32_t no_parent = 0x70000000u;

  struct Layer {
    FileDescriptor file;
    std::uint64_t size = 0;
    std::uint32_t base = 0;
    std::uint32_t count = 0;
    std::uint64_t names = 0;
    std::uint64_t commits = 0;
    std::uint64_t edges = 0;
    std::uint64_t edges_size = 0;
    std::array<std::uint32_t, 256> fanout{};
  };

  struct Commit {
    std::uint32_t generation = 0;
    std::int64_t time = 0;
    std::uint32_t first = no_parent;
    std::uint32_t second = no_parent;
    const Layer *layer = nullptr;
  };

  inline explicit CommitGraph(Memory &memory) noexcept
      : layers_(AllocatorRef<Layer, Memory>{memory}),
        chain_(AllocatorRef<char, Memory>{memory}) {}

  // Reopens the graph when the commit-graph file or the chain file changed.
  // Any invalid layer leaves the graph empty: the walk then reads commits.
  inline void load(int objects, ObjectFormat format, const Limits &limits, bool disabled) {
    if (disabled || objects < 0) {
      clear();
      return;
    }
    const auto single = fingerprintAt(objects, "info/commit-graph");
    const auto chain = single.present ? Fingerprint{} : fingerprintAt(objects, "info/commit-graphs/commit-graph-chain");
    if (loaded_ && single == single_ && chain == chain_identity_ && format == format_) {
      return;
    }
    clear();
    loaded_ = true;
    single_ = single;
    chain_identity_ = chain;
    format_ = format;
    if (single.present) {
      if (!addLayer(objects, "info/commit-graph")) {
        layers_.clear();
      }
      return;
    }
    if (!chain.present || readWhole(objects, "info/commit-graphs/commit-graph-chain", chain_, limits.small_file * 16) != ReadStatus::ok) {
      return;
    }
    std::string_view lines{chain_};
    const auto digits = 2 * hashSize(format);
    while (!lines.empty()) {
      const auto end = lines.find('\n');
      const auto line = lines.substr(0, end);
      lines.remove_prefix(end == std::string_view::npos ? lines.size() : end + 1);
      PathName name;
      if (line.size() != digits || !ObjectId::fromHex(line, format) || layers_.size() >= limits.commit_graph_layers ||
          !name.assign({"info/commit-graphs/graph-", line, ".graph"}) || !addLayer(objects, name.c_str())) {
        layers_.clear();
        return;
      }
    }
  }

  inline void clear() noexcept {
    layers_.clear();
    loaded_ = false;
    single_ = {};
    chain_identity_ = {};
  }

  inline bool empty() const noexcept { return layers_.empty(); }

  // The global position of `id`, nullopt when absent or unreadable.
  inline std::optional<std::uint32_t> find(const ObjectId &id) const noexcept {
    const auto hash_size = hashSize(format_);
    if (id.size != hash_size) {
      return std::nullopt;
    }
    for (const auto &layer : layers_) {
      const auto first = id.bytes[0];
      std::uint32_t low = first == 0 ? 0 : layer.fanout[first - 1];
      std::uint32_t high = layer.fanout[first];
      while (low < high) {
        const auto middle = low + (high - low) / 2;
        std::array<std::uint8_t, maximum_hash_size> name;
        if (!readAt(layer.file.get(), name.data(), hash_size, layer.names + std::uint64_t{middle} * hash_size)) {
          return std::nullopt;
        }
        const auto order = compareBytes(id.view(), {name.data(), hash_size});
        if (order == 0) {
          return layer.base + middle;
        }
        if (order < 0) {
          high = middle;
        } else {
          low = middle + 1;
        }
      }
    }
    return std::nullopt;
  }

  // `position` must come from find() or parents().
  inline std::optional<ObjectId> id(std::uint32_t position) const noexcept {
    const auto *layer = layerOf(position);
    const auto hash_size = hashSize(format_);
    std::array<std::uint8_t, maximum_hash_size> name;
    if (layer == nullptr || !readAt(layer->file.get(), name.data(), hash_size, layer->names + std::uint64_t{position - layer->base} * hash_size)) {
      return std::nullopt;
    }
    return ObjectId::fromBytes({name.data(), hash_size});
  }

  // The commit at `position`. A generation of 0, which no released git
  // writes, would break the walk's order, so it reads as unreadable.
  inline std::optional<Commit> commit(std::uint32_t position) const noexcept {
    const auto *layer = layerOf(position);
    const auto hash_size = hashSize(format_);
    std::array<std::uint8_t, maximum_hash_size + 16> record;
    if (layer == nullptr || !readAt(layer->file.get(), record.data(), hash_size + 16, layer->commits + std::uint64_t{position - layer->base} * (hash_size + 16))) {
      return std::nullopt;
    }
    const auto upper = loadBig32(record.data() + hash_size + 8);
    const Commit commit{
        .generation = upper >> 2,
        .time = static_cast<std::int64_t>((std::uint64_t{upper & 3u} << 32) | loadBig32(record.data() + hash_size + 12)),
        .first = loadBig32(record.data() + hash_size),
        .second = loadBig32(record.data() + hash_size + 4),
        .layer = layer,
    };
    if (commit.generation == 0) {
      return std::nullopt;
    }
    return commit;
  }

  // Calls `output` with each parent of `commit`; false when the graph is malformed.
  template <typename Output>
  bool parents(const Commit &commit, std::size_t maximum, Output &&output) const {
    const auto limit = commit.layer->base + commit.layer->count;
    if (commit.first == no_parent) {
      return true;
    }
    if (commit.first >= limit) {
      return false;
    }
    output(commit.first);
    if (commit.second == no_parent) {
      return true;
    }
    if ((commit.second & 0x80000000u) == 0) {
      if (commit.second >= limit) {
        return false;
      }
      output(commit.second);
      return true;
    }
    auto edge = std::uint64_t{commit.second & 0x7fffffffu};
    for (std::size_t count = 1;; ++count, ++edge) {
      std::array<std::uint8_t, 4> bytes;
      if (count >= maximum || !fits(commit.layer->edges_size, 4 * edge, 4) || !readAt(commit.layer->file.get(), bytes.data(), 4, commit.layer->edges + 4 * edge)) {
        return false;
      }
      const auto value = loadBig32(bytes.data());
      const auto parent = value & 0x7fffffffu;
      if (parent >= limit) {
        return false;
      }
      output(parent);
      if ((value & 0x80000000u) != 0) {
        return true;
      }
    }
  }

private:
  inline const Layer *layerOf(std::uint32_t position) const noexcept {
    for (const auto &layer : layers_) {
      if (position - layer.base < layer.count) {
        return &layer;
      }
    }
    return nullptr;
  }

  // Validates the header, the chunk table and the fanout of one layer.
  inline bool addLayer(int objects, const char *path) {
    const auto hash_size = hashSize(format_);
    Layer layer;
    struct stat status{};
    if (openRegular(objects, path, layer.file, status) != ReadStatus::ok) {
      return false;
    }
    layer.size = static_cast<std::uint64_t>(status.st_size);
    constexpr std::size_t maximum_chunks = 32;
    std::array<std::uint8_t, 8 + 12 * (maximum_chunks + 1)> header;
    if (layer.size < 8 + hash_size || !readAt(layer.file.get(), header.data(), 8, 0)) {
      return false;
    }
    if (std::memcmp(header.data(), "CGPH", 4) != 0 || header[4] != 1 || header[5] != (format_ == ObjectFormat::sha1 ? 1 : 2)) {
      return false;
    }
    const std::size_t chunk_count = header[6];
    const auto table = 12 * (chunk_count + 1);
    if (header[7] != layers_.size() || chunk_count > maximum_chunks || !fits(layer.size - hash_size, 8, table) || !readAt(layer.file.get(), header.data() + 8, table, 8)) {
      return false;
    }
    std::uint64_t fanout = 0;
    std::uint64_t fanout_size = 0;
    std::uint64_t names_size = 0;
    std::uint64_t commits_size = 0;
    for (std::size_t chunk = 0; chunk < chunk_count; ++chunk) {
      const auto *entry = header.data() + 8 + 12 * chunk;
      const auto identifier = loadBig32(entry);
      const auto start = loadBig64(entry + 4);
      const auto end = loadBig64(entry + 16);
      if (identifier == 0 || start > end || end > layer.size - hash_size) {
        return false;
      }
      switch (identifier) {
      case 0x4f494446: // OIDF
        fanout = start;
        fanout_size = end - start;
        break;
      case 0x4f49444c: // OIDL
        layer.names = start;
        names_size = end - start;
        break;
      case 0x43444154: // CDAT
        layer.commits = start;
        commits_size = end - start;
        break;
      case 0x45444745: // EDGE
        layer.edges = start;
        layer.edges_size = end - start;
        break;
      default:
        break;
      }
    }
    std::array<std::uint8_t, 256 * 4> fanout_bytes;
    if (loadBig32(header.data() + 8 + 12 * chunk_count) != 0 || fanout_size != fanout_bytes.size() || !readAt(layer.file.get(), fanout_bytes.data(), fanout_bytes.size(), fanout)) {
      return false;
    }
    std::uint32_t previous = 0;
    for (std::size_t index = 0; index < layer.fanout.size(); ++index) {
      layer.fanout[index] = loadBig32(fanout_bytes.data() + 4 * index);
      if (layer.fanout[index] < previous) {
        return false;
      }
      previous = layer.fanout[index];
    }
    layer.count = previous;
    layer.base = layers_.empty() ? 0 : layers_.back().base + layers_.back().count;
    if (std::uint64_t{layer.base} + layer.count >= no_parent || names_size != std::uint64_t{layer.count} * hash_size ||
        commits_size != std::uint64_t{layer.count} * (hash_size + 16) || layer.edges_size % 4 != 0) {
      return false;
    }
    layers_.push_back(std::move(layer));
    return true;
  }

  Vector<Layer, Memory> layers_;
  String<Memory> chain_;
  Fingerprint single_;
  Fingerprint chain_identity_;
  ObjectFormat format_ = ObjectFormat::sha1;
  bool loaded_ = false;
};

}
