module telar.git;

import std;
import telar.platform.sha256;
import telar.sys.posix;
import telar.base.text;
import telar.base.ds;

namespace telar::git {

  using telar::runtime::substring;

  namespace {

#ifdef __APPLE__
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtimespec;
    }

    const timespec& changedTime(const struct stat& status) noexcept {
      return status.st_ctimespec;
    }
#else
    const timespec& modifiedTime(const struct stat& status) noexcept {
      return status.st_mtim;
    }

    const timespec& changedTime(const struct stat& status) noexcept {
      return status.st_ctim;
    }
#endif

    constexpr unsigned nibble_bits = 4;
    constexpr unsigned nibble_mask = 0xf;

    // Reads exactly `destination.size()` bytes and confirms the file ends there, so a file that
    // grows or shrinks while it is read is refused rather than half-parsed.
    bool readExactly(int descriptor, std::span<char> destination) noexcept {
      std::size_t offset = 0;

      while (offset < destination.size()) {
        const auto rest = destination.subspan(offset);
        const auto count = ::read(descriptor, rest.data(), rest.size());
        if (count > 0) {
          offset += static_cast<std::size_t>(count);
        } else if (count < 0 && sys::lastError() == EINTR) {
          continue;
        } else {
          return false;
        }
      }

      char extra = 0;
      auto count = ::read(descriptor, &extra, 1);

      while (count < 0 && sys::lastError() == EINTR) {
        count = ::read(descriptor, &extra, 1);
      }

      return count == 0;
    }

    template <std::unsigned_integral Integer>
    Integer loadBig(std::span<const std::uint8_t> bytes, std::size_t offset) noexcept {
      constexpr unsigned byte_bits = 8;
      std::uint64_t value = 0;

      for (const auto byte : bytes.subspan(offset).first<sizeof(Integer)>()) {
        value = (value << byte_bits) | byte;
      }

      return static_cast<Integer>(value);
    }

