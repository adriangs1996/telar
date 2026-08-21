# references

Read-only copies of other people's projects, kept here so an agent working on
telar can look things up without guessing. Nothing here is built, imported or
shipped.

**Untracked on purpose.** `.gitignore` excludes everything in this directory
except this file. See the licensing note below.

## herdr

The Rust project telar came from. `AGENTS.md` explains what to read it for and
why porting from it is the wrong move.

Recreate it with:

```sh
mkdir -p references/herdr
H=../herdr   # or wherever your checkout is
cp -R $H/{src,migration,scripts} references/herdr/
cp $H/{LICENSE,CLAUDE.md,README.md,Cargo.toml,justfile} references/herdr/
cp $H/vendor/libghostty-vt.patches.md references/herdr/
cp -R $H/vendor/patches references/herdr/vendor-patches
git -C $H rev-parse HEAD > references/herdr/COMMIT
```

`COMMIT` records which revision the copy came from, so a claim about herdr's
behaviour can be traced to a specific state of it.

Left out deliberately: `vendor/` (800 MB, and telar fetches libghostty-vt
itself), `website/`, `docs/`, `target/` and the `.git` directory.

## Licensing

herdr is **AGPL-3.0-or-later**, dual-licensed with a commercial option. telar
has not chosen a licence yet.

Copying AGPL source into a public repository whose own licence is undecided is a
decision to take deliberately, not one to arrive at through a convenient `cp`.
So this directory stays untracked until Adrian decides otherwise.

The same caution applies to the code itself: read herdr to learn what problem
somebody hit and how they thought about it, then write telar's answer. Lifting a
function across is how a rewrite quietly becomes a derivative work.
