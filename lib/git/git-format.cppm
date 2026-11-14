export module telar.git:format;

import std;
import telar.base.memory.allocators;
import telar.platform.sha256;
import telar.platform.primitives;
import telar.sys.posix;

// Byte-level primitives every other part of the reader shares: object ids,
// hashing, bounded file reads beneath a directory descriptor and file
// fingerprints. Everything read from a repository is untrusted input.

export namespace telar::git {

  // Upper bounds on what one read may consume. Exceeding one reports the
  // affected part as unknown instead of reading further.
  struct Limits {
    std::size_t small_file = 4096;     // HEAD, loose refs, .git files, commondir
    std::size_t config_file = 1 << 20; // config, config.worktree
    std::size_t packed_refs = 64 << 20;
    std::size_t shallow_file = 16 << 20;
    std::size_t index_file = 256 << 20;
    std::size_t index_entries = 1 << 21;
    std::size_t path_length = 4095;    // one index path or ref name
    std::size_t path_depth = 128;      // directory components of one index path
    std::size_t discovery_depth = 256; // parent directories walked to find .git
    std::size_t symbolic_depth = 5;    // chained symbolic refs, as git's SYMREF_MAXDEPTH
    std::size_t packs = 1024;
    std::size_t object_size = 64 << 20; // one inflated object or delta result
    std::size_t delta_depth = 128;
    std::size_t inflated_bytes = 256 << 20; // inflated and delta-applied by one read
    std::size_t commit_header = 64 << 10;   // bytes of a commit inspected for its header
    std::size_t commit_parents = 128;
    std::size_t commit_graph_layers = 64;
    std::size_t walk_commits = 20000;    // commits visited by one ahead/behind walk
    std::size_t tree_objects = 20000;    // trees read by one HEAD-to-index comparison
    std::size_t hashed_bytes = 64 << 20; // working tree bytes hashed by one read
  };

  enum class ObjectFormat : std::uint8_t {
    sha1,
    sha256,
  };

  inline constexpr std::size_t maximum_hash_size = 32;
  inline constexpr std::size_t default_abbreviation = 7;

  inline constexpr std::size_t hashSize(ObjectFormat format) noexcept {
    return format == ObjectFormat::sha1 ? 20 : 32;
  }

  inline constexpr int hexValue(char digit) noexcept {
    if (digit >= '0' && digit <= '9') {
      return digit - '0';
    }

    if (digit >= 'a' && digit <= 'f') {
      return digit - 'a' + 10;
    }

    if (digit >= 'A' && digit <= 'F') {
      return digit - 'A' + 10;
    }

    return -1;
  }

  struct ObjectId {
    std::array<std::uint8_t, maximum_hash_size> bytes{};
    std::uint8_t size = 0;

    friend bool operator==(const ObjectId&, const ObjectId&) = default;

    explicit operator bool() const noexcept;
    std::span<const std::uint8_t> view() const noexcept;

    // The first `digits` hexadecimal digits, written into `buffer`.
    std::string_view hex(std::span<char, 2 * maximum_hash_size> buffer, std::size_t digits = 2 * maximum_hash_size) const noexcept;

    static std::optional<ObjectId> fromHex(std::string_view text, ObjectFormat format) noexcept;

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

  // True when [offset, offset + count) lies within `size` bytes, without overflow.
  inline constexpr bool fits(std::uint64_t size, std::uint64_t offset, std::uint64_t count) noexcept {
    return offset <= size && count <= size - offset;
  }

  std::uint16_t loadBig16(const std::uint8_t* bytes) noexcept;
  std::uint32_t loadBig32(const std::uint8_t* bytes) noexcept;
  std::uint64_t loadBig64(const std::uint8_t* bytes) noexcept;
  int compareBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept;

  // A NUL-terminated name for the *at() calls, assembled without allocating.
  class PathName {
  public:
    PathName() noexcept;
    bool assign(std::initializer_list<std::string_view> parts) noexcept;
    const char* c_str() const noexcept;
    std::string_view view() const noexcept;

  private:
    std::array<char, 4096> bytes_;
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

  bool readAt(int descriptor, void* destination, std::size_t size, std::uint64_t offset) noexcept;

  // Reads a small file into a caller buffer; files that do not fit are invalid.
  ReadStatus readSmall(int directory, const char* name, std::span<char> buffer, std::string_view& contents, Fingerprint* fingerprint = nullptr) noexcept;

  // Reads a whole file of at most `limit` bytes into `bytes`, which keeps its capacity.
  ReadStatus readWhole(int directory, const char* name, String<Memory>& bytes, std::size_t limit, Fingerprint* fingerprint = nullptr);

  FileDescriptor openDirectory(int directory, const char* name) noexcept;

  class Sha1 {
  public:
    Sha1() noexcept;
    void update(std::span<const std::uint8_t> bytes) noexcept;
    std::array<std::uint8_t, SHA_DIGEST_LENGTH> finish() noexcept;

  private:
    SHA_CTX context_;
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
