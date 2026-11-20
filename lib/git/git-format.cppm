export module telar.git:format;

import std;
import telar.base.memory.allocators;
import telar.platform.sha256;
import telar.platform.primitives;
import telar.sys.posix;
import telar.base.ds;
import telar.tbc;

// Byte-level primitives every other part of the reader shares: object ids,
// hashing, bounded file reads beneath a directory descriptor and file
// fingerprints. Everything read from a repository is untrusted input.

// The defaults of Limits.
namespace telar::git::default_limits {

  inline constexpr std::size_t kibibyte = std::size_t{1} << 10U;
  inline constexpr std::size_t mebibyte = std::size_t{1} << 20U;

  inline constexpr std::size_t small_file = 4096;
  inline constexpr std::size_t config_file = mebibyte;
  inline constexpr std::size_t packed_refs = 64 * mebibyte;
  inline constexpr std::size_t shallow_file = 16 * mebibyte;
  inline constexpr std::size_t index_file = 256 * mebibyte;
  inline constexpr std::size_t index_entries = std::size_t{1} << 21U;
  inline constexpr std::size_t path_length = 4095;
  inline constexpr std::size_t path_depth = 128;
  inline constexpr std::size_t discovery_depth = 256;
  inline constexpr std::size_t symbolic_depth = 5;
  inline constexpr std::size_t packs = 1024;
  inline constexpr std::size_t object_size = 64 * mebibyte;
  inline constexpr std::size_t delta_depth = 128;
  inline constexpr std::size_t inflated_bytes = 256 * mebibyte;
  inline constexpr std::size_t commit_header = 64 * kibibyte;
  inline constexpr std::size_t commit_parents = 128;
  inline constexpr std::size_t commit_graph_layers = 64;
  inline constexpr std::size_t walk_commits = 20000;
  inline constexpr std::size_t tree_objects = 20000;
  inline constexpr std::size_t hashed_bytes = 64 * mebibyte;

}

export namespace telar::git {

  // Upper bounds on what one read may consume. Exceeding one reports the
  // affected part as unknown instead of reading further.
  struct Limits {
    std::size_t small_file = default_limits::small_file;   // HEAD, loose refs, .git files, commondir
    std::size_t config_file = default_limits::config_file; // config, config.worktree
    std::size_t packed_refs = default_limits::packed_refs;
    std::size_t shallow_file = default_limits::shallow_file;
    std::size_t index_file = default_limits::index_file;
    std::size_t index_entries = default_limits::index_entries;
    std::size_t path_length = default_limits::path_length;         // one index path or ref name
    std::size_t path_depth = default_limits::path_depth;           // directory components of one index path
    std::size_t discovery_depth = default_limits::discovery_depth; // parent directories walked to find .git
    std::size_t symbolic_depth = default_limits::symbolic_depth;   // chained symbolic refs, as git's SYMREF_MAXDEPTH
    std::size_t packs = default_limits::packs;
    std::size_t object_size = default_limits::object_size; // one inflated object or delta result
    std::size_t delta_depth = default_limits::delta_depth;
    std::size_t inflated_bytes = default_limits::inflated_bytes; // inflated and delta-applied by one read
    std::size_t commit_header = default_limits::commit_header;   // bytes of a commit inspected for its header
    std::size_t commit_parents = default_limits::commit_parents;
    std::size_t commit_graph_layers = default_limits::commit_graph_layers;
    std::size_t walk_commits = default_limits::walk_commits; // commits visited by one ahead/behind walk
    std::size_t tree_objects = default_limits::tree_objects; // trees read by one HEAD-to-index comparison
    std::size_t hashed_bytes = default_limits::hashed_bytes; // working tree bytes hashed by one read
  };

  enum class ObjectFormat : std::uint8_t {
    sha1,
    sha256,
  };

  inline constexpr std::size_t sha1_hash_size = 20;
  inline constexpr std::size_t sha256_hash_size = 32;
  inline constexpr std::size_t maximum_hash_size = sha256_hash_size;
  inline constexpr std::size_t default_abbreviation = 7;

  inline constexpr std::size_t hashSize(ObjectFormat format) noexcept {
    return format == ObjectFormat::sha1 ? sha1_hash_size : sha256_hash_size;
  }

  inline constexpr int hexValue(char digit) noexcept {
    constexpr int letter_values = 10;

    if (digit >= '0' && digit <= '9') {
      return digit - '0';
    }

    if (digit >= 'a' && digit <= 'f') {
      return digit - 'a' + letter_values;
    }

    if (digit >= 'A' && digit <= 'F') {
      return digit - 'A' + letter_values;
    }

    return -1;
  }

  struct ObjectId {
    ds::Array<std::uint8_t, maximum_hash_size> bytes{};
    std::uint8_t size = 0;

    friend bool operator==(const ObjectId&, const ObjectId&) = default;

    explicit operator bool() const noexcept;
    [[nodiscard]] std::span<const std::uint8_t> view() const noexcept;

    // The first `digits` hexadecimal digits, written into `buffer`.
    [[nodiscard]] tbc::val_a<std::string_view> hex(tbc::val_a<std::span<char, 2 * maximum_hash_size>> buffer, std::size_t digits = 2 * maximum_hash_size) const noexcept;

