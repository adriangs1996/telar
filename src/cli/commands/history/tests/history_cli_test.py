#!/usr/bin/env python3
"""`telar history` against a private runtime: imports of every source format, the list, search,
prune, stats and export commands, as a user runs them and reads what they print."""

import argparse
import contextlib
import datetime
import json
import os
from pathlib import Path
import pty
import re
import select
import shutil
import signal
import sqlite3
import subprocess
import sys
import tempfile
import time


class Fixture:
    def __init__(self, binary, root):
        self.binary = Path(binary).resolve()
        self.root = Path(root).resolve()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith("TELAR_")}
        for key, name in (("HOME", "home"), ("XDG_RUNTIME_DIR", "run"), ("XDG_DATA_HOME", "data"),
                          ("XDG_CONFIG_HOME", "config"), ("XDG_STATE_HOME", "state"), ("TMPDIR", "tmp")):
            directory = self.root / name
            directory.mkdir(exist_ok=True, mode=0o700)
            self.env[key] = str(directory)
        self.socket = self.root / "s"
        self.checks = 0

    def run(self, *args, data=b"", code=0, cwd=None):
        argv = [str(self.binary), "history", *map(str, args), "--socket", str(self.socket)]
        result = subprocess.run(argv, env=self.env, input=data, capture_output=True, cwd=cwd or self.root, timeout=120)
        if code is not None:
            assert result.returncode == code, (argv, result.returncode, result.stdout, result.stderr)
        self.checks += 1
        return result

    def entries(self, *args):
        """What `history list --json` shows, newest first."""
        output = self.run("list", "--json", "--limit", "1000", *args).stdout
        return [json.loads(line) for line in output.splitlines()]

    def commands(self, *args):
        return [entry["command"] for entry in self.entries(*args)]

    def clear(self):
        self.run("prune", "--yes")
        assert self.commands() == []

    def file(self, name, content):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    @contextlib.contextmanager
    def runtime(self, config=None):
        """A runtime on the private socket, reading `config` as its config.lua when given."""
        path = Path(self.env["XDG_CONFIG_HOME"]) / "telar" / "config.lua"
        if config is not None:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(config)
        with (self.root / "server.log").open("wb") as log:
            process = subprocess.Popen([str(self.binary), "server", "--socket", str(self.socket)] + (["--no-config"] if config is None else []),
                                       env=self.env, stdout=log, stderr=log)
            try:
                deadline = time.monotonic() + 10
                while not self.socket.exists():
                    assert process.poll() is None, (self.root / "server.log").read_bytes()
                    assert time.monotonic() < deadline, "private runtime did not listen"
                    time.sleep(.02)
                yield
            finally:
                subprocess.run([str(self.binary), "server", "stop", "--socket", str(self.socket)], env=self.env,
                               capture_output=True, timeout=20)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                if config is not None:
                    path.unlink()


def text_id(connection, text):
    """The id of a command's text in the history, stored as the runtime stores it (its hash aside,
    which only finds a text again when the runtime writes it)."""
    connection.execute("INSERT INTO command_text (hash, text) VALUES (0, ?)", (text,))
    return connection.execute("SELECT last_insert_rowid()").fetchone()[0]


def zsh_imports(f):
    """zsh: extended lines with metafied bytes and multi-line commands, plain lines that begin with `: `."""
    # zsh writes the bytes of → (e2 86 92) it treats specially as Meta (0x83) and the byte xor 0x20.
    arrow = b"\xe2\x83\xa6\x83\xb2"
    path = f.file("zsh_history", b": 1700000000:0;echo " + arrow + b" done\n"
                                b": 1700000001:3;printf 'a\\\nb'\n"
                                b": noop\n"
                                b"plain command\n")
    f.run("import", "zsh", "--file", path)
    assert f.commands() == ["printf 'a\nb'", "echo \u2192 done", "plain command", ": noop"], f.commands()
    started = {entry["command"]: entry["started_at_ms"] for entry in f.entries()}
    assert started["echo \u2192 done"] == 1700000000000 and started["printf 'a\nb'"] == 1700000001000, started
    # The elapsed seconds of an extended line are the entry's duration.
    durations = {entry["command"]: entry["duration_ms"] for entry in f.entries()}
    assert durations["printf 'a\nb'"] == 3000 and durations["echo \u2192 done"] == 0, durations
    f.clear()


