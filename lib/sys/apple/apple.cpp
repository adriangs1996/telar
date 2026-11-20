module;
#include <mach/mach.h>
#include <sys/event.h>

module telar.sys.apple;

// The parentheses keep each name from expanding as the macro the body calls.
// NOLINTNEXTLINE(bugprone-easily-swappable-parameters): the parameters of the C macro EV_SET, in its order
void(EV_SET)(telar::sys::captured::Event* event, uintptr_t ident, int16_t filter, uint16_t flags, uint32_t filter_flags, intptr_t data, void* user_data) noexcept {
  EV_SET(event, ident, filter, flags, filter_flags, data, user_data);
}

mach_port_t(mach_task_self)() noexcept {
  return mach_task_self();
}
