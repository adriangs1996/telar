module telar.gui.foundation.system;

import std;
import telar.sys.posix;

import telar.platform.error;
import telar.machines;
import telar.platform.fs;
import telar.gui.foundation.text;
import telar.wire.vocabulary;
import telar.gui.foundation.core;
import telar.platform.primitives;
import telar.base.ds;

namespace telar::gui::inline foundation::inline system {

  namespace {

    struct PrivateMode {
      static constexpr mode_t file = 0600;
      static constexpr mode_t shared = 0077;
    };

    void requirePrivateRegularFile(int descriptor) {
      struct stat state{};
      if (::fstat(descriptor, &state) != 0) {
        throw runtime::SystemError{"Inspect machine profile file"};
      }

      if (!S_ISREG(state.st_mode) || state.st_uid != ::geteuid() || (state.st_mode & PrivateMode::shared) != 0) {
        throw InsecureProfileFile{};
      }
    }

    runtime::FileDescriptor openProfileLockFile(int directory, std::string_view name) {
      try {
        try {
          return runtime::openBeneath(directory, name, O_RDWR | O_CREAT | O_EXCL, PrivateMode::file);
        } catch (const runtime::SystemError& error) {
          if (error.code() != EEXIST) {
            throw;
          }
        }

        return runtime::openBeneath(directory, name, O_RDWR);
      } catch (const runtime::SystemError& error) {
        if (error.code() == ELOOP) {
          throw InsecureProfileFile{};
        }

        throw runtime::SystemError{"Open machine profile lock", error.code()};
      }
    }

    void waitForProfileLock(int descriptor, const std::stop_token& stop) {
      std::binary_semaphore cancellation{0};
      const std::stop_callback notify_stop{stop, [&cancellation] {
                                             cancellation.release();
                                           }};

      constexpr auto retry_interval = std::chrono::milliseconds{20};

      for (;;) {
        if (stop.stop_requested()) {
          throw ProfileOperationCancelled{};
        }

        if (::flock(descriptor, LOCK_EX | LOCK_NB) == 0) {
          return;
        }

        if (sys::lastError() == EINTR) {
          continue;
        }

        if (sys::lastError() != EWOULDBLOCK && sys::lastError() != EAGAIN) {
          throw runtime::SystemError{"Lock machine profiles"};
        }

        static_cast<void>(cancellation.try_acquire_for(retry_interval));
      }
    }

    class TemporaryProfileFile {
    public:
      explicit TemporaryProfileFile(int parent)
          : parent_(parent) {
        constexpr unsigned maximum_attempts = 8;

        for (unsigned attempt = 0; attempt < maximum_attempts; ++attempt) {
          generateName();
          try {
            file_ = runtime::openBeneath(parent_, name_.data(), O_WRONLY | O_CREAT | O_EXCL, PrivateMode::file);

            return;
          } catch (const runtime::SystemError& error) {
            if (error.code() != EEXIST) {
              throw runtime::SystemError{"Create temporary machine profile file", error.code()};
            }
          }
        }

        throw runtime::SystemError{"Create unique machine profile file", EEXIST};
      }

      ~TemporaryProfileFile() {
        if (!committed_) {
          ::unlinkat(parent_, name_.data(), 0);
        }
      }

      TemporaryProfileFile(const TemporaryProfileFile&) = delete;
      TemporaryProfileFile& operator=(const TemporaryProfileFile&) = delete;
      TemporaryProfileFile(TemporaryProfileFile&&) = delete;
      TemporaryProfileFile& operator=(TemporaryProfileFile&&) = delete;

      void replace(const char* destination, std::string_view source) {
        if (const auto failure = runtime::writeDescriptor(file_.get(), byteView(source)); failure != 0) {
          throw runtime::SystemError{"Write machine profiles", failure};
        }

        if (::fsync(file_.get()) != 0) {
          throw runtime::SystemError{"Sync machine profiles"};
        }

        file_.reset();
        if (::renameat(parent_, name_.data(), parent_, destination) != 0) {
          throw runtime::SystemError{"Replace machine profiles"};
        }

        committed_ = true;
      }

    private:
      static constexpr std::string_view prefix = ".telar-machine-profile-";
      static constexpr std::string_view hexadecimal = "0123456789abcdef";
      static constexpr std::size_t nonce_bytes = 16;
      static constexpr unsigned hexadecimal_bits = 4;

      void generateName() {
        ds::Array<std::uint8_t, nonce_bytes> nonce{};

        SecureRandom::fill(nonce.viewMut());

        std::ranges::copy(prefix, name_.viewMut().begin());
        auto position = prefix.size();

        for (const auto byte : nonce) {
          name_.atMut(position++) = hexadecimal[byte >> hexadecimal_bits];
          name_.atMut(position++) = hexadecimal[byte % hexadecimal.size()];
        }
      }

