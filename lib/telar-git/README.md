# telar-git

A native, read-only reader of a git repository's state: the branch or
detached commit, the upstream and how far the two diverged, and the counts
`git status` reports. The runtime asks it after every command, next to a
shell prompt.

It never runs git or any other program, never runs hooks and never honours
config that runs code: `core.fsmonitor`, filter drivers, `include` and
`includeIf` are not even looked at. Every byte of the repository is untrusted
input. It is C++23 with module interfaces, on `telar::platform`, OpenSSL's
SHA-1 and SHA-256, and zlib.

```cmake
add_subdirectory("${TELAR_ROOT}/lib/telar-git" "${CMAKE_CURRENT_BINARY_DIR}/telar-git")
target_link_libraries(your_target PRIVATE telar::git)
```

```cpp
import telar.base.memory;
import telar.git;

telar::SystemAllocator memory;
telar::git::StatusReader reader{memory};

const auto &status = reader.read("/home/user/project/src"); // never throws
if (status.repository == telar::git::RepositoryState::ready) {
  // status.head: branch, unborn, detached or unknown; status.branch, status.head_id
  // status.upstream, status.upstream_name ("origin/main"), status.ahead, status.behind
  // status.changes.staged_added ... unstaged_deleted, intent_to_add, conflicted
}

// After the next command: one fstatat per input, nothing read.
if (reader.changed()) { /* HEAD, index, config, packed-refs or a ref moved */ }
```

Each part of a `Status` says how far to trust it. `RepositoryState` tells
apart no repository, one owned by another user, an unsupported format and a
malformed one. `divergence`, `staged` and `unstaged` are an `Accuracy`:
`exact`, `unknown` (unreadable data or a limit reached), `unsupported` or
`not_applicable`. `Status::work` counts what a read did: objects and commits
read, trees compared, entries checked, files hashed.

## What it reads

- **Discovery**: walks up from the directory, as `setup_git_directory` does,
  to a `.git` directory, a `gitdir:` file (worktrees, submodules, relative or
  absolute) or a bare git directory, following `commondir` and a
  non-linked `core.worktree`. It stops at the filesystem root and at a
  filesystem boundary. The work tree, the `.git` file, the git directory and
  the common directory must belong to the effective user, as git's
  `safe.directory` default demands; `safe.directory` itself is not read. The
  directory must be absolute; `GIT_*` variables are ignored.
- **Config**: `<common>/config` and, with `extensions.worktreeConfig`,
  `config.worktree`. Only `core.repositoryformatversion`, `core.bare`,
  `core.filemode`, `core.symlinks`, `core.worktree`, `extensions.*`,
  `branch.<name>.remote|merge` and `remote.<name>.fetch` are used. Global and
  system config are not read. A malformed file makes the repository
  `invalid`, as git refuses it.
- **Refs**: HEAD, symbolic refs (five levels), loose refs and `packed-refs`,
  per-worktree refs from the worktree's git directory. Ref names must pass
  git's `check_refname_format`, so no name reaches outside `refs/`.
- **Upstream**: `branch.<name>.merge` mapped through the remote's fetch
  refspecs (globs and negative refspecs), or a local branch for `remote = .`.
  A configured upstream whose ref is missing is `gone`.
- **Objects**: loose objects, packfiles with `.idx` v2, `OFS_DELTA` and
  `REF_DELTA` chains across packs and loose bases, SHA-1 and SHA-256.
- **Ahead/behind**: the `rev-list --left-right --count` walk. With a
  `commit-graph` file or split chain it orders by generation number and
  reads no commit object; commits newer than the graph, or every commit when
  there is no graph, are read from the object database and ordered by date
  with git's slop. `shallow` cuts parents, and disables the graph as in git.
- **Index**: versions 2, 3 and 4, extended flags, the `TREE` cache-tree, the
  trailing checksum. Optional extensions are skipped; a split index, a sparse
  index or another required extension is `unsupported`.