    int signOf(std::strong_ordering order) noexcept {
      if (order < 0) {
        return -1;
      }

      return order > 0 ? 1 : 0;
    }

  }

  ObjectId::operator bool() const noexcept {
    return size != 0;
  }

  std::span<const std::uint8_t> ObjectId::view() const noexcept {
    return bytes.view().first(size);
  }

  tbc::val_a<std::string_view> ObjectId::hex(tbc::val_a<std::span<char, 2 * maximum_hash_size>> buffer, std::size_t digits) const noexcept {
    constexpr std::string_view alphabet = "0123456789abcdef";

    digits = std::min(digits, std::size_t{size} * 2);
    for (std::size_t index = 0; index < digits; ++index) {
      const auto byte = bytes[index / 2];

      buffer[index] = alphabet[index % 2 == 0 ? byte >> nibble_bits : byte & nibble_mask];
    }

    return {buffer.data(), digits};
  }

  ds::Option<ObjectId> ObjectId::fromHex(std::string_view text, ObjectFormat format) noexcept {
    const auto size = hashSize(format);
    if (text.size() != 2 * size) {
      return ds::none;
    }

    ObjectId id;

    id.size = static_cast<std::uint8_t>(size);
    for (std::size_t index = 0; index < size; ++index) {
      const auto high = hexValue(text[2 * index]);
      const auto low = hexValue(text[(2 * index) + 1]);
      if (high < 0 || low < 0) {
        return ds::none;
      }

      id.bytes.atMut(index) = static_cast<std::uint8_t>(static_cast<unsigned>(high) << nibble_bits | static_cast<unsigned>(low));
    }

    return id;
  }

  ObjectId ObjectId::fromBytes(std::span<const std::uint8_t> raw) noexcept {
    ObjectId id;

    id.size = static_cast<std::uint8_t>(std::min(raw.size(), maximum_hash_size));
    std::copy_n(raw.begin(), id.size, id.bytes.dataMut());
    return id;
  }

  Fingerprint fingerprintOf(const struct stat& status) noexcept {
    return {
        .device = static_cast<std::uint64_t>(status.st_dev),
        .inode = static_cast<std::uint64_t>(status.st_ino),
        .size = static_cast<std::uint64_t>(status.st_size),
        .modified_seconds = static_cast<std::int64_t>(modifiedTime(status).tv_sec),
        .modified_nanoseconds = static_cast<std::int64_t>(modifiedTime(status).tv_nsec),
        .changed_seconds = static_cast<std::int64_t>(changedTime(status).tv_sec),
        .changed_nanoseconds = static_cast<std::int64_t>(changedTime(status).tv_nsec),
        .mode = static_cast<std::uint32_t>(status.st_mode),
        .present = true,
    };
  }

  Fingerprint fingerprintAt(int directory, const char* name) noexcept {
    struct stat status{};
    if (directory < 0 || ::fstatat(directory, name, &status, AT_SYMLINK_NOFOLLOW) != 0) {
      return {};
    }

    return fingerprintOf(status);
  }

  bool sameFile(const struct stat& left, const struct stat& right) noexcept {
    return left.st_dev == right.st_dev && left.st_ino == right.st_ino;
  }

  std::span<const std::uint8_t> asBytes(std::string_view text) noexcept {
#pragma clang unsafe_buffer_usage begin
    return {reinterpret_cast<const std::uint8_t*>(text.data()), text.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): bytes may alias text, and no cast-free view reads text as bytes
#pragma clang unsafe_buffer_usage end
  }

  std::string_view asText(std::span<const std::uint8_t> bytes) noexcept {
    return {reinterpret_cast<const char*>(bytes.data()), bytes.size()}; // NOLINT(cppcoreguidelines-pro-type-reinterpret-cast): char may alias the bytes, and no cast-free view reads them as text
  }

  std::uint16_t loadBig16(std::span<const std::uint8_t> bytes, std::size_t offset) noexcept {
    return loadBig<std::uint16_t>(bytes, offset);
  }

  std::uint32_t loadBig32(std::span<const std::uint8_t> bytes, std::size_t offset) noexcept {
    return loadBig<std::uint32_t>(bytes, offset);
  }

  std::uint64_t loadBig64(std::span<const std::uint8_t> bytes, std::size_t offset) noexcept {
    return loadBig<std::uint64_t>(bytes, offset);
  }

  int compareBytes(std::span<const std::uint8_t> left, std::span<const std::uint8_t> right) noexcept {
    return signOf(std::lexicographical_compare_three_way(left.begin(), left.end(), right.begin(), right.end()));
  }

  PathName::PathName() noexcept { // NOLINT(cppcoreguidelines-pro-type-member-init): bytes_ is written before it is read, and zeroing its 4 KiB would cost every *at() call that names a file
    bytes_.atMut(0) = '\0';
  }

  bool PathName::assign(std::initializer_list<std::string_view> parts) noexcept {
    length_ = 0;
    for (const auto part : parts) {
      if (part.size() >= bytes_.size() - length_ || part.contains('\0')) {
        length_ = 0;
        bytes_.atMut(0) = '\0';
        return false;
      }

      std::ranges::copy(part, bytes_.viewMut().subspan(length_).begin());
      length_ += part.size();
    }

    bytes_.atMut(length_) = '\0';
    return true;
  }

  const char* PathName::cString() const noexcept {
    return bytes_.data();
  }

  std::string_view PathName::view() const noexcept {
    return {bytes_.data(), length_};
  }

  ReadStatus openRegular(int directory, const char* name, FileDescriptor& file, struct stat& status) noexcept {
    file.reset(::openat(directory, name, runtime::combineFlags(O_RDONLY, O_NOFOLLOW, O_NONBLOCK, O_CLOEXEC, O_NOCTTY))); // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
    if (!file) {
      return sys::lastError() == ENOENT || sys::lastError() == ENOTDIR ? ReadStatus::missing : ReadStatus::invalid;
    }

    if (::fstat(file.get(), &status) != 0 || !S_ISREG(status.st_mode) || status.st_size < 0) {
      file.reset();
      return ReadStatus::invalid;
    }

    return ReadStatus::ok;
  }

  bool readAt(int descriptor, std::span<std::uint8_t> destination, std::uint64_t offset) noexcept {
    std::size_t done = 0;

    while (done < destination.size()) {
      if (offset + done > static_cast<std::uint64_t>(std::numeric_limits<off_t>::max())) {
        return false;
      }

      const auto rest = destination.subspan(done);
      const auto count = ::pread(descriptor, rest.data(), rest.size(), static_cast<off_t>(offset + done));
      if (count > 0) {
        done += static_cast<std::size_t>(count);
      } else if (count < 0 && sys::lastError() == EINTR) {
        continue;
      } else {
        return false;
      }
    }

    return true;
  }

  ReadStatus readSmall(int directory, const char* name, tbc::val_a<std::span<char>> buffer, tbc::mut_a<std::string_view> contents, Fingerprint* fingerprint) noexcept {
    FileDescriptor file;
    struct stat status{};
    if (const auto opened = openRegular(directory, name, file, status); opened != ReadStatus::ok) {
      return opened;
    }

    const auto size = static_cast<std::uint64_t>(status.st_size);
    if (size > buffer.size() || !readExactly(file.get(), buffer.first(static_cast<std::size_t>(size)))) {
      return ReadStatus::invalid;
    }

    if (fingerprint != nullptr) {
      *fingerprint = fingerprintOf(status);
    }

    contents = {buffer.data(), static_cast<std::size_t>(size)};
    return ReadStatus::ok;
  }

  ReadStatus readWhole(int directory, const char* name, ds::String<Memory>& bytes, std::size_t limit, Fingerprint* fingerprint) {
    bytes.clear();
    FileDescriptor file;
    struct stat status{};
    if (const auto opened = openRegular(directory, name, file, status); opened != ReadStatus::ok) {
      return opened;
    }

    const auto size = static_cast<std::uint64_t>(status.st_size);
    if (size > limit) {
      return ReadStatus::invalid;
    }

    bool complete = false;

    bytes.resizeForOverwrite(static_cast<std::size_t>(size));
    complete = readExactly(file.get(), bytes.viewMut());

    if (!complete) {
      bytes.clear();
      return ReadStatus::invalid;
    }

    if (fingerprint != nullptr) {
      *fingerprint = fingerprintOf(status);
    }

    return ReadStatus::ok;
  }

  FileDescriptor openDirectory(int directory, const char* name, FinalLink link) noexcept {
    const auto flags = runtime::combineFlags(O_RDONLY, O_DIRECTORY, O_CLOEXEC, link == FinalLink::refuse ? O_NOFOLLOW : 0);

    return FileDescriptor{::openat(directory, name, flags)}; // NOLINT(cppcoreguidelines-pro-type-vararg): openat's C signature is variadic
  }

