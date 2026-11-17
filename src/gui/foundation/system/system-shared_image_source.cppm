export module telar.gui.foundation.system:shared_image_source;

import std;

import telar.platform.primitives;

export {
  namespace telar::gui::inline foundation::inline system {

    class SharedImageSource {
    public:
      explicit SharedImageSource(std::string_view name);
      ~SharedImageSource() = default;
      SharedImageSource(const SharedImageSource&) = delete;
      SharedImageSource& operator=(const SharedImageSource&) = delete;
      SharedImageSource(SharedImageSource&&) noexcept = default;
      SharedImageSource& operator=(SharedImageSource&&) noexcept = default;

      [[nodiscard]] bool read(std::span<std::uint8_t> destination) const noexcept;

    private:
      runtime::FileDescriptor descriptor_;
    };

  }
}
