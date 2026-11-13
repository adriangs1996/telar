module;
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <pthread.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/attr.h>
#include <sys/event.h>
#include <sys/sysctl.h>
#include <unistd.h>

export module telar.sys.apple;

// Darwin only (cmake/module_platforms.cmake). The C headers stay in this global
// module fragment only; importers reach their declarations through these
// using-declarations instead of including them.
export {
  // Process information.
  using ::proc_bsdinfo;
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

  // BSD and Darwin extensions.
  using ::arc4random_buf;
  using ::attrlist;
  using ::devname_r;
  using ::getattrlist;
  using ::getpeereid;
  using ::posix_spawn_file_actions_addchdir;
  using ::pthread_threadid_np;
  using ::renameatx_np;
}
