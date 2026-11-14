module;
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <net/if.h>
#include <net/if_utun.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/attr.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/param.h>
#include <sys/socket.h>
#include <sys/sys_domain.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>

export module telar.sys.apple;

// Darwin only (cmake/module_platforms.cmake). The C headers stay in this global
// module fragment only; importers reach their declarations through these
// using-declarations instead of including them.
export {
  // Process information.
  using ::proc_bsdinfo;
  using ::proc_fdinfo;
  using ::proc_listallpids;
  using ::proc_listpids;
  using ::proc_name;
  using ::proc_pidfdinfo;
  using ::proc_pidinfo;
  using ::proc_pidpath;
  using ::sysctl;
  using ::sysctlbyname;

  // Event queues.
  using ::kevent;
  using ::kqueue;

  // Mach.
  using ::host_statistics64;
  using ::kern_return_t;
  using ::mach_host_self;
  using ::mach_port_deallocate;
  using ::mach_port_t;
  using ::mach_vm_address_t;
  using ::mach_vm_read_overwrite;
  using ::mach_vm_size_t;
  using ::task_info;

  // The running executable.
  using ::_NSGetExecutablePath;

  // BSD and Darwin extensions.
  using ::arc4random_buf;
  using ::attrlist;
  using ::attrreference_t;
  using ::devname_r;
  using ::getattrlist;
  using ::getpeereid;
  using ::posix_spawn_file_actions_addchdir;
  using ::pthread_threadid_np;
  using ::renameatx_np;
}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `EVFILT_READ` reads the same to an
// importer that includes the header and to one that only imports this module.
#define TELAR_SYS_FILES(X)       \
  X(ATTR_BIT_MAP_COUNT)          \
  X(ATTR_CMN_NAME)               \
  X(CLOCK_UPTIME_RAW)            \
  X(FSOPT_NOFOLLOW)              \
  X(F_SETNOSIGPIPE)              \
  X(MAXCOMLEN)                   \
  X(POSIX_SPAWN_CLOEXEC_DEFAULT) \
  X(RENAME_EXCL)

// kqueue filters and flags.
#define TELAR_SYS_EVENTS(X) \
  X(EVFILT_READ)            \
  X(EVFILT_SIGNAL)          \
  X(EVFILT_WRITE)           \
  X(EV_ADD)                 \
  X(EV_DELETE)              \
  X(EV_DISABLE)             \
  X(EV_ENABLE)              \
  X(EV_EOF)                 \
  X(EV_ERROR)

// Mach host and task statistics, sysctl and libproc.
#define TELAR_SYS_PROCESSES(X) \
  X(CPU_STATE_IDLE)            \
  X(CPU_STATE_NICE)            \
  X(CPU_STATE_SYSTEM)          \
  X(CPU_STATE_USER)            \
  X(CTL_KERN)                  \
  X(HOST_CPU_LOAD_INFO)        \
  X(HOST_CPU_LOAD_INFO_COUNT)  \
  X(HOST_VM_INFO64)            \
  X(HOST_VM_INFO64_COUNT)      \
  X(INI_IPV4)                  \
  X(INI_IPV6)                  \
  X(KERN_PROCARGS2)            \
  X(KERN_SUCCESS)              \
  X(PROC_PGRP_ONLY)            \
  X(PROC_PIDFDSOCKETINFO)      \
  X(PROC_PIDLISTFDS)           \
  X(PROC_PIDPATHINFO_MAXSIZE)  \
  X(PROC_PIDTBSDINFO)          \
  X(PROC_PIDT_SHORTBSDINFO)    \
  X(PROC_PIDVNODEPATHINFO)     \
  X(PROX_FDTYPE_SOCKET)        \
  X(TASK_VM_INFO)              \
  X(TASK_VM_INFO_COUNT)        \
  X(TSI_S_CLOSED)              \
  X(TSI_S_LISTEN)

// Sockets, kernel controls, utun, routes and the TCP control blocks.
#define TELAR_SYS_NETWORK(X) \
  X(AF_LINK)                 \
  X(AF_SYSTEM)               \
  X(AF_SYS_CONTROL)          \
  X(CTLIOCGINFO)             \
  X(INP_IPV4)                \
  X(INP_IPV6)                \
  X(LOCAL_PEERPID)           \
  X(PF_SYSTEM)               \
  X(RTAX_GATEWAY)            \
  X(RTAX_MAX)                \
  X(RTA_DST)                 \
  X(RTA_IFP)                 \
  X(RTF_BLACKHOLE)           \
  X(RTF_GATEWAY)             \
  X(RTF_HOST)                \
  X(RTF_IFSCOPE)             \
  X(RTF_REJECT)              \
  X(RTF_UP)                  \
  X(RTM_GET)                 \
  X(RTM_VERSION)             \
  X(SIOCIFCREATE)            \
  X(SIOCIFDESTROY)           \
  X(SOL_LOCAL)               \
  X(SO_NOSIGPIPE)            \
  X(SYSPROTO_CONTROL)        \
  X(TCPS_SYN_RECEIVED)       \
  X(TCP_KEEPALIVE)           \
  X(UTUN_CONTROL_NAME)       \
  X(UTUN_OPT_IFNAME)

