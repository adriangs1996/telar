export module telar.gui.platform.private_file_stamp;

import std;

export {
  namespace telar::gui::platform {

    struct PrivateFileStamp {
      std::uint64_t device = 0;
      std::uint64_t inode = 0;
      std::uint64_t size = 0;
      std::uint64_t links = 0;
      std::int64_t modified_seconds = 0;
      std::int64_t modified_nanoseconds = 0;
      std::int64_t changed_seconds = 0;
      std::int64_t changed_nanoseconds = 0;
      std::uint32_t mode = 0;
      std::uint32_t owner = 0;

      bool operator==(const PrivateFileStamp&) const = default;

      [[nodiscard]] static std::optional<PrivateFileStamp> read(const char* path) noexcept;
    };

  }
}