def bash_imports(f):
    """bash: one command per line, or with HISTTIMEFORMAT every line up to the next timestamp."""
    plain = f.file("bash_plain", b"ls\ncd src\nls\n")
    f.run("import", "bash", "--file", plain)
    assert sorted(f.commands()) == ["cd src", "ls", "ls"], f.commands()
    f.clear()
    timed = f.file("bash_timed", b"#1700000000\nfor x in a b; do\n  echo $x\ndone\n#1700000005\nmake\n")
    f.run("import", "bash", "--file", timed)
    assert f.commands() == ["make", "for x in a b; do\n  echo $x\ndone"], f.commands()
    f.clear()


def fish_imports(f):
    """fish keeps a command's newlines as `\\n` and its backslashes as `\\\\`."""
    path = f.file("fish_history", b"- cmd: printf 'one\\ntwo'\n  when: 1700000000\n"
                                 b"- cmd: echo C:\\\\temp\n  when: 1700000001\n  paths:\n    - C:\\\\temp\n")
    f.run("import", "fish", "--file", path)
    assert f.commands() == ["echo C:\\temp", "printf 'one\ntwo'"], f.commands()
    f.clear()


def shell_environment(f):
    """An environment for a real shell whose home and XDG directories are the fixture's, so it
    reads and writes no history of the user's, and loads no startup file of theirs."""
    keep = {key: f.env[key] for key in ("HOME", "XDG_RUNTIME_DIR", "XDG_DATA_HOME", "XDG_CONFIG_HOME", "XDG_STATE_HOME", "TMPDIR")}
    return {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "en_US.UTF-8" if sys.platform == "darwin" else "C.UTF-8", "TERM": "xterm", **keep}


def installed(name):
    path = shutil.which(name)
    if path is None:
        print(f"skipped: {name} is not installed, so no histfile of its own is imported")
    return path


def imported_from(f, kind, path, commands, before):
    """Imports what a shell wrote to `path` and checks it holds `commands`, newest first, at the
    times the shell stamped them, between `before` and now."""
    f.run("import", kind, "--file", path)
    entries = f.entries()
    assert [entry["command"] for entry in entries] == commands, (kind, [entry["command"] for entry in entries], path.read_bytes())
    after = (int(time.time()) + 1) * 1000
    assert all(before * 1000 <= entry["started_at_ms"] <= after for entry in entries), (kind, entries)
    f.clear()


def real_zsh_imports(f):
    """A histfile zsh itself wrote with `fc -W` and extended_history: its stamps, a command it
    split over lines and one whose non-ASCII bytes it metafied."""
    zsh = installed("zsh")
    if zsh is None:
        return
    path = f.root / "real_zsh_history"
    commands = ["echo \u2192 done", "printf 'one\ntwo'"]
    before = int(time.time())
    # History is on only in an interactive shell; -f reads no startup file.
    script = 'setopt extended_history; HISTFILE=$1; HISTSIZE=100; SAVEHIST=100; print -rs -- "$2"; print -rs -- "$3"; fc -W'
    subprocess.run([zsh, "-f", "-i", "-c", script, "zsh", str(path), *commands], env=shell_environment(f), stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=30)
    written = path.read_bytes()
    assert re.match(rb": \d+:0;", written) and b"\x83" in written and b"\\\n" in written, written
    imported_from(f, "zsh", path, commands[::-1], before)


def real_bash_imports(f):
    """A histfile bash itself wrote with `history -w` and HISTTIMEFORMAT set: a `#` stamp before
    each command, and a command over several lines."""
    bash = installed("bash")
    if bash is None:
        return
    path = f.root / "real_bash_history"
    commands = ["make", "for x in a b; do\n  echo $x\ndone"]
    before = int(time.time())
    # histchars, its default spelled out, gives bash its comment character, which bash 3.2 (macOS's)
    # started with -c lacks: it keeps each stamp behind a NUL and writes none.
    script = 'unset HISTFILE; HISTTIMEFORMAT="%F %T "; histchars="!^#"; set -o history; for command; do history -s -- "$command"; done; history -w "$0"'
    subprocess.run([bash, "--norc", "--noprofile", "-c", script, str(path), *commands], env=shell_environment(f), stdin=subprocess.DEVNULL, capture_output=True, check=True, timeout=30)
    written = path.read_bytes()
    assert re.match(rb"#\d+\nmake\n#\d+\nfor x in a b; do\n", written), written
    imported_from(f, "bash", path, commands[::-1], before)


