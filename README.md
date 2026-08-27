# epic-script

One command to build and install [Epic Cash](https://github.com/EpicCash) from source: the node,
the wallet, the miner, or the node and wallet together.

Nothing prebuilt is downloaded. The installer fetches pinned upstream sources, compiles them, and
puts the binaries on your PATH. What you run is what you compiled.

## Install

Linux and macOS:

```sh
curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh | sh
```

Windows, PowerShell 5.1 or later:

```powershell
irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex
```

From `cmd.exe` instead: `powershell -c "irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex"`

The default is the node and the wallet. Expect 10 to 30 minutes per component and a few GB of disk,
because this is a real compile.

## Read it first

You are about to run a script from the internet. Read it:

```sh
curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh | less
```

```powershell
irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | more
```

Or see what it would do without changing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh | sh -s -- --check
```

`--check` runs every preflight test, prints the plan, and stops.

## Choosing what to install

```sh
# node only
curl -fsSL .../install.sh | sh -s -- --component node

# miner with OpenCL, no prompts
curl -fsSL .../install.sh | sh -s -- --component miner --miner-features opencl --yes

# node plus a chain snapshot, so it does not sync from genesis
curl -fsSL .../install.sh | sh -s -- --component node --fast-sync
```

Through a pipe, PowerShell cannot bind parameters, so use environment variables:

```powershell
$env:EPIC_COMPONENT='node'; $env:EPIC_FAST_SYNC='1'; irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex
```

Do not wrap that in `powershell -c "..."` from a PowerShell prompt. The outer shell expands
`$env:EPIC_COMPONENT` inside the double quotes before the child process starts, so the child gets a
bare `=node` token and the launch fails with `The Process object must have the UseShellExecute
property set to false in order to use environment variables`. Execution policy governs script files
on disk, not a string handed to `iex`, so no bypass flag is needed here either.

Running it as a saved file takes ordinary parameters instead:

```powershell
./install.ps1 -Component node -FastSync
```

Every option has a variable equivalent, which also works on Unix and is the easier route in CI:

```sh
curl -fsSL .../install.sh | EPIC_COMPONENT=node EPIC_YES=1 sh
```

## Answering the questions

It asks before doing anything you might not want: installing build tools, installing Rust, patching
the miner's build scripts, replacing chain data. Each prompt takes `y`, `n` or `a`:

```
Install them now? [y/N/a]
```

`a` means yes to that one and to everything after it, so you can decide once at whatever point you
have seen enough. `--yes` is the same answer given up front, and is what unattended runs need, since
there is no terminal to ask on.

One thing `--yes` deliberately does not cover: a source checkout with uncommitted changes still
stops the run. That is your work rather than a step in this install, so it takes its own
`--force-checkout` to discard.

## Options

| Option | Variable | Meaning |
| --- | --- | --- |
| `--component <name>` | `EPIC_COMPONENT` | `node`, `wallet`, `miner`, `node_wallet`, `all`. Default `node_wallet` |
| `--yes` | `EPIC_YES` | Answer yes to every question up front. Required when piping with no terminal |
| `--install-deps` | `EPIC_INSTALL_DEPS` | Install missing build packages. Uses sudo on Linux, winget on Windows |
| `--check` | `EPIC_CHECK_ONLY` | Preflight only, change nothing |
| `--fast-sync` | `EPIC_FAST_SYNC` | Download a chain snapshot instead of syncing from genesis. Node only |
| `--bootstrap-url <u>` | `EPIC_BOOTSTRAP_URL` | Snapshot source. Default `https://bootstrap.epiccash.com/bootstrap.zip` |
| `--with-tor` | `EPIC_WITH_TOR` | Build node and wallet with `--features with-tor` |
| `--miner-features <f>` | `EPIC_MINER_FEATURES` | `cpu`, `opencl`, `cuda`. Default `cpu` |
| `--bin-dir <path>` | `EPIC_BIN_DIR` | Where binaries go. Default `~/.local/bin`, or `%LOCALAPPDATA%\Epic\bin` |
| `--src-dir <path>` | `EPIC_SRC_DIR` | Where sources are built. Default `~/.epic/src`, or `%LOCALAPPDATA%\Epic\src` |
| `--jobs <n>` | `EPIC_JOBS` | Parallel build jobs |
| `--no-modify-path` | `EPIC_NO_MODIFY_PATH` | Leave shell startup files and PATH alone |
| `--no-patch-cmake` | `EPIC_NO_PATCH_CMAKE` | Refuse the miner build-script fixes described below |
| `--force-checkout` | `EPIC_FORCE_CHECKOUT` | Discard uncommitted changes in an existing source checkout |

## What it installs

| Component | Binary | Source |
| --- | --- | --- |
| node | `epic` | `EpicCash/epic` at tag `v4.0.3` |
| wallet | `epic-wallet` | `EpicCash/epic-wallet` at tag `v4.0.0` |
| miner | `epic-miner` | `blacktyger/epic-miner` at `e9d0d85`, see [The miner](#the-miner) |

Release tags rather than branch tips, so running this next month builds the same code. The exact
commit is printed before each build.

The miner is not a single file. It loads RandomX as a shared library, needs its Cuckoo plugins on
disk, and will not start without an `epic-miner.toml` in the working directory. So it is installed
into `~/.epic/miner` and reached through a small launcher on your PATH that supplies all three. Run
`epic-miner` from a directory containing your own `epic-miner.toml` and that one is used instead.

## What it will not do

- **No sudo without asking.** Binaries go under your home directory. If build tools are missing it
  prints the exact command, then asks. Answer no and nothing is changed. An unattended run with no
  terminal to ask on refuses instead of escalating, which is what `--install-deps` is for.
- **It never creates a wallet.** `epic-wallet init` generates a seed phrase, so that stays your
  explicit step. The installer will not run it for you.
- **It never touches wallet data.** No file under `~/.epic/*/wallet_data` is read, moved or removed.
- **It will not silently replace chain data.** `--fast-sync` asks before replacing an existing
  chain, and moves the old one aside with a timestamp rather than deleting it.
- **It will not discard your work.** Updating a source checkout ends in `git checkout --force`, so a
  checkout with uncommitted changes to tracked files stops the run. Commit them, point `--src-dir`
  elsewhere, or pass `--force-checkout` to discard them deliberately. The two build scripts the
  installer patches itself are not counted, so a rerun is not blocked by its own edit.

## If you already have Epic installed

Rerunning is safe and idempotent, and it says what it is doing rather than assuming.

An existing checkout at the source path is reused rather than recloned, and its `origin` is
repointed if it aims somewhere else. A directory that exists but is not a checkout stops the run with
a message naming it, instead of git's "already exists and is not an empty directory".

Before replacing a binary it prints what was there, with its version, so a downgrade is visible
rather than silent. Your `epic-miner.toml` is kept if you already have one.

After installing it checks whether a different binary of the same name comes first on your `PATH`,
which is the case that used to look like success and behave like failure: an older `epic` from a 3.x
`.deb` in `/usr/local/bin` still answers to `epic` even though the new one installed correctly. If
that happens you are told which file wins and where it is.

## Uninstall

The installer writes an uninstaller listing exactly what it added.

```sh
sh ~/.epic/install/uninstall.sh
```

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Epic\install\uninstall.ps1"
```

It removes the binaries, the launcher, the PATH entry and the lines it added to your shell startup
files, and leaves everything else alone. Your chain data, wallets and the source checkouts stay
until you ask for them to go with `--purge-data` or `-PurgeData`, which requires typing `DELETE` to
confirm.

## Fast sync

A new node validates the chain from genesis, which takes hours. `--fast-sync` downloads a snapshot
of the chain database and unpacks it into `~/.epic/main/chain_data`, which is where the node looks
by default.

Understand the trade before using it. The snapshot is somebody else's copy of the chain database,
fetched over TLS with no signature published alongside it. The node still verifies proof of work and
the MMR roots as it loads and continues, so a doctored snapshot cannot hand you coins that do not
exist. It is still a weaker guarantee than validating everything yourself. Leave the flag off if you
would rather wait.

The installer checks that what arrived is actually a zip before unpacking it, because a captive
portal, a corporate proxy or an ISP content filter will happily return an HTML page with a 200 status
in its place.

If you run the node from a directory that has its own `epic-server.toml`, that config's `db_root` is
used and the snapshot is ignored.

## Build requirements

The installer checks all of these, prints the exact install command for your platform, and offers
to run it. You do not need to read this section unless you want to install them yourself.

On Windows that includes the Visual Studio Build Tools with the C++ workload, passed through winget
with the `--override` it needs. Without that override winget installs the VS Installer and no
workload, which yields no compiler while appearing to succeed. On macOS it will trigger
`xcode-select --install` and offer to install Homebrew, since neither can be named as a package until
they exist.

**Linux.** A C toolchain, CMake, git, pkg-config, libclang, and development headers for ncurses,
zlib and OpenSSL. On Debian and Ubuntu:

```sh
sudo apt-get install build-essential cmake git pkg-config libclang-dev libncurses-dev zlib1g-dev libssl-dev
```

That list is shorter than the upstream wiki's, which asks for `clang`, `llvm-dev`, `libncurses5-dev`
and `libncursesw5-dev` as well. None of those are needed: the bindgen-based crates want
`libclang.so`, which comes from `libclang-dev` rather than the clang driver, and `libncurses-dev` has
provided the wide-character headers for years. Verified by building all three repositories with
exactly the set above and nothing else.

**macOS.** Xcode command line tools, plus `cmake pkg-config ncurses zlib openssl@3` from Homebrew.
The installer points pkg-config at Homebrew's keg-only prefixes for you.

**Windows.** Visual Studio Build Tools with the C++ workload, a Windows SDK of **10.0.20348 or
newer**, CMake, and a real LLVM install for `libclang.dll`. The miner additionally needs Strawberry
Perl.

Two Windows traps the installer checks for so you do not lose an afternoon to them:

- SDK 10.0.19041 fails with `Cannot open include file: 'stdalign.h'`. The `croaring-sys` crate
  compiles with `-std:c11`, and MSVC only shipped the C11 headers from 10.0.20348 onward.
- The LLVM component bundled with Visual Studio contains only `clang-format` and `clang-tidy`, no
  `libclang.dll`. A separate LLVM install is required.

**Rust** is installed with rustup if it is missing, after asking. The node and wallet both pin
`1.89.0` in `rust-toolchain.toml`, so rustup selects the right compiler on its own.

## The miner

The miner needs more explanation than the others, because it is the one component where this
installer does not build the canonical upstream source.

`EpicCash/epic-miner` master is `9e33237` from September 2022 and does not compile on a current
toolchain. Its `Cargo.lock` pins `rustc-serialize 0.3.24`, which fails with `E0310` on modern rustc.
The crate is abandoned, but `0.3.25` exists specifically to fix that error. It arrives through
`rust-crypto` under `cuckoo_miner`, which `epic_miner_config` depends on unconditionally, so no
feature flag avoids it. `blacktyger/epic-miner` carries that fix along with three Windows build
fixes, and that is what gets built.

One problem remains after that, and it is why the installer touches source at all. Both the miner's
cuckoo build script and the `randomx-rust` build script ask the `cmake` crate for an empty build
target, which becomes `cmake --build . --target ""`. CMake used to tolerate that and now rejects it,
so the build dies partway through. Neither is skippable: `cuckoo_miner` is a non-optional dependency
of `epic_miner_config`, and `randomx` is a direct dependency of the miner.

The installer probes your CMake with a two-line throwaway project. If it rejects an empty target,
the installer shows you the change and asks before applying it:

```
cuckoo-miner/src/build.rs
    -  .build_target("")
    +  .no_build_target(true)
randomx-rust/build.rs
    -  .build_target("")
    +  .no_build_target(true)
```

Both spellings mean the same thing, configure and build the default target. Only the newer one is
accepted by current CMake. Pass `--no-patch-cmake` to refuse, and the installer will stop rather
than start a build it knows will fail. Once those two lines land in the forks, the probe stops
firing and nothing is patched.

There has never been a published miner binary for any platform, and mining plugins exist only for
Linux x86-64 and macOS. A stock Windows build is RandomX only.

## Notes for the curious

Things found while building this that are worth knowing:

- The official prebuilt Linux binaries for the node and wallet link against `GLIBC_2.39`, so they
  need Ubuntu 24.04 or newer. Building from source, which is what this installer does, has no such
  limit.
- `foundation.json` is not needed for v4. The node falls back to embedded foundation data, so the
  release tarball shipping only the binary is not the problem it looks like.
- The miner README documents `cargo build --no-default-features --features cuda,tui`. There is no
  `tui` feature in the manifest and cargo rejects it. The installer uses `--features cuda`.
- Release asset checksums published in GitHub release notes have disagreed with the actual files.
  Trust the `-sha256sum.txt` sidecar or the API digest, not the notes.

## Output

Steps are numbered, so a twenty minute compile is not a mystery. Long operations show a spinner
with elapsed time rather than the thousands of lines cargo and git produce, and those lines go to a
log instead:

```
[3/5] Node
        ✓ cloning epic at v4.0.3  0m19s
        epic is at 650b783
        ✓ compiling node  6m04s
```

When something fails, the last 25 lines of the log are printed, because that is where the error is,
and the full log path is given. Logs live in `~/.epic/install/logs`.

Colour and the spinner are used only when stdout is a terminal. Redirect it, or set `NO_COLOR`, and
the output is plain text with no escape codes.

## Design

The script is deliberately boring, and structured so you can audit it in one sitting.

- POSIX `sh`, no bashisms, so it runs under dash, bash, zsh and ksh alike. Checked with
  `shellcheck -s sh`.
- The whole body is a function called on the last line. A download cut off halfway therefore does
  nothing at all, instead of running the first half.
- `set -u` with explicit `ensure` wrappers rather than `set -e`, whose behaviour varies between
  shells and which aborts without saying what failed.
- `curl --proto '=https' --tlsv1.2`, so a redirect to plain HTTP is refused rather than followed.
- PATH is set by sourcing a generated `env` script from your startup file, once. Sourcing it twice is
  harmless, so reinstalling cannot corrupt anything.
- Every installed path is recorded in a receipt that accumulates across runs, and the uninstaller is
  generated from it.
- Nothing is reported as installed until the binary has been run and its version printed.
- Noisy commands run through one helper that logs their output, times them, and shows the tail of
  the log only on failure.

## Licence

MIT. See [LICENSE](LICENSE).

This installer is not an official Epic Cash project. It builds official sources.
