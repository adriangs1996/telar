export module telar.gui.foundation.system:private_file_stamp;

import std;
import telar.base.ds;

export {
  namespace telar::gui::inline foundation::inline system {

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

      [[nodiscard]] static ds::Option<PrivateFileStamp> read(const char* path) noexcept;
    };

  }
}