def typed_into_fish(f, fish, lines):
    """Types `lines` into an interactive fish on a terminal, each when its prompt shows, then
    exits it; fish saves each command it ran to its history."""
    config = Path(f.env["XDG_CONFIG_HOME"]) / "fish"
    config.mkdir(parents=True, exist_ok=True)
    # The prompt counts the commands run, as a repaint prints it again.
    (config / "config.fish").write_text("set -g ran 0\nfunction fish_greeting; end\nfunction counted --on-event fish_postexec; set -g ran (math $ran + 1); end\n"
                                         "function fish_prompt; echo -n \"READY$ran> \"; end\n")
    pid, terminal = pty.fork()
    if pid == 0:
        os.execve(fish, ["fish", "-i"], shell_environment(f))
    seen = b""

    def prompts(ran):
        nonlocal seen
        deadline = time.monotonic() + 20
        while b"READY%d> " % ran not in seen:
            assert time.monotonic() < deadline, seen
            if select.select([terminal], [], [], 0.1)[0]:
                seen += os.read(terminal, 4096)

    try:
        for ran, line in enumerate(lines):
            prompts(ran)
            os.write(terminal, line)
        prompts(len(lines))
        os.write(terminal, b"exit\r")
        deadline = time.monotonic() + 20
        while os.waitpid(pid, os.WNOHANG) == (0, 0):
            assert time.monotonic() < deadline, "fish did not exit"
            with contextlib.suppress(OSError):
                if select.select([terminal], [], [], 0.1)[0]:
                    os.read(terminal, 4096)
        pid = 0
    finally:
        if pid != 0:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
        os.close(terminal)
        (config / "config.fish").unlink()


def real_fish_imports(f):
    """The fish_history fish itself saved: a non-ASCII command, and one typed over three lines."""
    fish = installed("fish")
    if fish is None:
        return
    before = int(time.time())
    typed_into_fish(f, fish, [b"echo \xe2\x86\x92 done\r", b"begin\recho a\rend\r"])
    path = Path(f.env["XDG_DATA_HOME"]) / "fish" / "fish_history"
    assert b"- cmd: begin\\necho a\\nend\n" in path.read_bytes(), path.read_bytes()
    imported_from(f, "fish", path, ["exit", "begin\necho a\nend", "echo \u2192 done"], before)
    path.unlink()


def reimports(f):
    """A histfile its shell trimmed and grew, imported twice, adds exactly the new runs; a file
    named three ways is one source."""
    path = f.file("trimmed_history", b": 1700000001:0;make\n: 1700000002:0;make test\n: 1700000003:0;git push\n")
    f.run("import", "zsh", "--file", path)
    path.write_bytes(b": 1700000002:0;make test\n: 1700000003:0;git push\n: 1700000004:0;git pull\n")
    f.run("import", "zsh", "--file", path)
    f.run("import", "zsh", "--file", path)
    assert sorted(f.commands()) == ["git pull", "git push", "make", "make test"], f.commands()

    link = f.root / "linked_history"
    link.symlink_to(path)
    f.run("import", "zsh", "--file", "./trimmed_history")
    f.run("import", "zsh", "--file", link)
    assert len(f.commands()) == 4, f.commands()
    f.clear()

    # Without times, repeated commands are runs of their own, kept once each however often the
    # file is imported.
    repeated = f.file("repeated_history", b"ls\nls\nls\n")
    f.run("import", "bash", "--file", repeated)
    f.run("import", "bash", "--file", repeated)
    assert f.commands() == ["ls", "ls", "ls"], f.commands()
    f.clear()


def cut_imports(f):
    """A file past 32 MiB keeps its newest lines from the first whole entry, and says it was cut."""
    tail = b": 1700000000:0;printf 'cut\\\npart'\n: 1700000001:0;echo whole\n"
    filler = b": 1600000000:0;" + b"x" * 1000 + b"\\\n"
    lines = (32 * 1024 * 1024) // len(filler) + 10
    path = f.file("large_history", filler * lines + b"tail end\n" + tail)
    result = f.run("import", "zsh", "--file", path, code=1)
    assert b"imported" in result.stdout, result
    commands = f.commands()
    assert "echo whole" in commands and not any(command.startswith("x") for command in commands), commands
    f.clear()


