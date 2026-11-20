export module telar.runtime.core.model.client_layouts:launch_record;

import std;

import telar.base.memory.allocators;
import telar.base.ds;

// Interface: persistence/launch_record.cppm
export {
  namespace telar::runtime {

    template <Allocator Memory>
    class LaunchRecord {
    public:
      explicit LaunchRecord(Memory& memory);

      void capture(std::span<const ds::String<Memory>> arguments, bool restorable);
      void restore(std::string_view arguments, std::uint16_t count);
      [[nodiscard]] std::string_view bytes() const noexcept;
      [[nodiscard]] std::uint16_t count() const noexcept;

    private:
      ds::String<Memory> bytes_;
      std::uint16_t count_ = 0;
    };

    extern template class LaunchRecord<SystemAllocator>;
    extern template class LaunchRecord<ConcurrentMemory>;
    extern template LaunchRecord<Memory>::LaunchRecord(Memory& memory);
    extern template void LaunchRecord<Memory>::capture(std::span<const ds::String<Memory>> arguments, bool restorable);
    extern template LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::LaunchRecord(SynchronizedAllocator<BudgetAllocator<SystemAllocator>>& memory);
    extern template void LaunchRecord<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>::capture(std::span<const ds::String<SynchronizedAllocator<BudgetAllocator<SystemAllocator>>>> arguments, bool restorable);

  }
}