// SHA-1 goes through OpenSSL's low-level API, deprecated since 3.0 in favour of EVP: it keeps its
// context inline, where an EVP_MD_CTX is a heap allocation and a provider lookup per hash, and
// every object a worktree scan reads is hashed.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

  Sha1::Sha1() noexcept {
    SHA1_Init(&context_);
  }

  void Sha1::update(std::span<const std::uint8_t> bytes) noexcept {
    SHA1_Update(&context_, bytes.data(), bytes.size());
  }

  ds::Array<std::uint8_t, SHA_DIGEST_LENGTH> Sha1::finish() noexcept {
    ds::Array<std::uint8_t, SHA_DIGEST_LENGTH> digest{};

    SHA1_Final(digest.dataMut(), &context_);
    return digest;
  }

#pragma clang diagnostic pop

  Hasher::Hasher(ObjectFormat format) noexcept
      : format_(format) {}

  void Hasher::update(std::span<const std::uint8_t> bytes) noexcept {
    if (format_ == ObjectFormat::sha1) {
      sha1_.update(bytes);
    } else {
      sha256_.update(asText(bytes));
    }
  }

  ObjectId Hasher::finish() noexcept {
    if (format_ == ObjectFormat::sha1) {
      const auto digest = sha1_.finish();

      return ObjectId::fromBytes(digest);
    }

    const auto digest = sha256_.finish();

    return ObjectId::fromBytes(digest);
  }

  ObjectId hashBytes(ObjectFormat format, std::span<const std::uint8_t> bytes) noexcept {
    Hasher hasher{format};

    hasher.update(bytes);
    return hasher.finish();
  }

  void hashObjectHeader(Hasher& hasher, std::string_view type, std::uint64_t size) noexcept {
    // Room for git's longest type, a space, the digits of the largest size and the NUL.
    constexpr std::size_t header_bytes = 48;

    ds::Array<char, header_bytes> header{};
    const auto view = header.viewMut();

    std::ranges::copy(type, view.begin());
    view[type.size()] = ' ';
    const auto digits = view.subspan(type.size() + 1, view.size() - type.size() - 2);
    const auto* const end = std::to_chars(digits.data(), std::to_address(digits.end()), size).ptr;
    const auto length = static_cast<std::size_t>(end - view.data());

    view[length] = '\0';
    hasher.update(asBytes({view.data(), length + 1}));
  }

  ObjectId emptyBlob(ObjectFormat format) noexcept {
    Hasher hasher{format};

    hashObjectHeader(hasher, "blob", 0);
    return hasher.finish();
  }

  bool validReferenceName(std::string_view name, std::size_t maximum_length) noexcept {
    if (name.empty() || name.size() > maximum_length || name == "@" || name.front() == '/' || name.back() == '/' || name.back() == '.') {
      return false;
    }

    std::size_t component_start = 0;

    for (std::size_t index = 0; index <= name.size(); ++index) {
      if (index == name.size() || name[index] == '/') {
        const auto component = substring(name, component_start, index - component_start);
        if (component.empty() || component.front() == '.' || component.ends_with(".lock")) {
          return false;
        }

        component_start = index + 1;
        continue;
      }

      constexpr unsigned char first_printable = 0x20;
      constexpr unsigned char delete_character = 0x7f;

      const auto byte = static_cast<unsigned char>(name[index]);
      if (byte < first_printable || byte == delete_character) {
        return false;
      }

      switch (name[index]) {
      case ' ':
      case '~':
      case '^':
      case ':':
      case '?':
      case '*':
      case '[':
      case '\\':
        return false;
      case '.':
        if (index + 1 < name.size() && name[index + 1] == '.') {
          return false;
        }

        break;
      case '@':
        if (index + 1 < name.size() && name[index + 1] == '{') {
          return false;
        }

        break;
      default:
        break;
      }
    }

    return true;
  }

}