def encodings(f):
    """Bytes that are no UTF-8 are kept as U+FFFD rather than stored as they are."""
    path = f.file("broken_history", b"echo \xff\xfe ok\n")
    f.run("import", "bash", "--file", path)
    assert f.commands() == ["echo \ufffd\ufffd ok"], f.commands()
    f.clear()


def other_shells(f):
    """nushell's text history, PowerShell's and xonsh's JSON sessions."""
    nushell = f.file("nushell/history.txt", b"ls | where size > 1kb\nlet x = 1<\\n>echo $x\n")
    f.run("import", "nushell", "--file", nushell)
    assert sorted(f.commands()) == ["let x = 1\necho $x", "ls | where size > 1kb"], f.commands()
    f.clear()

    powershell = f.file("ConsoleHost_history.txt", b"Get-ChildItem\nif ($true) {`\n  'yes'`\n}\n")
    f.run("import", "--file", powershell)
    assert sorted(f.commands()) == ["Get-ChildItem", "if ($true) {\n  'yes'\n}"], f.commands()
    f.clear()

    sessions = f.root / "history_json"
    sessions.mkdir()
    (sessions / "xonsh-b.json").write_text(json.dumps({"data": {"ts": [1700000100.0, 1700000200.0], "cmds": [{"inp": "echo later\n", "rtn": 0, "ts": [1700000100.25, 1700000101.0]}]}}))
    (sessions / "xonsh-a.json").write_text(json.dumps({"data": {"ts": [1700000000.0, 1700000050.0], "cmds": [{"inp": "echo first\n", "rtn": 1, "ts": [1700000000.5, 1700000001.0]}]}}))
    f.run("import", "xonsh", "--file", sessions)
    started = {entry["command"]: (entry["started_at_ms"], entry["exit_code"], entry["duration_ms"]) for entry in f.entries()}
    assert started == {"echo first": (1700000000500, 1, 500), "echo later": (1700000100250, 0, 750)}, started
    f.clear()


def databases(f):
    """The SQLite databases of atuin, mcfly, zsh-histdb and nushell, read without being written."""
    atuin = f.root / "atuin" / "history.db"
    atuin.parent.mkdir()
    with sqlite3.connect(atuin) as connection:
        connection.execute("CREATE TABLE history (id TEXT PRIMARY KEY, timestamp INTEGER, duration INTEGER, exit INTEGER, command TEXT, cwd TEXT, session TEXT, hostname TEXT, deleted_at INTEGER)")
        connection.execute("INSERT INTO history VALUES ('a', 1700000000123456789, 5000000, 0, 'cargo build', '/src', 's', 'host:me', NULL)")
        connection.execute("INSERT INTO history VALUES ('b', 1700000001000000000, 5, 0, 'deleted one', '/src', 's', 'host:me', 1700000002000000000)")
    before = atuin.read_bytes()
    f.run("import", "atuin", "--file", atuin)
    entries = f.entries()
    assert [(entry["command"], entry["started_at_ms"], entry["cwd"], entry["exit_code"], entry["duration_ms"]) for entry in entries] == [("cargo build", 1700000000123, "/src", 0, 5)], entries
    assert atuin.read_bytes() == before
    f.clear()

    mcfly = f.root / "mcfly" / "history.db"
    mcfly.parent.mkdir()
    with sqlite3.connect(mcfly) as connection:
        connection.execute("CREATE TABLE commands (id INTEGER PRIMARY KEY, cmd TEXT, cmd_tpl TEXT, session_id TEXT, when_run INTEGER, exit_code INTEGER, selected INTEGER, dir TEXT, old_dir TEXT)")
        connection.execute("INSERT INTO commands VALUES (1, 'git status', 'git status', 's', 1700000000, 0, 0, '/src', NULL)")
    f.run("import", "mcfly", "--file", mcfly)
    assert [(entry["command"], entry["started_at_ms"], entry["cwd"], entry["exit_code"]) for entry in f.entries()] == [("git status", 1700000000000, "/src", 0)]
    f.clear()

    histdb = f.root / ".histdb" / "zsh-history.db"
    histdb.parent.mkdir()
    with sqlite3.connect(histdb) as connection:
        connection.executescript("""
            CREATE TABLE commands (id INTEGER PRIMARY KEY, argv TEXT);
            CREATE TABLE places (id INTEGER PRIMARY KEY, host TEXT, dir TEXT);
            CREATE TABLE history (id INTEGER PRIMARY KEY, session INTEGER, command_id INTEGER, place_id INTEGER, exit_status INTEGER, start_time INTEGER, duration INTEGER);
            INSERT INTO commands VALUES (1, 'make'), (2, 'make test');
            INSERT INTO places VALUES (1, 'host', '/src');
            INSERT INTO history VALUES (1, 1, 1, 1, 0, 1700000000, 2), (2, 1, 2, 1, 0, 1700000010, 2), (3, 1, 1, 1, 0, 1700000020, 2);
        """)
    f.run("import", "histdb", "--file", histdb)
    assert [(entry["command"], entry["cwd"], entry["duration_ms"]) for entry in f.entries()] == [("make", "/src", 2000), ("make test", "/src", 2000), ("make", "/src", 2000)], f.entries()
    f.clear()

    nushell = f.root / "nu" / "history.sqlite3"
    nushell.parent.mkdir()
    with sqlite3.connect(nushell) as connection:
        connection.execute("CREATE TABLE history (id INTEGER PRIMARY KEY, command_line TEXT, start_timestamp INTEGER, session_id INTEGER, hostname TEXT, cwd TEXT, duration_ms INTEGER, exit_status INTEGER, more_info TEXT)")
        connection.execute("INSERT INTO history VALUES (1, 'ls', 1700000000999, 1, 'host', '/src', 3, 0, NULL)")
    f.run("import", "nushell", "--file", nushell)
    assert [(entry["command"], entry["started_at_ms"], entry["cwd"], entry["exit_code"], entry["duration_ms"]) for entry in f.entries()] == [("ls", 1700000000999, "/src", 0, 3)]
    f.clear()

    unknown = f.root / "other.db"
    with sqlite3.connect(unknown) as connection:
        connection.execute("CREATE TABLE unrelated (x)")
    f.run("import", "atuin", "--file", unknown, code=1)