- **Staged**: HEAD's tree against the index, skipping every directory whose
  cache-tree entry is valid and equal to HEAD's tree.
- **Unstaged**: each entry's stat data against the work tree, as
  `ce_match_stat`. Racily clean entries (modified in the second the index was
  written, or later) and smudged ones are hashed as blobs. The work tree is
  walked with `openat` and `O_NOFOLLOW`, one directory descriptor per
  component, so a path under a symlink is deleted, as git reports it.

## What it does not do

- Untracked files are not reported. Doing it right means `.gitignore`,
  `info/exclude` and `core.excludesFile` semantics; a partial version would be
  wrong, so there is none.
- Counts match `git status --porcelain=v2 --untracked-files=no --no-renames`:
  a rename counts as a deletion and an addition.
- Content conversions (`core.autocrlf`, `eol`, `ident`, filter drivers such as
  LFS) are not applied. A file git converts is compared by its raw bytes, so
  it shows as modified when its stat data no longer matches the index.
- Submodule work trees are not inspected; a staged gitlink change counts.
- Not supported: reftable, split and sparse indexes, pack index v1,
  alternates, replace refs, grafts. Objects a partial clone never fetched
  make the affected part `unknown`.
- Detached HEAD gives the full object id; `default_abbreviation` is 7, not
  git's unique abbreviation.

## Limits

`Limits` bounds every read; exceeding one reports the part as unknown. The
defaults: small files (HEAD, refs, `.git`, `commondir`) 4 KiB, config 1 MiB,
`packed-refs` 64 MiB, `shallow` 16 MiB, index 256 MiB and 2^21 entries, paths
4095 bytes and 128 components, 256 parent directories, 1024 packs, objects
64 MiB, delta chains 128 deep, 256 MiB inflated per read, commit headers
64 KiB with 128 parents, 64 commit-graph layers, 20000 commits per
ahead/behind walk, 20000 trees per HEAD-to-index comparison and 64 MiB
hashed per read. Results of a walk or comparison that hit a limit are cached
as unknown too, so a huge history is not walked again on every prompt.

Files are opened with `O_NOFOLLOW | O_NONBLOCK`, must be regular, and are read
once with their size checked, so a FIFO, a device or a file growing under the
reader is refused. Packfiles, pack indexes and the commit-graph are read with
`pread`, never mapped: a file truncated under a mapping would raise SIGBUS in
the runtime.

## Caching and cost

A `StatusReader` serves one caller at a time. Between reads it keeps the
parsed config and index, the open packs and commit-graph layers (descriptors,
not their bytes), the last divergence (commits never change) and the last
HEAD-to-index comparison, each keyed by the fingerprints (device, inode,
size, mtime and ctime in nanoseconds) of the files it came from. A read with
nothing changed redoes only the work tree's stat calls; `changed()` is the
cheaper probe for everything else. A racily clean entry's verdict is kept
until its file or the index changes. Large buffers are released after use.

`telar-git-tests --time DIRECTORY` times a first read, repeated reads and
`changed()`.

## Standalone checks

```sh
tools/cpp configure git
tools/cpp build git
tools/cpp test git
```

The tests build repositories with the `git` CLI (the library never runs it)
and compare every field with `git status --porcelain=v2 --branch`; they skip
when git is not installed. They cover branches, detached and unborn HEADs,
packed refs, linked worktrees, submodules, bare repositories, SHA-256,
loose objects, packs with OFS and REF deltified commits, single and split
commit-graphs, long histories with skewed dates, conflicts, index versions,
racy entries, symlinked directories, and hostile input: truncated and
corrupted indexes, bogus pack offsets, garbage packs, oversized and FIFO
refs, ref names escaping `refs/`, malformed and oversized config, unknown
extensions, foreign git directories and random byte corruption.

## Editor

Use the [pinned C++ workflow](../../docs/build/cpp-modules.md).
`tools/cpp configure git` generates `out/compile_commands.json`.
Build the project before opening importers, then launch `.toolchain/bin/clangd`
with `--experimental-modules-support`.
