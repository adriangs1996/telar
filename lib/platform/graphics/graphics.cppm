export module telar.platform.graphics;

import std;

import telar.platform.primitives;
import telar.base.ds;

// Interface: telar_platform/graphics/shared_image_storage.cppm
export {
  namespace telar::runtime {

    class SharedImageStorage {
    public:
      static constexpr std::size_t name_bytes = 32;
      using Name = ds::Array<char, name_bytes>;

      static ds::Option<SharedImageStorage> create(std::size_t length) noexcept;

      ~SharedImageStorage();

      SharedImageStorage(const SharedImageStorage&) = delete;
      SharedImageStorage& operator=(const SharedImageStorage&) = delete;

      SharedImageStorage(SharedImageStorage&& other) noexcept;
      SharedImageStorage& operator=(SharedImageStorage&&) = delete;

      MappedRegion& mapping() noexcept;
      Name takeName() noexcept;

    private:
      SharedImageStorage() noexcept = default;

      Name name_{};
      MappedRegion mapping_;
    };

  }
}
