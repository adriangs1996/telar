module;

#include "telar_base/memory/allocator.hpp"
#include "telar_client/serializers/telar_protocol.hpp"

export module telar.runtime.persistence.launch_record;


// Interface: persistence/launch_record.cppm
export {
namespace telar::runtime {

template <Allocator Memory>
class LaunchRecord {
public:
  inline explicit LaunchRecord(Memory &memory)
      : bytes_(AllocatorRef<char, Memory>{memory}) {}

  inline void capture(std::span<const String<Memory>> arguments, bool restorable) {
    bytes_.clear();
    count_ = 0;
    if (!restorable) {
      return;
    }

    std::size_t size = 0;
    for (const auto &argument : arguments) {
      size += argument.size() + 1;
    }
    if (arguments.size() > 64 || size > 128 * 1024) {
      throw EncodingError{"Pane launch exceeds checkpoint limits"};
    }

    bytes_.reserve(size);
    for (const auto &argument : arguments) {
      bytes_.append(argument);
      bytes_.push_back('\0');
    }
    count_ = static_cast<std::uint16_t>(arguments.size());
  }

  inline void restore(std::string_view arguments, std::uint16_t count) {
    bytes_.assign(arguments);
    count_ = count;
  }

  inline std::string_view bytes() const noexcept {
    return bytes_;
  }

  inline std::uint16_t count() const noexcept {
    return count_;
  }

private:
  String<Memory> bytes_;
  std::uint16_t count_ = 0;
};

}
}