namespace telar::sys::captured {

#define TELAR_SYS_CAPTURE(name) inline constexpr auto name##_ = name;
  TELAR_SYS_FILES(TELAR_SYS_CAPTURE)
  TELAR_SYS_EVENTS(TELAR_SYS_CAPTURE)
  TELAR_SYS_PROCESSES(TELAR_SYS_CAPTURE)
  TELAR_SYS_NETWORK(TELAR_SYS_CAPTURE)

  // The kevent function hides the struct's name, and an export cannot redeclare it.
  using Event = struct kevent;

}

#undef ATTR_BIT_MAP_COUNT
#undef ATTR_CMN_NAME
#undef CLOCK_UPTIME_RAW
#undef FSOPT_NOFOLLOW
#undef F_SETNOSIGPIPE
#undef MAXCOMLEN
#undef POSIX_SPAWN_CLOEXEC_DEFAULT
#undef RENAME_EXCL
#undef EVFILT_READ
#undef EVFILT_SIGNAL
#undef EVFILT_WRITE
#undef EV_ADD
#undef EV_DELETE
#undef EV_DISABLE
#undef EV_ENABLE
#undef EV_EOF
#undef EV_ERROR
#undef CPU_STATE_IDLE
#undef CPU_STATE_NICE
#undef CPU_STATE_SYSTEM
#undef CPU_STATE_USER
#undef CTL_KERN
#undef HOST_CPU_LOAD_INFO
#undef HOST_CPU_LOAD_INFO_COUNT
#undef HOST_VM_INFO64
#undef HOST_VM_INFO64_COUNT
#undef INI_IPV4
#undef INI_IPV6
#undef KERN_PROCARGS2
#undef KERN_SUCCESS
#undef PROC_PGRP_ONLY
#undef PROC_PIDFDSOCKETINFO
#undef PROC_PIDLISTFDS
#undef PROC_PIDPATHINFO_MAXSIZE
#undef PROC_PIDTBSDINFO
#undef PROC_PIDT_SHORTBSDINFO
#undef PROC_PIDVNODEPATHINFO
#undef PROX_FDTYPE_SOCKET
#undef TASK_VM_INFO
#undef TASK_VM_INFO_COUNT
#undef TSI_S_CLOSED
#undef TSI_S_LISTEN
#undef AF_LINK
#undef AF_SYSTEM
#undef AF_SYS_CONTROL
#undef CTLIOCGINFO
#undef INP_IPV4
#undef INP_IPV6
#undef LOCAL_PEERPID
#undef PF_SYSTEM
#undef RTAX_GATEWAY
#undef RTAX_MAX
#undef RTA_DST
#undef RTA_IFP
#undef RTF_BLACKHOLE
#undef RTF_GATEWAY
#undef RTF_HOST
#undef RTF_IFSCOPE
#undef RTF_REJECT
#undef RTF_UP
#undef RTM_GET
#undef RTM_VERSION
#undef SIOCIFCREATE
#undef SIOCIFDESTROY
#undef SOL_LOCAL
#undef SO_NOSIGPIPE
#undef SYSPROTO_CONTROL
#undef TCPS_SYN_RECEIVED
#undef TCP_KEEPALIVE
#undef UTUN_CONTROL_NAME
#undef UTUN_OPT_IFNAME
#undef EV_SET
#undef mach_task_self

#define TELAR_SYS_CONSTANT(name) inline constexpr auto name = telar::sys::captured::name##_;

export {
  TELAR_SYS_FILES(TELAR_SYS_CONSTANT)
  TELAR_SYS_EVENTS(TELAR_SYS_CONSTANT)
  TELAR_SYS_PROCESSES(TELAR_SYS_CONSTANT)
  TELAR_SYS_NETWORK(TELAR_SYS_CONSTANT)

  // Defined in apple.cpp, where the macros are.
  void EV_SET(telar::sys::captured::Event* event, uintptr_t ident, int16_t filter, uint16_t flags, uint32_t filter_flags, intptr_t data, void* user_data) noexcept;

  // Darwin's macro reads the port its runtime caches at startup.
  mach_port_t mach_task_self() noexcept;
}

// Members that the headers reach through a macro have no name an importer can spell.
export namespace telar::sys {

  // The local IPv4 address of a TCP control block.
  inline constexpr const in_addr& localAddress(const xinpcb64& block) noexcept {
    return block.inp_laddr;
  }

  // The foreign IPv4 address of a TCP control block.
  inline constexpr const in_addr& foreignAddress(const xinpcb64& block) noexcept {
    return block.inp_faddr;
  }

}