def import_filters(f):
    """Imported lines pass the filters recorded commands pass: a leading space keeps a line out,
    and a secret in one is redacted."""
    path = f.file("private_history", b"export API_TOKEN=abc123\n echo hidden\necho shown\n")
    f.run("import", "bash", "--file", path)
    assert sorted(f.commands()) == ["echo shown", "export API_TOKEN=[redacted]"], f.commands()
    f.clear()


def listing(f):
    """list and search print JSON, a template, a page past an offset, fuzzy matches and each
    command once."""
    f.run("import", "zsh", "--file", f.file("listing_history", b"".join(b": %d:0;%s\n" % (1700000000 + index, command)
                                                                        for index, command in enumerate([b"git status", b"git commit", b"git status", b"make", b"echo \x1b[31m"]))))
    entry = f.entries()[0]
    assert set(entry) == {"id", "pane_id", "started_at_ms", "duration_ms", "exit_code", "status", "author", "origin", "provider", "cwd", "workspace", "command", "command_truncated"}, entry
    assert entry["command"] == "echo \x1b[31m" and entry["exit_code"] is None and entry["status"] == "completed"
    formatted = f.run("list", "--format", "{timestamp}\\t{command}", "--limit", "2").stdout
    assert formatted == b"1700000004000\techo \\x1b[31m\n1700000003000\tmake\n", formatted
    f.run("list", "--format", "{nope}", code=1)
    assert f.commands("--offset", "3") == ["git commit", "git status"]
    assert f.commands("--distinct") == ["echo \x1b[31m", "make", "git status", "git commit"]
    fuzzy = [json.loads(line)["command"] for line in f.run("search", "gst", "--fuzzy", "--json").stdout.splitlines()]
    assert fuzzy and all(command == "git status" for command in fuzzy), fuzzy
    assert [json.loads(line)["command"] for line in f.run("search", "commit", "--json").stdout.splitlines()] == ["git commit"]
    f.clear()


def zsh_lines(commands, start=1700000000):
    """A zsh extended histfile of `commands`, a second apart."""
    return b"".join(b": %d:0;%s\n" % (start + index, command.encode()) for index, command in enumerate(commands))


