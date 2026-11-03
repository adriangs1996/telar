#include <errno.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/event.h>

int tab_switch_clock_open(void) {
    return kqueue();
}

int tab_switch_clock_wait(int descriptor, uint64_t deadline) {
    struct kevent change, event;
    EV_SET(&change, 1, EVFILT_TIMER, EV_ADD | EV_ONESHOT,
           NOTE_ABSOLUTE | NOTE_MACHTIME | NOTE_CRITICAL, deadline, NULL);
    int result = kevent(descriptor, &change, 1, &event, 1, NULL);
    if (result < 0) {
        return errno == EINTR ? 0 : errno;
    }

    if (result != 1 || event.filter != EVFILT_TIMER || event.ident != 1) {
        return EIO;
    }

    return event.flags & EV_ERROR ? (int)event.data : 0;
}
