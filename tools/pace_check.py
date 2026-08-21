"""Drives the real ui_spike binary through a pty and checks that a burst of
input does not become a burst of frames."""
import os, pty, re, select, subprocess, sys, time

BIN = "/Users/adriangonzalez/sandbox/mitm-spike/zig-out/bin/ui_spike"
FOOTER = re.compile(rb"frames=(\d+) absorbed=(\d+) dropped=(\d+) throttled=(\d+)")

def run(burst, label):
    pid, fd = pty.fork()
    if pid == 0:
        os.environ["TERM"] = "xterm-256color"
        os.execv(BIN, [BIN])
    import fcntl, struct, termios
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))

    out = bytearray()
    def drain(seconds):
        end = time.time() + seconds
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], max(0, end - time.time()))
            if not r: break
            try: chunk = os.read(fd, 65536)
            except OSError: break
            if not chunk: break
            out.extend(chunk)

    drain(0.6)                       # first frame
    start = time.time()
    # In chunks, draining between them. A pty has a small buffer in both
    # directions: writing the whole burst at once blocks us as soon as it fills,
    # and the app blocks writing its frames as soon as *its* side fills, which
    # is a deadlock in the harness rather than a fault in the program.
    at = 0
    while at < len(burst):
        at += os.write(fd, burst[at:at + 256])
        drain(0.02)
    elapsed_write = time.time() - start
    drain(1.2)
    os.write(fd, b"q")
    drain(0.4)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
    os.close(fd)

    hits = FOOTER.findall(bytes(out))
    if not hits:
        print(f"{label}: SIN RESUMEN"); globals()["ok"] = False; return None
    frame, absorbed, dropped, _thr = (int(x) for x in hits[-1])
    print(f"{label}: frames={frame} absorbed={absorbed} dropped={dropped}")
    return frame, absorbed, dropped

# 300 movimientos de ratón: la coalescencia debe descartar casi todos.
moves = b"".join(b"\x1b[<35;%d;%dM" % (10 + i % 40, 5 + i % 15) for i in range(300))
a = run(moves, "300 movimientos de raton")

# 300 pulsaciones de flecha: NINGUNA puede perderse, pero deben caber en pocos frames.
keys = b"\x1b[B" * 300
b = run(keys, "300 flechas abajo    ")

ok = True
if a:
    f, ab, dr = a
    if dr < 200: print("  FALLO: se esperaban >200 descartados"); ok = False
    if f > 60:   print(f"  FALLO: {f} frames para 300 eventos"); ok = False
if b:
    f, ab, dr = b
    if dr != 0:  print(f"  FALLO: se descartaron {dr} pulsaciones"); ok = False
    if ab < 200: print(f"  FALLO: solo {ab} absorbidas"); ok = False
    if f > 60:   print(f"  FALLO: {f} frames para 300 pulsaciones"); ok = False
print("OK" if ok else "HAY FALLOS")
sys.exit(0 if ok else 1)
