module;
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <fcntl.h>
#include <libproc.h>
#include <mach-o/dyld.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/mach_vm.h>
#include <net/if.h>
#include <net/if_dl.h>
#include <net/if_utun.h>
#include <net/route.h>
#include <netinet/in.h>
#include <netinet/in_pcb.h>
#include <netinet/tcp.h>
#include <netinet/tcp_fsm.h>
#include <netinet/tcp_var.h>
#include <netinet6/in6_var.h>
#include <pthread.h>
#include <spawn.h>
#include <sys/attr.h>
#include <sys/event.h>
#include <sys/ioctl.h>
#include <sys/kern_control.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/proc_info.h>
#include <sys/socket.h>
#include <sys/socketvar.h>
#include <sys/sys_domain.h>
#include <sys/sysctl.h>
#include <sys/un.h>
#include <unistd.h>

export module telar.sys.apple;

// Darwin only (MACOS_SOURCES in lib/sys/CMakeLists.txt). The C headers stay in this global
// module fragment only; importers reach their declarations through these
// using-declarations instead of including them.
export {
  // Process information.
  using ::in_sockinfo;
  using ::kinfo_proc;
  using ::proc_bsdinfo;
  using ::proc_bsdshortinfo;
  using ::proc_fdinfo;
  using ::proc_listallpids;
  using ::proc_listpids;
  using ::proc_name;
  using ::proc_pidfdinfo;
  using ::proc_pidinfo;
  using ::proc_pidpath;
  using ::proc_taskinfo;
  using ::proc_vnodepathinfo;
  using ::socket_fdinfo;
  using ::SOCKINFO_TCP;
  using ::sysctl;
  using ::sysctlbyname;

  // Event queues.
  using ::kevent;
  using ::kqueue;

  // Mach.
  using ::host_cpu_load_info_data_t;
  using ::host_info64_t;
  using ::host_processor_info;
  using ::host_statistics64;
  using ::kern_return_t;
  using ::mach_host_self;
  using ::mach_msg_type_number_t;
  using ::mach_port_deallocate;
  using ::mach_port_t;
  using ::mach_timebase_info;
  using ::mach_timebase_info_data_t;
  using ::mach_vm_address_t;
  using ::mach_vm_read_overwrite;
  using ::mach_vm_size_t;
  using ::natural_t;
  using ::processor_cpu_load_info_data_t;
  using ::processor_info_array_t;
  using ::task_info;
  using ::task_info_t;
  using ::task_vm_info_data_t;
  using ::vm_address_t;
  using ::vm_deallocate;
  using ::vm_size_t;
  using ::vm_statistics64_data_t;
  using ::xsw_usage;

  // The TCP control blocks the net.inet.tcp.pcblist64 sysctl returns.
  using ::xinpcb64;
  using ::xinpgen;
  using ::xsocket64;
  using ::xtcpcb64;

  // Routing messages, interface statistics and link-layer addresses.
  using ::if_msghdr2;
  using ::rt_msghdr;
  using ::sockaddr_dl;

  // Kernel controls and utun.
  using ::ctl_info;
  using ::in6_aliasreq;
  using ::sockaddr_ctl;

  // The running executable.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wreserved-identifier"
  using ::_NSGetExecutablePath; // NOLINT(bugprone-reserved-identifier,cert-dcl37-c,cert-dcl51-cpp): dyld's own name
#pragma clang diagnostic pop

  // BSD and Darwin extensions.
  using ::arc4random_buf;
  using ::attrlist;
  using ::attrreference_t;
  using ::devname_r;
  using ::getattrlist;
  using ::getmntinfo;
  using ::getpeereid;
  using ::posix_spawn_file_actions_addchdir;
  using ::pthread_threadid_np;
  using ::renameatx_np;
}

// Macros do not cross an import. Each one the tree reads is captured while the headers still
// define it, undefined, and exported under its own name, so `EVFILT_READ` reads the same to an
// importer that includes the header and to one that only imports this module.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_FILES(X)       \
  X(ATTR_BIT_MAP_COUNT)          \
  X(ATTR_CMN_NAME)               \
  X(CLOCK_UPTIME_RAW)            \
  X(FSOPT_NOFOLLOW)              \
  X(MNT_DONTBROWSE)              \
  X(MNT_LOCAL)                   \
  X(MNT_NOWAIT)                  \
  X(F_GETPATH)                   \
  X(F_GETNOSIGPIPE)              \
  X(F_SETNOSIGPIPE)              \
  X(MAXCOMLEN)                   \
  X(POSIX_SPAWN_CLOEXEC_DEFAULT) \
  X(RENAME_EXCL)

// kqueue filters and flags.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
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
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_PROCESSES(X) \
  X(CPU_STATE_IDLE)            \
  X(CPU_STATE_NICE)            \
  X(CPU_STATE_SYSTEM)          \
  X(CPU_STATE_USER)            \
  X(CTL_KERN)                  \
  X(CTL_VM)                    \
  X(HOST_CPU_LOAD_INFO)        \
  X(HOST_CPU_LOAD_INFO_COUNT)  \
  X(HOST_VM_INFO64)            \
  X(HOST_VM_INFO64_COUNT)      \
  X(INI_IPV4)                  \
  X(INI_IPV6)                  \
  X(KERN_PROC)                 \
  X(KERN_PROCARGS2)            \
  X(KERN_PROC_ALL)             \
  X(KERN_PROC_PID)             \
  X(KERN_SUCCESS)              \
  X(PROC_PGRP_ONLY)            \
  X(PROC_UID_ONLY)             \
  X(PROC_PIDFDSOCKETINFO)      \
  X(PROC_PIDLISTFDS)           \
  X(PROC_PIDPATHINFO_MAXSIZE)  \
  X(PROC_PIDTBSDINFO)          \
  X(PROCESSOR_CPU_LOAD_INFO)   \
  X(PROC_PIDTASKINFO)          \
  X(PROC_PIDT_SHORTBSDINFO)    \
  X(PROC_PIDVNODEPATHINFO)     \
  X(PROX_FDTYPE_SOCKET)        \
  X(SIDL)                      \
  X(SRUN)                      \
  X(SSLEEP)                    \
  X(SSTOP)                     \
  X(SZOMB)                     \
  X(TASK_VM_INFO)              \
  X(TASK_VM_INFO_COUNT)        \
  X(TSI_S_CLOSED)              \
  X(TSI_S_LISTEN)

