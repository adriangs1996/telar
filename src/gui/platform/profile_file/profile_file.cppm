export module telar.gui.platform.profile_file;

import std;
import telar.tbc;

import telar.gui.core.primitives;
import telar.gui.platform.path_limits;
import telar.platform.fs;
import telar.platform.primitives;
import telar.vocabulary;

export {
  namespace telar::gui::platform {

    class InsecureProfileFile final : public std::runtime_error {
    public:
      InsecureProfileFile();
    };

    class ProfileFile;

    class ProfileOperationCancelled final : public std::exception {
    public:
      [[nodiscard]] const char* what() const noexcept override;
    };

    template <Allocator Memory>
    // The source bytes are allocated from memory, region `a`.
    [[nodiscard]] tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> readProfileSource(tbc::view<Memory&, tbc::lt::a> memory, int directory, std::string_view name);

    class ProfileFileTransaction {
      friend class ProfileFile;

    public:
      ProfileFileTransaction(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction& operator=(const ProfileFileTransaction&) = delete;
      ProfileFileTransaction(ProfileFileTransaction&&) noexcept = default;
      ProfileFileTransaction& operator=(ProfileFileTransaction&&) noexcept = default;
      ~ProfileFileTransaction() = default;

      template <Allocator Memory>
      [[nodiscard]] tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory) const;

      void replace(std::string_view source) const;

    private:
      ProfileFileTransaction(runtime::FileDescriptor parent, runtime::FileDescriptor lock, std::string_view name);

      runtime::FileDescriptor parent_;
      runtime::FileDescriptor lock_;
      std::array<char, PathLimits::component_bytes + 1> name_{};
    };

    class ProfileFile {
    public:
      explicit ProfileFile(std::string_view path, std::stop_token stop = {});

      template <Allocator Memory>
      [[nodiscard]] tbc::view<std::optional<Vector<Byte, Memory>>, tbc::lt::a> read(tbc::view<Memory&, tbc::lt::a> memory) const;

      [[nodiscard]] std::string_view path() const noexcept;
      [[nodiscard]] ProfileFileTransaction lock() const;

    private:
      std::array<char, PathLimits::path_bytes> path_{};
      std::size_t path_length_ = 0;
      std::size_t name_offset_ = 0;
      std::stop_token stop_;
    };

    extern template tbc::view<std::optional<Vector<Byte, telar::Memory>>, tbc::lt::a> readProfileSource<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory, int directory, std::string_view name);
    extern template tbc::view<std::optional<Vector<Byte, telar::ConcurrentMemory>>, tbc::lt::a> readProfileSource<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory, int directory, std::string_view name);
    extern template tbc::view<std::optional<Vector<Byte, telar::Memory>>, tbc::lt::a> ProfileFileTransaction::read<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory) const;
    extern template tbc::view<std::optional<Vector<Byte, telar::ConcurrentMemory>>, tbc::lt::a> ProfileFileTransaction::read<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory) const;
    extern template tbc::view<std::optional<Vector<Byte, telar::Memory>>, tbc::lt::a> ProfileFile::read<telar::Memory>(tbc::view<telar::Memory&, tbc::lt::a> memory) const;
    extern template tbc::view<std::optional<Vector<Byte, telar::ConcurrentMemory>>, tbc::lt::a> ProfileFile::read<telar::ConcurrentMemory>(tbc::view<telar::ConcurrentMemory&, tbc::lt::a> memory) const;

  }
}