    static ds::Option<ObjectId> fromHex(std::string_view text, ObjectFormat format) noexcept;

    // `raw` holds at most maximum_hash_size bytes; callers check its bounds.
    static ObjectId fromBytes(std::span<const std::uint8_t> raw) noexcept;
  };

  // The identity and change markers of one file, from lstat-like data. Two
  // equal fingerprints mean git rewrote nothing: it replaces files by rename.
  struct Fingerprint {
    std::uint64_t device = 0;
    std::uint64_t inode = 0;
    std::uint64_t size = 0;
    std::int64_t modified_seconds = 0;
    std::int64_t modified_nanoseconds = 0;
    std::int64_t changed_seconds = 0;
    std::int64_t changed_nanoseconds = 0;
    std::uint32_t mode = 0;
    bool present = false;

    friend bool operator==(const Fingerprint&, const Fingerprint&) = default;
  };

}

namespace telar::git {

  using telar::runtime::FileDescriptor;

  Fingerprint fingerprintOf(const struct stat& status) noexcept;

  // The fingerprint of `name` beneath `directory`, without following a final
  // symlink. An absent or unreadable entry has no fingerprint.
  Fingerprint fingerprintAt(int directory, const char* name) noexcept;

  bool sameFile(const struct stat& left, const struct stat& right) noexcept;
  std::span<const std::uint8_t> asBytes(std::string_view text) noexcept;
  std::string_view asText(std::span<const std::uint8_t> bytes) noexcept;

  // True when [offset, offset + count) lies within `length` bytes, without overflow.
  inline constexpr bool fits(std::uint64_t length, std::uint64_t offset, std::uint64_t count) noexcept {
    return offset <= length && count <= length - offset;
  }

  // The big-endian integer at `offset` of `bytes`, which holds all of it.
  std::uint16_t loadBig16(std::span<const std::uint8_t> bytes, std::size_t offset = 0) noexcept;
  std::uint32_t loadBig32(std::span<const std::uint8_t> bytes, std::size_t offset = 0) noexcept;
  std::uint64_t loadBig64(std::span<const std::uint8_t> bytes, std::size_t offset = 0) noexcept;
  int compareBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept;

  // A NUL-terminated name for the *at() calls, assembled without allocating.
  class PathName {
  public:
    PathName() noexcept;
    bool assign(std::initializer_list<std::string_view> parts) noexcept;
    [[nodiscard]] const char* cString() const noexcept;
    [[nodiscard]] std::string_view view() const noexcept;

  private:
    static constexpr std::size_t capacity = 4096;

    ds::Array<char, capacity> bytes_;
    std::size_t length_ = 0;
  };

  enum class ReadStatus : std::uint8_t {
    ok,
    missing,
    invalid,
  };

  // Opens a regular file beneath `directory`. A final symlink, a FIFO, a device
  // or a directory is refused; O_NONBLOCK keeps a FIFO from blocking the open.
  ReadStatus openRegular(int directory, const char* name, FileDescriptor& file, struct stat& status) noexcept;

  // Fills `destination` from `offset`; false when the file is shorter or cannot be read.
  bool readAt(int descriptor, std::span<std::uint8_t> destination, std::uint64_t offset) noexcept;

  // Reads a small file into a caller buffer; files that do not fit are invalid.
  ReadStatus readSmall(int directory, const char* name, tbc::val_a<std::span<char>> buffer, tbc::mut_a<std::string_view> contents, Fingerprint* fingerprint = nullptr) noexcept;

  // Reads a whole file of at most `limit` bytes into `bytes`, which keeps its capacity.
  ReadStatus readWhole(int directory, const char* name, ds::String<Memory>& bytes, std::size_t limit, Fingerprint* fingerprint = nullptr);

  // Whether opening a name follows it when it is a symlink.
  enum class FinalLink : std::uint8_t {
    follow,
    refuse,
  };

  FileDescriptor openDirectory(int directory, const char* name, FinalLink link = FinalLink::follow) noexcept;

  class Sha1 {
  public:
    Sha1() noexcept;
    void update(std::span<const std::uint8_t> bytes) noexcept;
    ds::Array<std::uint8_t, SHA_DIGEST_LENGTH> finish() noexcept;

  private:
    SHA_CTX context_{};
  };

  // The object hash of the repository's format.
  class Hasher {
  public:
    explicit Hasher(ObjectFormat format) noexcept;
    void update(std::span<const std::uint8_t> bytes) noexcept;
    ObjectId finish() noexcept;

  private:
    ObjectFormat format_;
    Sha1 sha1_;
    telar::runtime::Sha256 sha256_;
  };

  ObjectId hashBytes(ObjectFormat format, std::span<const std::uint8_t> bytes) noexcept;

  // Starts hashing an object as git does: "<type> <size>\0" precedes its bytes.
  void hashObjectHeader(Hasher& hasher, std::string_view type, std::uint64_t size) noexcept;

  ObjectId emptyBlob(ObjectFormat format) noexcept;

  // git's check_refname_format for a full ref name, which also keeps a name
  // from escaping the refs directory: no "..", no component starting with ".".
  bool validReferenceName(std::string_view name, std::size_t maximum_length) noexcept;

}