// Sockets, kernel controls, utun, routes and the TCP control blocks.
// NOLINTNEXTLINE(cppcoreguidelines-macro-usage): an X-macro lists the C macros to capture, which no template can name
#define TELAR_SYS_NETWORK(X) \
  X(AF_LINK)                 \
  X(AF_SYSTEM)               \
  X(AF_SYS_CONTROL)          \
  X(CTLIOCGINFO)             \
  X(CTL_NET)                 \
  X(INP_IPV4)                \
  X(INP_IPV6)                \
  X(LOCAL_PEERPID)           \
  X(NET_RT_IFLIST2)          \
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
  X(RTM_IFINFO2)             \
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
#undef MNT_DONTBROWSE
#undef MNT_LOCAL
#undef MNT_NOWAIT
#undef F_GETPATH
#undef F_GETNOSIGPIPE
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
#undef CTL_VM
#undef HOST_CPU_LOAD_INFO
#undef HOST_CPU_LOAD_INFO_COUNT
#undef HOST_VM_INFO64
#undef HOST_VM_INFO64_COUNT
#undef INI_IPV4
#undef INI_IPV6
#undef KERN_PROCARGS2
#undef KERN_PROC
#undef KERN_PROC_ALL
#undef KERN_PROC_PID
#undef KERN_SUCCESS
#undef PROC_PGRP_ONLY
#undef PROC_UID_ONLY
#undef PROC_PIDFDSOCKETINFO
#undef PROC_PIDLISTFDS
#undef PROC_PIDPATHINFO_MAXSIZE
#undef PROC_PIDTBSDINFO
#undef PROC_PIDT_SHORTBSDINFO
#undef PROCESSOR_CPU_LOAD_INFO
#undef PROC_PIDTASKINFO
#undef PROC_PIDVNODEPATHINFO
#undef PROX_FDTYPE_SOCKET
#undef TASK_VM_INFO
#undef SIDL
#undef SRUN
#undef SSLEEP
#undef SSTOP
#undef SZOMB
#undef TASK_VM_INFO_COUNT
#undef TSI_S_CLOSED
#undef TSI_S_LISTEN
#undef AF_LINK
#undef AF_SYSTEM
#undef AF_SYS_CONTROL
#undef CTLIOCGINFO
#undef CTL_NET
#undef INP_IPV4
#undef INP_IPV6
#undef LOCAL_PEERPID
#undef NET_RT_IFLIST2
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
#undef RTM_IFINFO2
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
  TELAR_SYS_FILES(TELAR_SYS_CONSTANT)     // NOLINT(readability-identifier-naming): exported under the system's own names
  TELAR_SYS_EVENTS(TELAR_SYS_CONSTANT)    // NOLINT(readability-identifier-naming): exported under the system's own names
  TELAR_SYS_PROCESSES(TELAR_SYS_CONSTANT) // NOLINT(readability-identifier-naming): exported under the system's own names
  TELAR_SYS_NETWORK(TELAR_SYS_CONSTANT)   // NOLINT(readability-identifier-naming): exported under the system's own names

  // Darwin's private sockio.h defines these protocol attachments; the public SDK does not.
  inline constexpr unsigned long SIOCPROTOATTACH = _IOWR('i', 80, ifreq);             // NOLINT(readability-identifier-naming): exported under the system's own names
  inline constexpr unsigned long SIOCPROTOATTACH_IN6 = _IOWR('i', 110, in6_aliasreq); // NOLINT(readability-identifier-naming): exported under the system's own names

  // Defined in apple.cpp, where the macros are.
  // NOLINTNEXTLINE(readability-identifier-naming): exported under the system's own name
  void EV_SET(telar::sys::captured::Event* event, uintptr_t ident, int16_t filter, uint16_t flags, uint32_t filter_flags, intptr_t data, void* user_data) noexcept;

  // Darwin's macro reads the port its runtime caches at startup.
  // NOLINTNEXTLINE(readability-identifier-naming): exported under the system's own name
  mach_port_t mach_task_self() noexcept;
}

// Members that the headers reach through a macro have no name an importer can spell.
export namespace telar::sys {

  // The local IPv4 address of a TCP control block.
  inline constexpr const in_addr& localAddress(const xinpcb64& block) noexcept {
    return block.inp_laddr;
  }

  // When a process from the kernel's process list started.
  inline constexpr const timeval& processStarted(const kinfo_proc& process) noexcept {
    return process.kp_proc.p_starttime;
  }

  // The statfs the mount table lists; the function of the same name hides the struct's.
  using FileSystemStatus = struct statfs;

  // The foreign IPv4 address of a TCP control block.
  inline constexpr const in_addr& foreignAddress(const xinpcb64& block) noexcept {
    return block.inp_faddr;
  }

}
