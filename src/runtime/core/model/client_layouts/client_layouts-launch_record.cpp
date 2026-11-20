module telar.runtime.core.model.client_layouts;
import telar.base.ds;

namespace telar::runtime {

  template <Allocator Memory>
  LaunchRecord<Memory>::LaunchRecord(Memory& memory)
      : bytes_(memory) {}

  template <Allocator Memory>
  void LaunchRecord<Memory>::capture(std::span<const ds::String<Memory>> arguments, bool restorable) {
    bytes_.clear();
    count_ = 0;
    if (!restorable) {
      return;
    }

    // What a session checkpoint keeps of one launch.
    constexpr std::size_t maximum_arguments = 64;
    constexpr std::size_t maximum_bytes = std::size_t{128} * 1024;
    std::size_t size = 0;

    for (const auto& argument : arguments) {
      size += argument.size() + 1;
    }

    if (arguments.size() > maximum_arguments || size > maximum_bytes) {
      throw EncodingError{"Pane launch exceeds checkpoint limits"};
    }

    bytes_.reserve(size);
    for (const auto& argument : arguments) {
      bytes_.append(argument);
      bytes_.push('\0');
    }

    count_ = static_cast<std::uint16_t>(arguments.size());
  }

  template <Allocator Memory>
  void LaunchRecord<Memory>::restore(std::string_view arguments, std::uint16_t count) {
    bytes_.assign(arguments);
    count_ = count;
  }

  template <Allocator Memory>
  std::string_view LaunchRecord<Memory>::bytes() const noexcept {
    return bytes_;
  }

  template <Allocator Memory>
  std::uint16_t LaunchRecord<Memory>::count() const noexcept {
    return count_;
  }

  template class LaunchRecord<SystemAllocator>;
  template class LaunchRecord<ConcurrentMemory>;
  template LaunchRecord<Memory>::LaunchRecord(Memory& memory);
  template void LaunchRecord<Memory>::capture(std::span<const ds::String<Memory>> arguments, bool restorable);
  template LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::LaunchRecord(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory);
  template void LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::capture(std::span<const ds::String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>> arguments, bool restorable);

}