      int parent_;
      ds::Array<char, prefix.size() + (nonce_bytes * 2) + 1> name_{};
      runtime::FileDescriptor file_;
      bool committed_ = false;
    };

  }

  InsecureProfileFile::InsecureProfileFile()
      : std::runtime_error("InsecureFile") {}

  const char* ProfileOperationCancelled::what() const noexcept {
    return "Machine profile operation cancelled";
  }

  template <Allocator Memory>
  tbc::view<ds::Option<ds::Vec<Byte, Memory>>, tbc::lt::a> readProfileSource(tbc::view<Memory&, tbc::lt::a> memory, int directory, std::string_view name) {
    ds::Vec<Byte, Memory> bytes{memory};

    try {
      if (!runtime::readPrivateFile(directory, name, bytes, runtime::machines::MachineLimits::file_bytes)) {
        return ds::none;
      }
    } catch (const runtime::SystemError& error) {
      if (error.code() == EACCES || error.code() == ELOOP || error.code() == EISDIR) {
        throw InsecureProfileFile{};
      }

      throw;
    }

    return bytes;
  }

  template <Allocator Memory>
  tbc::view<ds::Option<ds::Vec<Byte, Memory>>, tbc::lt::a> ProfileFileTransaction::read(tbc::view<Memory&, tbc::lt::a> memory) const {
    return readProfileSource(memory, parent_.get(), name_.data());
  }

  template <Allocator Memory>
  tbc::view<ds::Option<ds::Vec<Byte, Memory>>, tbc::lt::a> ProfileFile::read(tbc::view<Memory&, tbc::lt::a> memory) const {
    return readProfileSource(memory, AT_FDCWD, path());
  }

  template tbc::view<ds::Option<ds::Vec<Byte, telar::Memory>>, tbc::lt::a> readProfileSource<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory, int directory, std::string_view name);
  template tbc::view<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>, tbc::lt::a> readProfileSource<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory, int directory, std::string_view name);
  template tbc::view<ds::Option<ds::Vec<Byte, telar::Memory>>, tbc::lt::a> ProfileFileTransaction::read<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory) const;
  template tbc::view<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>, tbc::lt::a> ProfileFileTransaction::read<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory) const;
  template tbc::view<ds::Option<ds::Vec<Byte, telar::Memory>>, tbc::lt::a> ProfileFile::read<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory) const;
  template tbc::view<ds::Option<ds::Vec<Byte, telar::ConcurrentMemory>>, tbc::lt::a> ProfileFile::read<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory) const;

  ProfileFile::ProfileFile(std::string_view path, std::stop_token stop)
      : stop_(std::move(stop)) {
    if (path.empty() || path.contains('\0') || path.ends_with('/')) {
      throw runtime::SystemError{"Invalid machine profile path", EINVAL};
    }

    BoundedText<PathLimits::path_bytes - 1> absolute;

    if (!path.starts_with('/')) {
      ds::Array<char, PathLimits::path_bytes> current{};
      if (::getcwd(current.dataMut(), current.size()) == nullptr) {
        throw runtime::SystemError{"Resolve machine profile directory"};
      }

      absolute.append(current.data());
      absolute.append("/");
    }

    absolute.append(path);
    path_length_ = absolute.view().size();
    std::ranges::copy(absolute.view(), path_.viewMut().begin());
    name_offset_ = absolute.view().rfind('/') + 1;
    const auto name = absolute.view().substr(name_offset_);
    if (name == "." || name == ".." || name.size() > PathLimits::component_bytes) {
      throw runtime::SystemError{"Invalid machine profile file name", EINVAL};
    }
  }

  std::string_view ProfileFile::path() const noexcept {
    return {path_.data(), path_length_};
  }

  ProfileFileTransaction ProfileFile::lock() const {
    ds::Array<char, PathLimits::path_bytes> parent_path{};
    const auto parent_length = std::max<std::size_t>(1, name_offset_ - 1);

    std::copy_n(path_.begin(), parent_length, parent_path.dataMut());
    runtime::createPrivateDirectory({parent_path.data(), parent_length});
    auto parent = runtime::openPrivateParent(path());
    const auto name = path().substr(name_offset_);
    constexpr std::string_view lock_suffix = ".lock";
    BoundedText<PathLimits::component_bytes> lock_name;

    lock_name.append(name);
    lock_name.append(lock_suffix);
    auto held = openProfileLockFile(parent.get(), lock_name.view());

    requirePrivateRegularFile(held.get());
    waitForProfileLock(held.get(), stop_);

    return {std::move(parent), std::move(held), name};
  }

  ProfileFileTransaction::ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name)
      : parent_(std::move(parent)),
        lock_(std::move(lock)) {
    std::ranges::copy(name, name_.viewMut().begin());
  }

  void ProfileFileTransaction::replace(std::string_view source) const {
    TemporaryProfileFile temporary{parent_.get()};

    temporary.replace(name_.data(), source);
  }

}
