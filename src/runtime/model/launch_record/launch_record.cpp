module telar.runtime.model.launch_record;

namespace telar::runtime {

  template <Allocator Memory>
  LaunchRecord<Memory>::LaunchRecord(Memory& memory)
      : bytes_(AllocatorRef<char, Memory>{memory}) {}

  template <Allocator Memory>
  void LaunchRecord<Memory>::capture(std::span<const String<Memory>> arguments, bool restorable) {
    bytes_.clear();
    count_ = 0;
    if (!restorable) {
      return;
    }

    std::size_t size = 0;

    for (const auto& argument : arguments) {
      size += argument.size() + 1;
    }

    if (arguments.size() > 64 || size > 128 * 1024) {
      throw EncodingError{"Pane launch exceeds checkpoint limits"};
    }

    bytes_.reserve(size);
    for (const auto& argument : arguments) {
      bytes_.append(argument);
      bytes_.push_back('\0');
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
  template void LaunchRecord<Memory>::capture(std::span<const String<Memory>> arguments, bool restorable);
  template LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::LaunchRecord(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory);
  template void LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::capture(std::span<const String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>> arguments, bool restorable);

}
