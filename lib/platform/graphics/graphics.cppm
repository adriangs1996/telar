export module telar.platform.graphics;

import std;

import telar.platform.primitives;

// Interface: telar_platform/graphics/shared_image_storage.cppm
export {
  namespace telar::runtime {

    class SharedImageStorage {
    public:
      using Name = std::array<char, 32>;

      static std::optional<SharedImageStorage> create(std::size_t length) noexcept;

      ~SharedImageStorage();

      SharedImageStorage(const SharedImageStorage&) = delete;
      SharedImageStorage& operator=(const SharedImageStorage&) = delete;

      SharedImageStorage(SharedImageStorage&& other) noexcept;

      MappedRegion& mapping() noexcept;
      Name takeName() noexcept;

    private:
      SharedImageStorage() noexcept = default;

      Name name_{};
      MappedRegion mapping_;
    };

  }
}