def paging(f):
    """--after continues past the last entry a page showed: entries deleted or recorded since
    neither skip nor repeat any."""
    f.run("import", "zsh", "--file", f.file("paging_history", zsh_lines(["page %d" % index for index in range(10)])))
    first = f.entries("--limit", "3")
    assert [entry["command"] for entry in first] == ["page 9", "page 8", "page 7"], first
    f.run("delete", first[1]["id"])
    f.run("import", "zsh", "--file", f.file("paging_newer", zsh_lines(["newer"], start=1800000000)))
    second = [entry["command"] for entry in f.entries("--limit", "3", "--after", first[-1]["id"])]
    assert second == ["page 6", "page 5", "page 4"], second
    assert f.run("search", "page", "--json", "--limit", "2", "--after", first[-1]["id"]).stdout.count(b"\n") == 2
    f.run("list", "--after", first[1]["id"], code=1)
    f.run("list", "--after", first[-1]["id"], "--offset", "1", code=1)
    f.clear()

    # Each command once: a command an earlier page showed is not listed again at an older run.
    f.run("import", "zsh", "--file", f.file("paging_distinct", zsh_lines(["alpha", "beta", "alpha", "gamma", "delta", "beta", "epsilon"])))
    listed = []
    page = f.entries("--distinct", "--limit", "2")
    while page:
        listed += [entry["command"] for entry in page]
        page = f.entries("--distinct", "--limit", "2", "--after", page[-1]["id"])
    assert listed == ["epsilon", "beta", "delta", "gamma", "alpha"], listed
    f.clear()


def export_during_deletes(f):
    """An export that entries are deleted from while it prints holds each entry that stays once,
    oldest first: the deleted ones shift none of the pages still to come."""
    padding = "x" * 200
    count = 3000
    commands = ["echo %d %s%s" % (index, "gone " if index >= count - 40 else "", padding) for index in range(count)]
    f.run("import", "zsh", "--file", f.file("deleted_export", zsh_lines(commands)))
    argv = [str(f.binary), "history", "export", "--socket", str(f.socket)]
    process = subprocess.Popen(argv, env=f.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=f.root)
    try:
        # The export prints its oldest page first and waits on the pipe, its newer pages unread.
        lines = [process.stdout.readline()]
        assert f.run("prune", "--match", "gone", "--yes").stdout == b"removed 40 entries\n"
        lines += process.stdout.read().splitlines(keepends=True)
        assert process.wait(timeout=60) == 0, process.stderr.read()
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
    exported = [json.loads(line)["command"] for line in lines]
    assert exported == commands[:count - 40], (len(exported), exported[-3:])
    f.checks += 1
    f.clear()


def deduplication(f):
    """prune --keep N previews and removes the runs past the newest N of each command."""
    f.run("import", "zsh", "--file", f.file("dedup_history", zsh_lines(["make", "ls", "make", "git push", "make", "ls", "make"])))
    assert f.run("prune", "--keep", "2", "--dry-run").stdout == b"would remove 2 entries\n"
    assert len(f.commands()) == 7
    assert f.run("prune", "--keep", "2", data=b"yes\n").stdout.endswith(b"removed 2 entries\n")
    assert f.commands() == ["make", "ls", "make", "git push", "ls"], f.commands()
    f.run("prune", "--keep", "0", code=1)
    f.clear()


