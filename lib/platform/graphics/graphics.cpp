module telar.platform.graphics;

import std;
import telar.sys.posix;
import telar.base.ds;
import telar.base.text;

namespace telar::runtime {

  ds::Option<SharedImageStorage> SharedImageStorage::create(std::size_t length) noexcept {
    if (length == 0 || length > static_cast<std::size_t>(std::numeric_limits<off_t>::max())) {
      return ds::none;
    }

    // The name is /tlr and 24 random hexadecimal digits, which leave it terminated in its zeroed
    // storage.
    constexpr std::string_view prefix = "/tlr";
    constexpr std::size_t nonce_bytes = 12;
    constexpr mode_t private_file_mode = 0600;
    SharedImageStorage storage;
    ds::Array<std::uint8_t, nonce_bytes> nonce{};
    const auto name = storage.name_.viewMut();

    randomBytes(nonce.dataMut(), nonce.size());
    std::ranges::copy(prefix, name.begin());
    encodeLowerHex(nonce.view(), name.subspan(prefix.size()));
    FileDescriptor descriptor{::shm_open(storage.name_.data(), combineFlags(O_CREAT, O_EXCL, O_RDWR), private_file_mode)}; // NOLINT(cppcoreguidelines-pro-type-vararg): shm_open's C signature is variadic
    if (!descriptor) {
      storage.name_.atMut(0) = '\0';
      return ds::none;
    }

    if (::ftruncate(descriptor.get(), static_cast<off_t>(length)) != 0) {
      return ds::none;
    }

    storage.mapping_ = MappedRegion{descriptor.get(), length, combineFlags(PROT_READ, PROT_WRITE)};
    if (!storage.mapping_) {
      return ds::none;
    }

    return storage;
  }

  SharedImageStorage::~SharedImageStorage() {
    if (name_[0] != '\0') {
      ::shm_unlink(name_.data());
    }
  }

  SharedImageStorage::SharedImageStorage(SharedImageStorage&& other) noexcept
      : name_(other.takeName()),
        mapping_(std::move(other.mapping_)) {}

  MappedRegion& SharedImageStorage::mapping() noexcept {
    return mapping_;
  }

  SharedImageStorage::Name SharedImageStorage::takeName() noexcept {
    auto name = name_;

    name_.atMut(0) = '\0';
    return name;
  }

}
