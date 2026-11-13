import os
import signal
import sys


def main():
    if len(sys.argv) < 2:
        raise SystemExit('Usage: foreground_fixture.py EXECUTABLE [ARGUMENTS...]')
    child = os.fork()
    if child == 0:
        os.setpgid(0, 0)
        os.kill(os.getpid(), signal.SIGSTOP)
        os.execv(sys.argv[1], sys.argv[1:])
    os.waitpid(child, os.WUNTRACED)
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    os.tcsetpgrp(0, child)
    os.kill(child, signal.SIGCONT)
    _, status = os.waitpid(child, 0)
    raise SystemExit(os.waitstatus_to_exitcode(status))


if __name__ == '__main__':
    main()
