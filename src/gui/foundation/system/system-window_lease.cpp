module telar.gui.foundation.system;

import std;
import telar.tbc;

import telar.platform.fs;
import telar.sys.posix;
import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

  namespace {

    // open(2) and flock(2) take their flags as an int; the bits are combined unsigned.
    template <std::same_as<int>... Flag>
    constexpr int combineFlags(Flag... flags) noexcept {
      return static_cast<int>((0U | ... | static_cast<unsigned>(flags)));
    }

    // The filename is written into the output, region `a`.
    tbc::val_a<std::string_view> lockFilename(tbc::val_a<std::span<char>> output, std::string_view basename, unsigned slot) {
      constexpr std::string_view prefix = ".gui-";
      constexpr std::string_view suffix = ".lock";
      if (basename.size() + prefix.size() + suffix.size() >= output.size()) {
        throw std::runtime_error{"GUI identity filename exceeds capacity"};
      }

      auto* next = std::ranges::copy(basename, output.data()).out;

      next = std::ranges::copy(prefix, next).out;
      const auto formatted = std::to_chars(next, output.data() + output.size() - suffix.size(), slot);
      if (formatted.ec == std::errc::value_too_large) {
        throw std::runtime_error{"GUI identity filename exceeds capacity"};
      }

      next = formatted.ptr;

      const auto* end = std::ranges::copy(suffix, next).out;

      return {output.data(), static_cast<std::size_t>(end - output.data())};
    }

    void validateFile(int descriptor) {
      struct stat metadata{};
      constexpr mode_t permission_mask = 07777;
      constexpr mode_t required_permissions = 0600;
      if (::fstat(descriptor, &metadata) != 0 || !S_ISREG(metadata.st_mode) || metadata.st_uid != ::geteuid() || metadata.st_nlink != 1 || (metadata.st_mode & permission_mask) != required_permissions) {
        throw std::runtime_error{"Unsafe GUI identity lock file"};
      }
    }

  }

  WindowLease::WindowLease(std::string_view endpoint) {
    if (endpoint.empty() || endpoint.front() != '/' || endpoint.back() == '/' || endpoint.contains('\0') || endpoint.size() >= PATH_MAX) {
      throw std::runtime_error{"Invalid runtime endpoint path"};
    }

    const auto separator = endpoint.rfind('/');
    const auto directory_name = endpoint.substr(0, separator == 0 ? 1 : separator);
    const auto basename = endpoint.substr(separator + 1);
    ds::Array<char, PATH_MAX> directory_path{};

    std::ranges::copy(directory_name, directory_path.viewMut().begin());
    const auto directory = runtime::openPrivateParent(endpoint);

    if (::realpath(directory_path.dataMut(), canonical_endpoint_.dataMut()) == nullptr) {
      throw std::runtime_error{"Cannot resolve runtime endpoint directory"};
    }

    const auto canonical_length = std::strlen(canonical_endpoint_.data());
    if (canonical_length + basename.size() + 1 >= canonical_endpoint_.size()) {
      throw std::runtime_error{"Canonical runtime endpoint exceeds path capacity"};
    }

    canonical_endpoint_.atMut(canonical_length) = '/';
    std::ranges::copy(basename, canonical_endpoint_.viewMut().subspan(canonical_length + 1).begin());
    endpoint_length_ = canonical_length + 1 + basename.size();
    canonical_endpoint_.atMut(endpoint_length_) = '\0';

    for (unsigned slot = 0; slot < maximum_windows; ++slot) {
      ds::Array<char, NAME_MAX> filename{};
      const auto name = lockFilename(filename.viewMut(), basename, slot);
      constexpr mode_t private_file_permissions = 0600;
      auto file = runtime::openBeneath(directory.get(), name, combineFlags(O_RDWR, O_CREAT), private_file_permissions);

      validateFile(file.get());
      if (::flock(file.get(), combineFlags(LOCK_EX, LOCK_NB)) != 0) {
        if (sys::lastError() == EWOULDBLOCK) {
          continue;
        }

        throw std::runtime_error{"Cannot lock GUI identity file"};
      }

      slot_ = slot;
      descriptor_ = file.release();

      return;
    }

    throw std::runtime_error{"No free GUI window identity slot"};
  }

  WindowLease::~WindowLease() {
    if (descriptor_ >= 0) {
      ::close(descriptor_);
    }
  }

  unsigned WindowLease::slot() const noexcept {
    return slot_;
  }

  std::string_view WindowLease::endpoint() const noexcept {
    return {canonical_endpoint_.data(), endpoint_length_};
  }

}