def seed_workspaces(f):
    """Rows of a workspace, written while no runtime runs, as an index it loads then holds them."""
    workspace = f.root / "project"
    workspace.mkdir()
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO session (id,pane_id,location_kind,location_id,tab_id,workspace_path,shell,started_at_ms) VALUES (?,?,?,?,?,?,?,?)",
                           (bytes(range(16)), 900, 0, 1, 1, str(workspace), "/bin/sh", 1700000000000))
        for sequence, (command, path) in enumerate([("in project", str(workspace)), ("elsewhere", "/elsewhere")], 1):
            connection.execute("INSERT INTO command (session_id,pane_id,location_kind,location_id,tab_id,sequence,text_id,cwd,workspace_path,cwd_key,workspace_key,started_at_ms,duration_ns,exit_code,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                               (bytes(range(16)), 900, 0, 1, 1, sequence, text_id(connection, command), path, path, path, path, 1700000000000 + sequence, 0, 0, 0))


def seed_shells(f):
    """Runs of two shells, each as the path or the login name a pane started it by."""
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    session = bytes(range(32, 48))
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO session (id,pane_id,location_kind,location_id,tab_id,workspace_path,shell,started_at_ms) VALUES (?,?,?,?,?,?,?,?)",
                           (session, 902, 0, 1, 1, "/s", "/usr/bin/zsh", 1700000000000))
        for sequence, (command, shell) in enumerate([("in zsh", "/usr/bin/zsh"), ("in bash", "-bash")], 1):
            connection.execute("INSERT INTO command (session_id,pane_id,location_kind,location_id,tab_id,sequence,text_id,cwd,workspace_path,cwd_key,workspace_key,started_at_ms,duration_ns,exit_code,status,shell) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                               (session, 902, 0, 1, 1, sequence, text_id(connection, command), "/s", "/s", "/s", "/s", 1700000000000 + sequence, 0, 0, 0, shell))


def shells(f):
    """--shell finds the runs of a shell by its name, whatever path started it."""
    assert f.commands("--shell", "zsh") == ["in zsh"], f.commands("--shell", "zsh")
    assert f.commands("--shell", "bash") == ["in bash"]
    assert f.commands("--shell", "fish") == []


def workspaces(f):
    """--workspace takes a path relative to where it runs."""
    for name in ("project", "./project", "project/"):
        listed = [line for line in f.run("list", "--workspace", name).stdout.splitlines()]
        assert len(listed) == 1 and listed[0].endswith(b"in project"), (name, listed)
    f.clear()


def pruning(f):
    """prune previews exactly what it removes, past 1000 entries and before a date, and refuses a
    date that does not exist."""
    path = f.file("many_history", b"".join(b": %d:0;echo %d\n" % (1700000000 + index * 60, index) for index in range(1500)))
    f.run("import", "zsh", "--file", path)
    assert f.run("prune", "--dry-run").stdout == b"would remove 1500 entries\n"
    cutoff = datetime.datetime.fromtimestamp(1700000000 + 1000 * 60, datetime.timezone.utc).strftime("%Y-%m-%d")
    older = sum(1 for index in range(1500) if 1700000000 + index * 60 < datetime.datetime.strptime(cutoff, "%Y-%m-%d").replace(tzinfo=datetime.timezone.utc).timestamp())
    assert f.run("prune", "--dry-run", "--before", cutoff).stdout == b"would remove %d entries\n" % older
    assert f.run("prune", "--before", cutoff, data=b"yes\n").stdout.endswith(b"removed %d entries\n" % older)
    assert f.run("stats").stdout.startswith(b"commands: %d\n" % (1500 - older))
    f.run("prune", "--before", "2024-02-31", "--dry-run", code=1)
    f.clear()


def seed_rewrites(f):
    """Rows recorded before a filter existed, written while no runtime runs."""
    database = Path(f.env["XDG_DATA_HOME"]) / "telar/history.db"
    session = bytes(range(16, 32))
    with sqlite3.connect(database) as connection:
        connection.execute("INSERT INTO session (id,pane_id,location_kind,location_id,tab_id,workspace_path,shell,started_at_ms) VALUES (?,?,?,?,?,?,?,?)",
                           (session, 901, 0, 1, 1, "/p", "/bin/sh", 1700000000000))
        for sequence, command in enumerate(["vault login -method=oidc", "export API_TOKEN=abc123", "make", "ls"], 1):
            connection.execute("INSERT INTO command (session_id,pane_id,location_kind,location_id,tab_id,sequence,text_id,cwd,workspace_path,cwd_key,workspace_key,started_at_ms,duration_ns,exit_code,status) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                               (session, 901, 0, 1, 1, sequence, text_id(connection, command), "/p", "/p", "/p", "/p", 1700000000000 + sequence, 0, 0, 0))
        made = connection.execute("SELECT c.id FROM command c JOIN command_text t ON t.id = c.text_id WHERE t.text = 'make'").fetchone()[0]
        connection.execute("INSERT INTO command_output (command_id,content,truncated,observed_bytes) VALUES (?,?,?,?)", (made, "GITHUB_TOKEN=abc123\nbuilt\n", 0, 27))
    return made


def rewrites(f, made):
    """prune --filters, against a runtime whose configuration filters what it did not before,
    removes what the filters refuse and redacts what they would keep redacted."""
    assert f.run("prune", "--filters", "--dry-run").stdout == b"would remove 2 entries and redact 2\n"
    assert sorted(f.commands()) == ["export API_TOKEN=abc123", "ls", "make", "vault login -method=oidc"]
    assert f.run("prune", "--filters", data=b"yes\n").stdout.endswith(b"removed 2 entries and redacted 2\n")
    assert sorted(f.commands()) == ["export API_TOKEN=[redacted]", "make"], f.commands()
    shown = f.run("show", str(made)).stdout
    assert shown == b"GITHUB_TOKEN=[redacted]\nbuilt\n", shown
    f.clear()


def statistics(f):
    """stats --period today starts at local midnight; --ngram-size counts sequences of commands."""
    now = datetime.datetime.now().astimezone()
    midnight = now.replace(hour=0, minute=0, second=0, microsecond=0)
    times = [int((midnight - datetime.timedelta(minutes=1)).timestamp()), int(midnight.timestamp()) + 1]
    if times[1] > now.timestamp():
        times[1] = int(now.timestamp())
    f.run("import", "zsh", "--file", f.file("today_history", b": %d:0;yesterday\n: %d:0;today\n" % tuple(times)))
    assert f.run("stats", "--period", "today").stdout.startswith(b"commands: 1\n")
    f.clear()

    commands = [b"git add .", b"git commit", b"git push", b"git add .", b"git commit", b"make"]
    f.run("import", "zsh", "--file", f.file("ngram_history", b"".join(b": %d:0;%s\n" % (1700000000 + index, command) for index, command in enumerate(commands))))
    output = f.run("stats", "--ngram-size", "2").stdout
    assert output.startswith(b"commands: 5\nunique:   4\ntop:\n        2  git add . ; git commit\n"), output
    f.run("stats", "--ngram-size", "11", code=1)
    f.clear()


def exports(f):
    """export prints every entry oldest first, as JSON or as a shell's histfile that imports back."""
    commands = [b"echo one", b"printf 'a\\\nb'", b"echo \xe2\x86\x92"]
    f.run("import", "zsh", "--file", f.file("export_history", b"".join(b": %d:0;%s\n" % (1700000000 + index, command) for index, command in enumerate(commands))))
    exported = [json.loads(line)["command"] for line in f.run("export").stdout.splitlines()]
    assert exported == ["echo one", "printf 'a\nb'", "echo \u2192"], exported
    zsh = f.run("export", "--format", "zsh").stdout
    assert zsh.startswith(b": 1700000000:0;echo one\n: 1700000001:0;printf 'a\\\nb'\n"), zsh
    assert f.run("export", "--format", "bash").stdout.startswith(b"#1700000000\necho one\n#1700000001\nprintf 'a\nb'\n")
    assert f.run("export", "--format", "fish").stdout.startswith(b"- cmd: echo one\n  when: 1700000000\n- cmd: printf 'a\\nb'\n")
    f.clear()
    f.run("import", "zsh", "--file", f.file("exported_zsh", zsh))
    assert f.commands() == ["echo \u2192", "printf 'a\nb'", "echo one"], f.commands()
    f.clear()

    many = f.file("export_many", b"".join(b": %d:0;echo %d\n" % (1700000000 + index, index) for index in range(2500)))
    f.run("import", "zsh", "--file", many)
    exported = [json.loads(line)["command"] for line in f.run("export").stdout.splitlines()]
    assert exported == ["echo %d" % index for index in range(2500)], exported[:3]
    f.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--telar", type=Path, required=True)
    arguments = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="hist-") as directory:
        f = Fixture(arguments.telar, directory)
        with f.runtime():
            for check in (zsh_imports, bash_imports, fish_imports, real_zsh_imports, real_bash_imports, real_fish_imports,
                          reimports, cut_imports, encodings, other_shells, databases, import_filters, listing, paging,
                          pruning, deduplication, statistics, exports, export_during_deletes):
                check(f)
        seed_workspaces(f)
        seed_shells(f)
        with f.runtime():
            shells(f)
            workspaces(f)
        made = seed_rewrites(f)
        with f.runtime('return {api_version = 2, runtime = {history = {command_filters = {{regex = "^vault "}}, trivial_commands = {"ls"}}}}\n'):
            rewrites(f, made)
        print(f"{f.checks} history CLI checks passed")


if __name__ == "__main__":
    main()
