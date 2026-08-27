#!/bin/sh
# Epic Cash source installer for Linux and macOS.
#
# Builds the node, the wallet or the miner from pinned upstream sources and puts the binaries
# on your PATH. There are no prebuilt binaries involved, so what you run is what you compiled.
#
#   curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh | sh
#
# Read it before you run it:
#
#   curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh | less
#
# Pass options through the pipe with `sh -s --`:
#
#   curl -fsSL .../install.sh | sh -s -- --component node --yes
#
# Every option has an environment variable equivalent, which is easier to set on some shells.
# Run with --help for the full list.
#
# Design notes, because you are about to execute this:
#   - The whole script is a function called on the last line. A download that dies halfway
#     therefore does nothing at all, rather than running the first half.
#   - It never uses sudo on its own. System packages are only installed if you pass
#     --install-deps, and it prints the exact command first.
#   - It never touches wallet data and never runs `epic-wallet init`, because that generates a
#     seed. Creating a wallet stays your explicit step.
#   - It writes an uninstaller that removes exactly what it added.
#
# Licence: MIT. Source: https://github.com/blacktyger/epic-script

set -u

INSTALLER_VERSION="1.0.0"

# ---------------------------------------------------------------------------
# Pinned upstream sources.
#
# Release tags, not master, so a rerun a month from now builds the same code. The miner has
# never published a release or a tag, so it is pinned to the commit that master has sat on
# since September 2022.
# ---------------------------------------------------------------------------

NODE_REPO="https://github.com/EpicCash/epic.git"
NODE_REF="v4.0.3"
NODE_DIR="epic"
NODE_BIN="epic"

WALLET_REPO="https://github.com/EpicCash/epic-wallet.git"
WALLET_REF="v4.0.0"
WALLET_DIR="epic-wallet"
WALLET_BIN="epic-wallet"

# The miner comes from a fork, not from upstream, and that needs justifying because it is the
# one place this installer does not build the canonical source.
#
# EpicCash/epic-miner master is 9e33237 from September 2022 and does not compile on a current
# toolchain. Its Cargo.lock pins rustc-serialize 0.3.24, which fails with E0310 on modern
# rustc. The crate is abandoned, but 0.3.25 exists specifically to fix that, and it arrives
# through rust-crypto under cuckoo_miner, which epic_miner_config depends on unconditionally,
# so no feature flag avoids it. The fork carries that fix plus three Windows build fixes.
# Reasoning and per-blocker detail: https://github.com/blacktyger/epic-script#the-miner
MINER_REPO="https://github.com/blacktyger/epic-miner.git"
MINER_REF="e9d0d85dbb2db39aca66a3d1b5baf95788523694"
MINER_UPSTREAM="https://github.com/EpicCash/epic-miner.git"
MINER_DIR="epic-miner"
MINER_BIN="epic-miner"

# Disk needed per component, in MiB. Measured from real build trees: the node target/ came to
# 1.0G, the wallet 1.1G and the miner 394M. These add the checkout and some slack.
NODE_DISK_MB=2500
WALLET_DISK_MB=2500
MINER_DISK_MB=1200
CARGO_DISK_MB=800

# Chain snapshot for --fast-sync, so a new node does not have to validate from genesis.
#
# The wiki still points at bootstrap.epic.tech, which no longer resolves. This host is the
# current one. Override it with --bootstrap-url if a mirror is closer or this one is down.
BOOTSTRAP_URL_DEFAULT="https://bootstrap.epiccash.com/bootstrap.zip"

# Directories that identify an unpacked chain database, used to find the payload inside the
# archive rather than assuming its layout. From epic-server: chain, header, lmdb, peer,
# txhashset.
CHAIN_MARKERS="lmdb txhashset header chain peer"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

say() {
	printf 'epic-install: %s\n' "$1"
}

say_bare() {
	printf '%s\n' "$1"
}

warn() {
	printf 'epic-install: warning: %s\n' "$1" >&2
}

err() {
	printf 'epic-install: error: %s\n' "$1" >&2
	exit 1
}

# Run a command and abort with the command line if it fails. Used instead of `set -e`, whose
# behaviour varies between shells and which aborts with no indication of what broke.
ensure() {
	if ! "$@"; then
		err "command failed: $*"
	fi
}

check_cmd() {
	command -v "$1" >/dev/null 2>&1
}

need_cmd() {
	if ! check_cmd "$1"; then
		err "need '$1' and it is not on PATH"
	fi
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------

usage() {
	cat <<'HELPTEXT'
Epic Cash source installer.

Builds from pinned upstream sources and installs the binaries. Nothing prebuilt is downloaded.

USAGE
    install.sh [options]
    curl -fsSL <url>/install.sh | sh
    curl -fsSL <url>/install.sh | sh -s -- [options]

OPTIONS
    -c, --component <name>   node | wallet | miner | node_wallet | all
                             Default: node_wallet
    -y, --yes                Do not prompt. Required when piping without a terminal.
        --install-deps       Install missing system packages with the platform package
                             manager. Uses sudo on Linux. Off by default: without it, missing
                             packages are reported with the exact command to run.
        --check              Run the preflight checks and stop. Changes nothing.
        --fast-sync          Download a chain snapshot into ~/.epic/main/chain_data so a new
                             node does not validate from genesis. Node only.
        --bootstrap-url <u>  Where the snapshot comes from. Default:
                             https://bootstrap.epiccash.com/bootstrap.zip
        --with-tor           Build the node and wallet with --features with-tor.
        --miner-features <f> cpu | opencl | cuda. Default: cpu
        --bin-dir <path>     Where binaries go. Default: ~/.local/bin
        --src-dir <path>     Where sources are cloned and built. Default: ~/.epic/src
    -j, --jobs <n>           Parallel build jobs. Default: cargo's own choice.
        --no-modify-path     Do not touch shell startup files.
        --no-patch-cmake     Refuse the miner's two build-script fixes rather than applying
                             them. The miner will not build on a current CMake without them.
    -h, --help               This text.
    -V, --version            Installer version.

ENVIRONMENT
    Each option has an equivalent variable, which is the easier route through a pipe:

    EPIC_COMPONENT, EPIC_YES, EPIC_INSTALL_DEPS, EPIC_CHECK_ONLY, EPIC_WITH_TOR,
    EPIC_MINER_FEATURES, EPIC_BIN_DIR, EPIC_SRC_DIR, EPIC_JOBS, EPIC_NO_MODIFY_PATH,
    EPIC_NO_PATCH_CMAKE, EPIC_FAST_SYNC, EPIC_BOOTSTRAP_URL

    Set boolean ones to 1. For example:

    curl -fsSL <url>/install.sh | EPIC_COMPONENT=node EPIC_YES=1 sh

WHAT GETS INSTALLED
    node      epic            the blockchain node, with the integrated Stratum server
    wallet    epic-wallet     the wallet CLI and its Owner and Foreign APIs
    miner     epic-miner      the miner, plus its RandomX library and Cuckoo plugins in
                              ~/.epic/miner, reached through a launcher on your PATH

    An uninstaller is written to ~/.epic/install/uninstall.sh. It removes what this script
    added and leaves your chain data and wallets alone unless you pass it --purge-data.

BUILD TIME
    Expect 10 to 30 minutes per component on a normal laptop, and a few GB of disk. This is a
    from-source install: there is no faster path that does not involve trusting someone's
    binary.
HELPTEXT
}

# ---------------------------------------------------------------------------
# Platform detection
# ---------------------------------------------------------------------------

# Sets PLATFORM to linux or macos, ARCH to the uname machine, LIB_EXT to the shared library
# suffix and LIB_PATH_VAR to the loader search variable. The miner needs the last two.
detect_platform() {
	_ostype="$(uname -s)"
	_cputype="$(uname -m)"

	case "$_ostype" in
	Linux)
		PLATFORM="linux"
		LIB_EXT="so"
		LIB_PATH_VAR="LD_LIBRARY_PATH"
		;;
	Darwin)
		PLATFORM="macos"
		LIB_EXT="dylib"
		LIB_PATH_VAR="DYLD_LIBRARY_PATH"
		# uname -m reports x86_64 under Rosetta, so ask the kernel what the hardware is.
		if [ "$_cputype" = "x86_64" ] &&
			(sysctl hw.optional.arm64 2>/dev/null || true) | grep -q ': 1'; then
			_cputype="arm64"
		fi
		;;
	MINGW* | MSYS* | CYGWIN* | Windows_NT)
		err "this is the Unix installer. On Windows run the PowerShell one:
    powershell -ExecutionPolicy Bypass -c \"irm https://raw.githubusercontent.com/blacktyger/epic-script/main/install.ps1 | iex\""
		;;
	*)
		err "unsupported operating system '$_ostype'. This installer covers Linux and macOS."
		;;
	esac

	ARCH="$_cputype"
}

# Sets PKG_MGR and PKG_INSTALL_CMD from /etc/os-release, or Homebrew on macOS.
detect_pkg_mgr() {
	PKG_MGR=""
	PKG_INSTALL_CMD=""

	if [ "$PLATFORM" = "macos" ]; then
		if check_cmd brew; then
			PKG_MGR="brew"
			PKG_INSTALL_CMD="brew install"
		fi
		return 0
	fi

	# Prefer the binary that exists over the ID field, since derivatives are numerous and
	# ID_LIKE is not always set.
	if check_cmd apt-get; then
		PKG_MGR="apt"
		PKG_INSTALL_CMD="sudo apt-get install -y"
	elif check_cmd dnf; then
		PKG_MGR="dnf"
		PKG_INSTALL_CMD="sudo dnf install -y"
	elif check_cmd pacman; then
		PKG_MGR="pacman"
		PKG_INSTALL_CMD="sudo pacman -S --needed --noconfirm"
	elif check_cmd zypper; then
		PKG_MGR="zypper"
		PKG_INSTALL_CMD="sudo zypper install -y"
	elif check_cmd apk; then
		PKG_MGR="apk"
		PKG_INSTALL_CMD="sudo apk add"
	elif check_cmd yum; then
		PKG_MGR="yum"
		PKG_INSTALL_CMD="sudo yum install -y"
	fi
}

# The build dependencies, per package manager.
#
# The apt list is shorter than the upstream wiki's because the wiki's is wrong in two ways.
# `clang` and `llvm-dev` are not needed: the bindgen-based randomx and progpow crates want
# libclang.so, which comes from libclang-dev, not the clang driver. And libncurses-dev has
# provided the wide-character headers for years, so libncurses5-dev and libncursesw5-dev are
# obsolete names. Verified by building all three repositories with exactly this set.
pkg_list() {
	case "$PKG_MGR" in
	apt) echo "build-essential cmake git pkg-config libclang-dev libncurses-dev zlib1g-dev libssl-dev" ;;
	dnf | yum) echo "gcc gcc-c++ make cmake git pkgconf-pkg-config clang-devel ncurses-devel zlib-devel openssl-devel" ;;
	pacman) echo "base-devel cmake git pkgconf clang ncurses zlib openssl" ;;
	zypper) echo "gcc gcc-c++ make cmake git pkg-config clang-devel ncurses-devel zlib-devel libopenssl-devel" ;;
	apk) echo "build-base cmake git pkgconfig clang-dev ncurses-dev zlib-dev openssl-dev linux-headers perl" ;;
	brew) echo "cmake pkg-config ncurses zlib openssl@3" ;;
	*) echo "" ;;
	esac
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------

# bindgen needs the libclang shared library, not the clang driver, so look for the library.
has_libclang() {
	if [ -n "${LIBCLANG_PATH:-}" ] && [ -d "$LIBCLANG_PATH" ]; then
		return 0
	fi
	if check_cmd ldconfig && ldconfig -p 2>/dev/null | grep -q 'libclang'; then
		return 0
	fi
	for _dir in /usr/lib /usr/lib64 /usr/local/lib /usr/lib/llvm-*/lib /opt/homebrew/opt/llvm/lib /usr/local/opt/llvm/lib; do
		# The glob may not match, in which case the test simply fails.
		for _hit in "$_dir"/libclang.so* "$_dir"/libclang.dylib; do
			if [ -e "$_hit" ]; then
				return 0
			fi
		done
	done
	# The macOS command line tools ship libclang inside the active developer directory.
	if [ "$PLATFORM" = "macos" ] && check_cmd xcode-select; then
		_devdir="$(xcode-select -p 2>/dev/null || true)"
		if [ -n "$_devdir" ] && [ -e "$_devdir/usr/lib/libclang.dylib" ]; then
			return 0
		fi
	fi
	return 1
}

# Homebrew keeps openssl and zlib out of the default search paths, so point pkg-config at them.
setup_macos_env() {
	[ "$PLATFORM" = "macos" ] || return 0
	check_cmd brew || return 0

	for _formula in openssl@3 zlib ncurses; do
		_prefix="$(brew --prefix "$_formula" 2>/dev/null || true)"
		if [ -n "$_prefix" ] && [ -d "$_prefix/lib/pkgconfig" ]; then
			PKG_CONFIG_PATH="$_prefix/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
		fi
	done
	if [ -n "${PKG_CONFIG_PATH:-}" ]; then
		export PKG_CONFIG_PATH
	fi
}

# Fills MISSING_TOOLS with commands that are absent, and MISSING_LIBS with development
# libraries that are absent. Neither aborts: the caller decides what to do.
check_build_deps() {
	MISSING_TOOLS=""
	MISSING_LIBS=""

	for _tool in git cmake make pkg-config; do
		check_cmd "$_tool" || MISSING_TOOLS="$MISSING_TOOLS $_tool"
	done

	# Any C compiler will do; cargo only needs a working linker driver.
	if ! check_cmd cc && ! check_cmd gcc && ! check_cmd clang; then
		MISSING_TOOLS="$MISSING_TOOLS c-compiler"
	fi

	# The miner vendors OpenSSL and builds it with OpenSSL's own Configure script, which is
	# written in Perl.
	if want_miner && ! check_cmd perl; then
		MISSING_TOOLS="$MISSING_TOOLS perl"
	fi

	has_libclang || MISSING_LIBS="$MISSING_LIBS libclang"

	# Unpacking the chain snapshot needs one of these.
	if [ "$FAST_SYNC" = "1" ] && ! check_cmd unzip && ! check_cmd python3; then
		MISSING_TOOLS="$MISSING_TOOLS unzip"
	fi

	if check_cmd pkg-config; then
		pkg-config --exists ncursesw 2>/dev/null ||
			pkg-config --exists ncurses 2>/dev/null ||
			MISSING_LIBS="$MISSING_LIBS ncurses"
		pkg-config --exists zlib 2>/dev/null || MISSING_LIBS="$MISSING_LIBS zlib"
		pkg-config --exists openssl 2>/dev/null || MISSING_LIBS="$MISSING_LIBS openssl"
	fi
}

# Free space in MiB on the filesystem that will hold the given directory. Walks up to the
# nearest existing ancestor, since the target usually does not exist yet.
free_mb() {
	_dir="$1"
	while [ ! -d "$_dir" ] && [ "$_dir" != "/" ]; do
		_dir="$(dirname "$_dir")"
	done
	# -P forces POSIX single-line output, so field 4 is reliably the available blocks.
	df -Pk "$_dir" 2>/dev/null | awk 'NR==2 {print int($4/1024)}'
}

required_disk_mb() {
	_total="$CARGO_DISK_MB"
	want_node && _total=$((_total + NODE_DISK_MB))
	want_wallet && _total=$((_total + WALLET_DISK_MB))
	want_miner && _total=$((_total + MINER_DISK_MB))
	echo "$_total"
}

check_disk() {
	_need="$(required_disk_mb)"
	_have="$(free_mb "$SRC_DIR")"

	if [ -z "$_have" ]; then
		warn "could not determine free disk space for $SRC_DIR. Builds need about ${_need} MiB."
		return 0
	fi
	say "disk: ${_have} MiB free where sources are built, about ${_need} MiB needed"
	if [ "$_have" -lt "$_need" ]; then
		err "not enough free disk space: ${_have} MiB available, about ${_need} MiB needed.
    Point --src-dir at a roomier filesystem, or install one component at a time."
	fi
}

# The miner's build scripts ask the cmake crate for an empty build target, which becomes
# `cmake --build . --target ""`. CMake used to tolerate that and now rejects it, so the build
# dies partway through. Two files are affected, in two different repositories:
#
#   cuckoo-miner/src/build.rs   in epic-miner
#   randomx-rust/build.rs       in the randomx-rust submodule
#
# Neither is skippable. cuckoo_miner is a non-optional dependency of epic_miner_config, and
# randomx is a direct dependency of the miner itself.
#
# This probe costs a second and decides whether the one-line fix below is needed. Once both
# forks carry no_build_target, the probe stops firing and the patching never runs.
check_cmake_empty_target() {
	CMAKE_NEEDS_PATCH=0
	check_cmd cmake || return 0

	_probe="$WORK_TMP/cmake-probe"
	mkdir -p "$_probe/build" 2>/dev/null || return 0
	printf 'cmake_minimum_required(VERSION 3.5)\nproject(probe C)\nadd_library(probe STATIC probe.c)\n' \
		>"$_probe/CMakeLists.txt"
	printf 'int probe(void){return 0;}\n' >"$_probe/probe.c"

	if ! (cd "$_probe/build" && cmake .. >/dev/null 2>&1); then
		# If cmake cannot configure a two-line project, let the real build report why.
		return 0
	fi

	if (cd "$_probe/build" && cmake --build . --target "" --config Release >/dev/null 2>&1); then
		return 0
	fi

	CMAKE_NEEDS_PATCH=1
	say "cmake: $(cmake --version | head -n 1) rejects an empty build target"
}

# Replace `.build_target("")` with `.no_build_target(true)` in the miner's two build scripts.
#
# This is the only place the installer changes source before compiling it, so it is disclosed
# in full and confirmed. The two calls are equivalent in intent: both mean "configure and build
# the default target". Only the newer spelling is accepted by current CMake.
patch_cmake_build_scripts() {
	_root="$SRC_DIR/$MINER_DIR"
	_targets="cuckoo-miner/src/build.rs randomx-rust/build.rs"

	say_bare ""
	say "the miner's build scripts need a one-line change each to build with this CMake:"
	for _f in $_targets; do
		[ -f "$_root/$_f" ] || continue
		if grep -q '\.build_target("")' "$_root/$_f" 2>/dev/null; then
			say_bare "    $_f"
			say_bare "        -  .build_target(\"\")"
			say_bare "        +  .no_build_target(true)"
		fi
	done
	say_bare ""

	if [ "$NO_PATCH_CMAKE" = "1" ]; then
		err "the miner cannot build with this CMake and --no-patch-cmake was passed.
    Apply the two changes above in $_root and run cargo build --release there,
    or install the node and wallet instead with --component node_wallet."
	fi

	if ! confirm "Apply those two changes to the checkout and continue?"; then
		err "declined. The miner cannot build with this CMake unless they are applied."
	fi

	_changed=0
	for _f in $_targets; do
		if [ ! -f "$_root/$_f" ]; then
			warn "expected $_f in the checkout and it is not there, skipping"
			continue
		fi
		if ! grep -q '\.build_target("")' "$_root/$_f" 2>/dev/null; then
			say "$_f already uses no_build_target, nothing to change"
			continue
		fi

		# sed -i is not portable between GNU and BSD, so write through a temporary file.
		sed 's|\.build_target("")|.no_build_target(true)|' "$_root/$_f" >"$WORK_TMP/patched.rs" ||
			err "could not rewrite $_f"
		ensure cp "$WORK_TMP/patched.rs" "$_root/$_f"

		grep -q '\.no_build_target(true)' "$_root/$_f" ||
			err "rewrote $_f but the change is not present. Stopping rather than guessing."
		say "patched $_f"
		_changed=$((_changed + 1))
	done

	if [ "$_changed" -eq 0 ]; then
		say "no changes were needed"
	fi
}

# ---------------------------------------------------------------------------
# Rust toolchain
# ---------------------------------------------------------------------------

# The node and wallet both carry rust-toolchain.toml pinning 1.89.0, so rustup selects the
# right compiler on its own and no toolchain argument should ever be passed. A plain distro
# rustc is used as-is, and may be too old; cargo will say so clearly if it is.
ensure_rust() {
	if check_cmd cargo; then
		say "cargo: $(cargo --version 2>/dev/null || echo 'present')"
		if ! check_cmd rustup; then
			warn "rustup is not installed, so the toolchain pinned by rust-toolchain.toml (1.89.0)
    cannot be selected automatically. The build will use the cargo already on PATH and may
    fail on a version error."
		fi
		return 0
	fi

	say "cargo is not on PATH, so Rust needs installing."
	if ! confirm "Install the Rust toolchain with rustup, from https://sh.rustup.rs?"; then
		err "Rust is required. Install it and rerun:
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
	fi

	if check_cmd curl; then
		ensure curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o "$WORK_TMP/rustup-init.sh"
	elif check_cmd wget; then
		ensure wget --https-only --secure-protocol=TLSv1_2 -qO "$WORK_TMP/rustup-init.sh" https://sh.rustup.rs
	else
		err "need curl or wget to fetch rustup"
	fi

	ensure chmod +x "$WORK_TMP/rustup-init.sh"
	ensure "$WORK_TMP/rustup-init.sh" -y --no-modify-path

	# rustup put cargo here but this shell's PATH predates it.
	CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
	PATH="$CARGO_HOME_DIR/bin:$PATH"
	export PATH

	check_cmd cargo || err "rustup finished but cargo is still not on PATH"
	say "installed $(cargo --version)"
	RUSTUP_WAS_INSTALLED=1
}

# ---------------------------------------------------------------------------
# Prompting
#
# When this script is piped into sh, stdin is the script itself, so a bare `read` would eat
# the rest of the file. Read from the terminal instead.
# ---------------------------------------------------------------------------

confirm() {
	_question="$1"

	if [ "$ASSUME_YES" = "1" ]; then
		return 0
	fi

	if [ ! -t 0 ]; then
		# Piped, so stdin is the script. A prompt can still work by reading the terminal
		# directly, but only when there is a human at one. If stdout is redirected as well then
		# nobody is watching, and reading /dev/tty would block forever: /dev/tty can be readable
		# in a CI job that will never type anything. Refusing is the only safe answer.
		if [ ! -t 1 ] || [ ! -r /dev/tty ]; then
			err "cannot prompt, and this needs an answer: $_question
    There is no terminal attached, which is normal when piping into sh from a script or CI.
    Rerun with --yes, or set EPIC_YES=1, to accept without prompting."
		fi
	fi

	printf '%s [y/N] ' "$_question"
	if [ -t 0 ]; then
		read -r _answer || _answer=""
	else
		read -r _answer </dev/tty || _answer=""
	fi

	case "$_answer" in
	y | Y | yes | YES | Yes) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Component selection
# ---------------------------------------------------------------------------

want_node() {
	case "$COMPONENT" in
	node | node_wallet | all) return 0 ;;
	*) return 1 ;;
	esac
}

want_wallet() {
	case "$COMPONENT" in
	wallet | node_wallet | all) return 0 ;;
	*) return 1 ;;
	esac
}

want_miner() {
	case "$COMPONENT" in
	miner | all) return 0 ;;
	*) return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Source and build
# ---------------------------------------------------------------------------

# Clone at an exact ref, or update an existing checkout to it. Kept shallow where possible,
# because nobody needs the full history to compile a tag.
fetch_source() {
	_repo="$1"
	_dir="$SRC_DIR/$2"
	_ref="$3"
	_recursive="$4"

	if [ -d "$_dir/.git" ]; then
		# An existing checkout may point somewhere else, either from an older version of this
		# installer or from the user's own clone. Fetching without fixing that would look for
		# the pinned ref in the wrong repository and fail with a confusing checkout error.
		_origin="$(git -C "$_dir" remote get-url origin 2>/dev/null || echo "")"
		if [ "$_origin" != "$_repo" ]; then
			say "$2 points at ${_origin:-nothing}, repointing origin at $_repo"
			if [ -n "$_origin" ]; then
				ensure git -C "$_dir" remote set-url origin "$_repo"
			else
				ensure git -C "$_dir" remote add origin "$_repo"
			fi
		fi
		say "updating $2 to $_ref"
		ensure git -C "$_dir" fetch --tags --force origin
		ensure git -C "$_dir" checkout --force "$_ref"
	else
		say "cloning $2 at $_ref (this is the slow part on a cold cache)"
		ensure git clone --quiet "$_repo" "$_dir"
		ensure git -C "$_dir" checkout --force "$_ref"
	fi

	if [ "$_recursive" = "yes" ]; then
		# The miner's .gitmodules uses relative URLs, so these resolve against whichever
		# account owns the parent. Cloning from EpicCash therefore picks up
		# EpicCash/randomx-rust and EpicCash/progpow-rust, which is what we want.
		say "fetching $2 submodules"
		ensure git -C "$_dir" submodule update --init --recursive
	fi

	# Report exactly what is about to be compiled. This is the one line a careful user checks.
	say "$2 is at $(git -C "$_dir" rev-parse --short HEAD)"
}

# Build one crate. cargo output is not captured, so progress is visible: a silent 20 minute
# wait is indistinguishable from a hang.
run_cargo_build() {
	_dir="$1"
	shift

	say "building in $_dir"
	say_bare ""
	# shellcheck disable=SC2086
	# JOBS_ARG is intentionally word-split: it is either empty or `-j N`.
	if ! (cd "$_dir" && cargo build --release $JOBS_ARG "$@"); then
		say_bare ""
		err "the build failed in $_dir.
    The cargo error above is the real cause. Common ones:
      - a missing development library, so rerun with --check to list them
      - too little disk or memory, since these are large Rust workspaces
    Sources are kept at $_dir, so you can retry there without recloning."
	fi
	say_bare ""
}

build_node() {
	fetch_source "$NODE_REPO" "$NODE_DIR" "$NODE_REF" "no"
	if [ "$WITH_TOR" = "1" ]; then
		run_cargo_build "$SRC_DIR/$NODE_DIR" --features with-tor
	else
		run_cargo_build "$SRC_DIR/$NODE_DIR"
	fi
}

build_wallet() {
	fetch_source "$WALLET_REPO" "$WALLET_DIR" "$WALLET_REF" "no"
	if [ "$WITH_TOR" = "1" ]; then
		run_cargo_build "$SRC_DIR/$WALLET_DIR" --features with-tor
	else
		run_cargo_build "$SRC_DIR/$WALLET_DIR"
	fi
}

build_miner() {
	fetch_source "$MINER_REPO" "$MINER_DIR" "$MINER_REF" "yes"

	# The checkout above resets the working tree, so this runs on every build rather than once.
	if [ "$CMAKE_NEEDS_PATCH" = "1" ]; then
		patch_cmake_build_scripts
	fi

	case "$MINER_FEATURES" in
	cpu)
		run_cargo_build "$SRC_DIR/$MINER_DIR"
		;;
	opencl)
		run_cargo_build "$SRC_DIR/$MINER_DIR" --features opencl
		;;
	cuda)
		# Upstream's README documents `--features cuda,tui` here, which cannot work: there is
		# no `tui` feature in the manifest and cargo rejects it outright.
		run_cargo_build "$SRC_DIR/$MINER_DIR" --no-default-features --features cuda
		;;
	*)
		err "unknown --miner-features '$MINER_FEATURES'. Use cpu, opencl or cuda."
		;;
	esac
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------

# Everything installed is appended here so the uninstaller can be generated from facts rather
# than from guesses about what the script might have done.
#
# The receipt is cumulative across runs and deduplicated. Truncating it per run was a bug: a
# user who installs the node today and the wallet next week would otherwise end up with an
# uninstaller that only knows about the wallet, orphaning the node binary.
record() {
	if [ -f "$RECEIPT" ] && grep -qxF "$1" "$RECEIPT" 2>/dev/null; then
		return 0
	fi
	printf '%s\n' "$1" >>"$RECEIPT"
}

install_binary() {
	_src="$1"
	_name="$2"

	[ -f "$_src" ] || err "expected a built binary at $_src and it is not there"
	ensure install -m 755 "$_src" "$BIN_DIR/$_name"
	record "$BIN_DIR/$_name"
	say "installed $BIN_DIR/$_name"
}

# The miner is not a single binary. It loads RandomX as a shared library, needs its Cuckoo
# plugins on disk, and refuses to start without an epic-miner.toml in the working directory.
# So it gets its own directory and a launcher that supplies all three.
install_miner() {
	_build="$SRC_DIR/$MINER_DIR/target/release"

	ensure mkdir -p "$MINER_HOME"

	# The real binary goes inside the miner directory rather than onto PATH, because it cannot
	# run without the environment the launcher supplies.
	[ -f "$_build/$MINER_BIN" ] || err "expected a built miner at $_build/$MINER_BIN"
	ensure install -m 755 "$_build/$MINER_BIN" "$MINER_HOME/$MINER_BIN"

	# Unlike the node, which links RandomX statically, the miner links it dynamically and
	# leaves the library deep in the build tree, where the loader will not find it.
	_randomx="$(find "$_build/build" -name "librandomx.$LIB_EXT" -print 2>/dev/null | head -n 1)"
	if [ -n "$_randomx" ]; then
		ensure install -m 755 "$_randomx" "$MINER_HOME/librandomx.$LIB_EXT"
		say "installed librandomx.$LIB_EXT beside the miner"
	else
		warn "no librandomx.$LIB_EXT found in the build tree. If the miner fails to start with a
    loader error, that is why."
	fi

	if [ -d "$_build/plugins" ]; then
		ensure mkdir -p "$MINER_HOME/plugins"
		ensure cp -R "$_build/plugins/." "$MINER_HOME/plugins/"
		say "installed $(find "$MINER_HOME/plugins" -type f | wc -l | tr -d ' ') mining plugins"
	fi

	# Never overwrite a config the user may have tuned.
	if [ -f "$MINER_HOME/epic-miner.toml" ]; then
		say "kept the existing $MINER_HOME/epic-miner.toml"
	else
		ensure cp "$SRC_DIR/$MINER_DIR/epic-miner.toml" "$MINER_HOME/epic-miner.toml"
		# Point the commented-out plugin directory at the installed one. Editing in place is
		# not portable across GNU and BSD sed, so write through a temporary file.
		sed "s|^#miner_plugin_dir = .*|miner_plugin_dir = \"$MINER_HOME/plugins\"|" \
			"$MINER_HOME/epic-miner.toml" >"$WORK_TMP/epic-miner.toml"
		ensure mv "$WORK_TMP/epic-miner.toml" "$MINER_HOME/epic-miner.toml"
		say "wrote $MINER_HOME/epic-miner.toml with miner_plugin_dir set"
	fi

	# The launcher runs the miner from the user's own directory when that directory has a
	# config, and from the installed one otherwise.
	cat >"$BIN_DIR/$MINER_BIN" <<LAUNCHER
#!/bin/sh
# Generated by epic-install. Supplies the RandomX library path, the plugin directory and a
# working directory containing epic-miner.toml, none of which the miner can find on its own.
set -u
EPIC_MINER_HOME="$MINER_HOME"
if [ ! -f ./epic-miner.toml ]; then
	cd "\$EPIC_MINER_HOME" || exit 1
fi
$LIB_PATH_VAR="\$EPIC_MINER_HOME\${$LIB_PATH_VAR:+:\$$LIB_PATH_VAR}"
export $LIB_PATH_VAR
exec "\$EPIC_MINER_HOME/$MINER_BIN" "\$@"
LAUNCHER
	ensure chmod 755 "$BIN_DIR/$MINER_BIN"
	record "$BIN_DIR/$MINER_BIN"
	say "installed $BIN_DIR/$MINER_BIN as a launcher for $MINER_HOME/$MINER_BIN"
}

# ---------------------------------------------------------------------------
# Fast sync
#
# A fresh node validates the whole chain from genesis, which takes hours. The project publishes
# a snapshot of the chain database, and dropping that in beforehand turns the wait into a
# download.
#
# Worth understanding before using it: this is somebody else's copy of the chain database,
# fetched over TLS with no signature published alongside it. The node still verifies the
# proof-of-work and the MMR roots as it loads and continues, so a doctored snapshot does not let
# anyone hand you fake coins. It is a much weaker guarantee than validating from genesis
# yourself, and it is exactly the same trade-off the official docs describe. Skip the flag if
# you would rather wait.
# ---------------------------------------------------------------------------

# Content-Length of the archive in MiB, or empty when the server will not say.
bootstrap_size_mb() {
	_headers="$(curl -fsSIL --max-time 30 "$BOOTSTRAP_URL" 2>/dev/null || true)"
	[ -n "$_headers" ] || return 0
	# Take the last Content-Length, since redirects contribute their own. tr strips the CR that
	# HTTP line endings leave behind, which otherwise poisons the arithmetic.
	printf '%s' "$_headers" |
		tr -d '\r' |
		awk 'BEGIN{IGNORECASE=1} /^content-length:/ {n=$2} END{if (n>0) print int(n/1048576)}'
}

# Find the chain database inside the extracted archive, whatever it was wrapped in.
find_chain_payload() {
	_staging="$1"

	# The usual case: the archive contains a chain_data directory somewhere near the top.
	_hit="$(find "$_staging" -maxdepth 3 -type d -name chain_data 2>/dev/null | head -n 1)"
	if [ -n "$_hit" ]; then
		printf '%s' "$_hit"
		return 0
	fi

	# Otherwise the archive may hold the database contents directly, either at the root or one
	# level down. Identify it by the directories a chain database always has.
	for _candidate in "$_staging" "$_staging"/*; do
		[ -d "$_candidate" ] || continue
		for _marker in $CHAIN_MARKERS; do
			if [ -d "$_candidate/$_marker" ]; then
				printf '%s' "$_candidate"
				return 0
			fi
		done
	done

	return 1
}

# Move the unpacked database into place and clear the staging tree.
#
# Separated out because this is the only part of fast sync that touches data the user may
# already care about, so it is worth being able to read and test on its own.
place_chain_payload() {
	_payload="$1"
	_chain="$2"
	_staging="$3"
	_zip="$4"

	# Move the old directory aside rather than deleting it first, so a failure here leaves a
	# recoverable chain instead of a destroyed one.
	CHAIN_BACKUP=""
	if [ -d "$_chain" ]; then
		CHAIN_BACKUP="$_chain.replaced-$(date +%Y%m%d%H%M%S)"
		ensure mv "$_chain" "$CHAIN_BACKUP"
	fi

	ensure mkdir -p "$(dirname "$_chain")"
	ensure mv "$_payload" "$_chain"

	# Only the archive and the staging tree are removed, and both were created by this script.
	rm -f "$_zip"
	rm -rf "$_staging/extracted"
	rmdir "$_staging" 2>/dev/null || true
}

# Guidance printed whenever the snapshot cannot be fetched or used. The install itself has already
# succeeded by this point, so this is advice, not an error.
bootstrap_manual_help() {
	say_bare ""
	say_bare "    The node and wallet are installed and work. Only the snapshot is missing, so the"
	say_bare "    node will validate from genesis instead. That is slower, and it is also the"
	say_bare "    stronger guarantee, so it is a perfectly good outcome."
	say_bare ""
	say_bare "    To bootstrap by hand later, from a machine or network that can reach the file:"
	say_bare ""
	say_bare "        curl -LO $BOOTSTRAP_URL"
	say_bare "        unzip bootstrap.zip"
	say_bare "        # the archive holds a chain_data directory. Move it here:"
	say_bare "        mv chain_data \"$HOME/.epic/main/chain_data\""
	say_bare ""
	say_bare "    Stop the node first if it is running, and check the file in a browser if curl"
	say_bare "    fails: a home or corporate content filter blocking the host is a common cause,"
	say_bare "    and it returns a web page rather than an archive."
	say_bare "        $BOOTSTRAP_URL"
}

# Records the outcome and returns non-zero, so fast sync failing never fails the install.
fast_sync_failed() {
	FAST_SYNC_STATUS="failed"
	warn "$1"
	bootstrap_manual_help
	return 1
}

fast_sync() {
	_home="$HOME/.epic/main"
	_chain="$_home/chain_data"
	# Staged on the same filesystem as the target, so the final move is a rename rather than a
	# multi-gigabyte copy, and so a large archive does not fill /tmp.
	_staging="$_home/.fast-sync"
	_zip="$_staging/bootstrap.zip"

	say_bare ""
	say "fast sync: fetching a chain snapshot so the node does not validate from genesis"
	say "source: $BOOTSTRAP_URL"

	if [ -d "$_chain" ]; then
		say_bare ""
		warn "chain data already exists at $_chain"
		say_bare "    Replacing it discards the chain you already have. Wallet files are not"
		say_bare "    touched either way, and a node that is currently running must be stopped first."
		if ! confirm "Replace the existing chain data at $_chain?"; then
			say "keeping the existing chain data, skipping fast sync"
			FAST_SYNC_STATUS="skipped"
			return 0
		fi
	fi

	ensure mkdir -p "$_staging"

	# Check space before pulling gigabytes. The archive plus its expansion needs roughly two and
	# a half times the download.
	_size="$(bootstrap_size_mb)"
	if [ -n "$_size" ] && [ "$_size" -gt 0 ]; then
		_need=$((_size * 5 / 2))
		_have="$(free_mb "$_home")"
		say "snapshot is about ${_size} MiB, so about ${_need} MiB is needed to unpack it"
		if [ -n "$_have" ] && [ "$_have" -lt "$_need" ]; then
			fast_sync_failed "not enough free disk space for the snapshot: ${_have} MiB available,
    about ${_need} MiB needed."
			return 0
		fi
	else
		warn "the server did not report a size, so free space cannot be checked in advance"
	fi

	say "downloading, which takes a while and shows progress"
	say_bare ""

	# Resuming a multi-gigabyte download matters on a flaky link, but resuming blindly does not
	# work: a leftover archive from an earlier run, or from a different URL, would be appended to
	# or accepted as complete. So the URL that produced the partial file is recorded next to it
	# and resume only happens when it still matches.
	_stamp="$_staging/bootstrap.url"
	_resume_curl=""
	_resume_wget=""
	if [ -f "$_zip" ] && [ -f "$_stamp" ] && [ "$(cat "$_stamp" 2>/dev/null)" = "$BOOTSTRAP_URL" ]; then
		say "resuming the partial download already in $_staging"
		_resume_curl="-C -"
		_resume_wget="-c"
	else
		rm -f "$_zip"
	fi
	printf '%s\n' "$BOOTSTRAP_URL" >"$_stamp"

	if check_cmd curl; then
		# shellcheck disable=SC2086
		# _resume_curl is intentionally word-split: it is either empty or `-C -`.
		if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 $_resume_curl --progress-bar \
			-o "$_zip" "$BOOTSTRAP_URL"; then
			fast_sync_failed "could not download the snapshot from $BOOTSTRAP_URL"
			return 0
		fi
	elif check_cmd wget; then
		# shellcheck disable=SC2086
		if ! wget --https-only $_resume_wget -O "$_zip" "$BOOTSTRAP_URL"; then
			fast_sync_failed "could not download the snapshot from $BOOTSTRAP_URL"
			return 0
		fi
	else
		fast_sync_failed "need curl or wget to download the snapshot, and neither is on PATH"
		return 0
	fi
	say_bare ""

	# A content filter, a proxy or an error page will happily arrive with a 200, so check the
	# magic bytes rather than trusting the extension.
	if [ "$(dd if="$_zip" bs=2 count=1 2>/dev/null)" != "PK" ]; then
		fast_sync_failed "what arrived from $BOOTSTRAP_URL is not a zip archive.
    A captive portal, a proxy or an ISP content filter returning a web page is the usual cause.
    The file is at $_zip if you want to look at it."
		return 0
	fi

	say "unpacking"
	# Cleared first, so files left by an earlier failed attempt cannot be mistaken for the
	# contents of this archive.
	rm -rf "$_staging/extracted"
	if check_cmd unzip; then
		if ! unzip -q -o "$_zip" -d "$_staging/extracted"; then
			fast_sync_failed "the snapshot downloaded but will not unpack, so it is probably
    truncated. Delete $_zip and try again."
			return 0
		fi
	elif check_cmd python3; then
		if ! python3 -c 'import sys,zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' \
			"$_zip" "$_staging/extracted"; then
			fast_sync_failed "the snapshot downloaded but will not unpack, so it is probably
    truncated. Delete $_zip and try again."
			return 0
		fi
	else
		fast_sync_failed "need unzip or python3 to unpack the snapshot, and neither is on PATH"
		return 0
	fi

	_payload="$(find_chain_payload "$_staging/extracted")" || _payload=""
	if [ -z "$_payload" ]; then
		fast_sync_failed "unpacked the snapshot but found no chain database inside it.
    Expected a chain_data directory, or one containing any of: $CHAIN_MARKERS
    The unpacked files are at $_staging/extracted if you want to move them by hand."
		return 0
	fi
	say "found the chain database at ${_payload#"$_staging/extracted/"}"

	place_chain_payload "$_payload" "$_chain" "$_staging" "$_zip"
	say "removed the archive and the staging directory"

	say "chain data is in place at $_chain"
	FAST_SYNC_STATUS="ok"
	if [ -n "$CHAIN_BACKUP" ]; then
		say_bare ""
		say "your previous chain data was moved to $CHAIN_BACKUP rather than deleted."
		say "Delete it yourself once the node starts cleanly."
	fi
}

# ---------------------------------------------------------------------------
# PATH
# ---------------------------------------------------------------------------

# An env script sourced from the shell startup file, rather than a PATH line appended to it.
# Sourcing the same file twice is harmless, so a reinstall cannot corrupt anything, and the
# uninstaller has one line to remove instead of a pattern to match.
setup_path() {
	case ":$PATH:" in
	*:"$BIN_DIR":*)
		say "$BIN_DIR is already on PATH, leaving shell startup files alone"
		return 0
		;;
	esac

	if [ "$NO_MODIFY_PATH" = "1" ]; then
		PATH_NEEDS_ACTION=1
		return 0
	fi

	ensure mkdir -p "$INSTALL_META"

	# $HOME is written literally rather than expanded, so the line survives the home
	# directory moving.
	_dir_expr="$(printf '%s' "$BIN_DIR" | sed "s|^$HOME|\$HOME|")"

	cat >"$INSTALL_META/env" <<ENVSH
#!/bin/sh
# Generated by epic-install. Adds the Epic binaries to PATH, once.
case ":\${PATH}:" in
	*:"$_dir_expr":*) ;;
	*) export PATH="$_dir_expr:\$PATH" ;;
esac
ENVSH
	record "$INSTALL_META/env"

	_meta_expr="$(printf '%s' "$INSTALL_META" | sed "s|^$HOME|\$HOME|")"
	_source_line=". \"$_meta_expr/env\""

	_edited=""
	_found=0
	for _rc in .profile .bashrc .bash_profile .zshrc; do
		_target="$HOME/$_rc"
		[ -f "$_target" ] || continue
		_found=$((_found + 1))
		# Record the file whether or not the line needs adding. On a rerun the line is already
		# there, and forgetting it here would leave the uninstaller unable to clean it up.
		record "rcline:$_target"
		if grep -F "$_meta_expr/env" "$_target" >/dev/null 2>&1; then
			continue
		fi
		printf '\n# Added by epic-install\n%s\n' "$_source_line" >>"$_target"
		_edited="$_edited $_rc"
	done

	# fish cannot source a POSIX script, so it gets its own conf.d snippet.
	if [ -d "$HOME/.config/fish" ]; then
		ensure mkdir -p "$HOME/.config/fish/conf.d"
		cat >"$HOME/.config/fish/conf.d/epic-install.fish" <<FISHSH
# Generated by epic-install.
if not contains "$BIN_DIR" \$PATH
	set -x PATH "$BIN_DIR" \$PATH
end
FISHSH
		record "$HOME/.config/fish/conf.d/epic-install.fish"
		_edited="$_edited fish"
	fi

	if [ -n "$_edited" ]; then
		say "added $BIN_DIR to PATH via:$_edited"
		PATH_NEEDS_RELOAD=1
	elif [ "$_found" -gt 0 ]; then
		say "PATH is already configured in your shell startup files"
	else
		warn "found no shell startup file to update. Add this to yours:
    export PATH=\"$BIN_DIR:\$PATH\""
	fi

	# Make the rest of this run see the binaries.
	PATH="$BIN_DIR:$PATH"
	export PATH
}

# ---------------------------------------------------------------------------
# Uninstaller
# ---------------------------------------------------------------------------

write_uninstaller() {
	ensure mkdir -p "$INSTALL_META"

	{
		cat <<'UNHEAD'
#!/bin/sh
# Generated by epic-install. Removes what the installer added, and nothing else.
#
#   sh ~/.epic/install/uninstall.sh              binaries, launcher, PATH lines
#   sh ~/.epic/install/uninstall.sh --purge-data  also chain data and wallets
#
# Without --purge-data your wallet seeds and chain data under ~/.epic are left untouched.
set -u

PURGE=0
[ "${1:-}" = "--purge-data" ] && PURGE=1

say() { printf 'epic-uninstall: %s\n' "$1"; }

UNHEAD

		# Files, in reverse order so directories empty before they are removed.
		printf 'say "removing installed files"\n'
		while IFS= read -r _line; do
			case "$_line" in
			rcline:*) ;;
			*)
				printf 'rm -f "%s" && say "removed %s"\n' "$_line" "$_line"
				;;
			esac
		done <"$RECEIPT"

		# The miner directory holds only installed artefacts and a generated config.
		if [ -d "$MINER_HOME" ]; then
			printf 'rm -rf "%s" && say "removed %s"\n' "$MINER_HOME" "$MINER_HOME"
		fi

		# Startup file lines. Removed by exact text, so an unrelated PATH edit is untouched.
		_meta_expr="$(printf '%s' "$INSTALL_META" | sed "s|^$HOME|\$HOME|")"
		printf '\nsay "cleaning shell startup files"\n'
		grep '^rcline:' "$RECEIPT" 2>/dev/null | sed 's/^rcline://' | sort -u | while IFS= read -r _rc; do
			cat <<UNRC
if [ -f "$_rc" ]; then
	grep -v -F '$_meta_expr/env' "$_rc" | grep -v '^# Added by epic-install\$' > "$_rc.epic-tmp" &&
		mv "$_rc.epic-tmp" "$_rc" && say "cleaned $_rc"
fi
UNRC
		done

		cat <<UNTAIL

if [ "\$PURGE" = "1" ]; then
	say "removing chain data and wallets under $HOME/.epic"
	printf 'This deletes wallet seeds and cannot be undone. Type DELETE to confirm: '
	read -r _c
	if [ "\$_c" = "DELETE" ]; then
		rm -rf "$HOME/.epic/main" "$HOME/.epic/floonet" "$HOME/.epic/usernet" "$SRC_DIR"
		say "removed chain data, wallets and sources"
	else
		say "left your data alone"
	fi
else
	say "left chain data and wallets under $HOME/.epic alone, and sources at $SRC_DIR"
	say "pass --purge-data to remove those too"
fi

rm -f "$RECEIPT"
say "done. Open a new shell so the PATH change takes effect."
UNTAIL
	} >"$INSTALL_META/uninstall.sh"

	ensure chmod 755 "$INSTALL_META/uninstall.sh"
	say "wrote $INSTALL_META/uninstall.sh"
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

# An install is not finished because the copy succeeded. Run each binary and show its version.
verify_install() {
	_failed=""

	say_bare ""
	say "verifying"

	if want_node; then
		if _v="$("$BIN_DIR/$NODE_BIN" --version 2>&1)"; then
			say_bare "  node    $_v"
		else
			_failed="$_failed $NODE_BIN"
		fi
	fi
	if want_wallet; then
		if _v="$("$BIN_DIR/$WALLET_BIN" --version 2>&1)"; then
			say_bare "  wallet  $_v"
		else
			_failed="$_failed $WALLET_BIN"
		fi
	fi
	if want_miner; then
		if _v="$("$BIN_DIR/$MINER_BIN" --version 2>&1)"; then
			say_bare "  miner   $_v"
		else
			_failed="$_failed $MINER_BIN"
		fi
	fi

	if [ -n "$_failed" ]; then
		err "installed but could not run:$_failed
    Run the binary directly to see the loader or library error."
	fi
}

next_steps() {
	say_bare ""
	say "installed to $BIN_DIR"

	if [ "${PATH_NEEDS_RELOAD:-0}" = "1" ]; then
		say_bare ""
		say_bare "Open a new shell, or load the change into this one:"
		say_bare "    . $INSTALL_META/env"
	fi
	if [ "${PATH_NEEDS_ACTION:-0}" = "1" ]; then
		say_bare ""
		say_bare "PATH was left alone as requested. Add this yourself:"
		say_bare "    export PATH=\"$BIN_DIR:\$PATH\""
	fi
	if [ "${RUSTUP_WAS_INSTALLED:-0}" = "1" ]; then
		say_bare ""
		say_bare "rustup was installed and is not yet on this shell's PATH:"
		say_bare "    . \"\$HOME/.cargo/env\""
	fi

	say_bare ""
	if want_node; then
		say_bare "Node:   epic server config     writes epic-server.toml in the current directory"
		say_bare "        epic server run        starts syncing mainnet"
		if [ "$FAST_SYNC_STATUS" = "ok" ]; then
			say_bare "        The snapshot is in ~/.epic/main/chain_data, which is where the node looks"
			say_bare "        by default. Running the node from a directory that has its own"
			say_bare "        epic-server.toml uses that config's db_root instead, and ignores it."
		elif [ "$FAST_SYNC_STATUS" = "failed" ]; then
			say_bare "        The snapshot could not be fetched, so the first run validates from"
			say_bare "        genesis and will take hours. That is normal and safe. Manual"
			say_bare "        bootstrap instructions were printed above."
		fi
	fi
	if want_wallet; then
		say_bare "Wallet: epic-wallet init       creates a wallet and prints a seed phrase."
		say_bare "                               Write the seed down offline. It is the only backup."
	fi
	if want_miner; then
		say_bare "Miner:  epic-miner             runs against a node's Stratum server on 3416."
		say_bare "                               Config: $MINER_HOME/epic-miner.toml"
	fi
	say_bare ""
	say_bare "Docs:      https://devdocs.epiccash.com"
	say_bare "Uninstall: sh $INSTALL_META/uninstall.sh"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

parse_args() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-c | --component)
			[ $# -ge 2 ] || err "--component needs a value"
			COMPONENT="$2"
			shift 2
			;;
		--component=*)
			COMPONENT="${1#*=}"
			shift
			;;
		-y | --yes)
			ASSUME_YES=1
			shift
			;;
		--install-deps)
			INSTALL_DEPS=1
			shift
			;;
		--check | --dry-run)
			CHECK_ONLY=1
			shift
			;;
		--with-tor)
			WITH_TOR=1
			shift
			;;
		--miner-features)
			[ $# -ge 2 ] || err "--miner-features needs a value"
			MINER_FEATURES="$2"
			shift 2
			;;
		--miner-features=*)
			MINER_FEATURES="${1#*=}"
			shift
			;;
		--bin-dir)
			[ $# -ge 2 ] || err "--bin-dir needs a value"
			BIN_DIR="$2"
			shift 2
			;;
		--bin-dir=*)
			BIN_DIR="${1#*=}"
			shift
			;;
		--src-dir)
			[ $# -ge 2 ] || err "--src-dir needs a value"
			SRC_DIR="$2"
			shift 2
			;;
		--src-dir=*)
			SRC_DIR="${1#*=}"
			shift
			;;
		-j | --jobs)
			[ $# -ge 2 ] || err "--jobs needs a value"
			JOBS="$2"
			shift 2
			;;
		--jobs=*)
			JOBS="${1#*=}"
			shift
			;;
		--no-modify-path)
			NO_MODIFY_PATH=1
			shift
			;;
		--no-patch-cmake)
			NO_PATCH_CMAKE=1
			shift
			;;
		--fast-sync)
			FAST_SYNC=1
			shift
			;;
		--bootstrap-url)
			[ $# -ge 2 ] || err "--bootstrap-url needs a value"
			BOOTSTRAP_URL="$2"
			shift 2
			;;
		--bootstrap-url=*)
			BOOTSTRAP_URL="${1#*=}"
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		-V | --version)
			say_bare "epic-install $INSTALLER_VERSION"
			exit 0
			;;
		*)
			err "unknown option '$1'. Run with --help."
			;;
		esac
	done
}

validate_component() {
	case "$COMPONENT" in
	node | wallet | miner | node_wallet | all) ;;
	node-wallet | nodewallet)
		COMPONENT="node_wallet"
		;;
	*)
		err "unknown component '$COMPONENT'. Choose node, wallet, miner, node_wallet or all."
		;;
	esac

	# The snapshot is the node's chain database, so it is meaningless without the node.
	if [ "$FAST_SYNC" = "1" ] && ! want_node; then
		err "--fast-sync downloads the node's chain data, but '$COMPONENT' does not include the node.
    Use --component node or --component node_wallet."
	fi
}

# ---------------------------------------------------------------------------
# Dependency reporting
# ---------------------------------------------------------------------------

report_and_install_deps() {
	check_build_deps

	if [ -z "$MISSING_TOOLS" ] && [ -z "$MISSING_LIBS" ]; then
		say "build dependencies: all present"
		return 0
	fi

	say_bare ""
	say "missing build dependencies:"
	[ -n "$MISSING_TOOLS" ] && say_bare "  tools:    $(echo "$MISSING_TOOLS" | sed 's/^ //')"
	[ -n "$MISSING_LIBS" ] && say_bare "  libraries:$MISSING_LIBS"
	say_bare ""

	_pkgs="$(pkg_list)"

	if [ -z "$PKG_MGR" ] || [ -z "$_pkgs" ]; then
		if [ "$PLATFORM" = "macos" ]; then
			err "no Homebrew found, so the missing libraries cannot be named as packages.
    Install Homebrew from https://brew.sh and rerun, or install cmake, pkg-config, ncurses,
    zlib and openssl@3 by hand."
		fi
		err "could not identify this system's package manager, so the packages cannot be named.
    Install the equivalents of: a C toolchain, cmake, git, pkg-config, libclang, and the
    development headers for ncurses, zlib and openssl. Then rerun."
	fi

	say_bare "Install them with:"
	say_bare "    $PKG_INSTALL_CMD $_pkgs"
	say_bare ""

	if [ "$INSTALL_DEPS" != "1" ]; then
		err "stopping, because installing system packages needs your say-so.
    Run the command above yourself, or rerun this installer with --install-deps."
	fi

	if [ "$PKG_MGR" != "brew" ]; then
		say "--install-deps was passed, so this will run with sudo and may ask for your password."
	fi
	if ! confirm "Run: $PKG_INSTALL_CMD $_pkgs ?"; then
		err "declined. Install the packages above and rerun."
	fi

	# Refresh the apt index first, or install fails on a stale one.
	if [ "$PKG_MGR" = "apt" ]; then
		ensure sudo apt-get update
	fi

	# shellcheck disable=SC2086
	# Both are intentionally word-split into separate arguments.
	ensure $PKG_INSTALL_CMD $_pkgs

	check_build_deps
	if [ -n "$MISSING_TOOLS" ] || [ -n "$MISSING_LIBS" ]; then
		err "still missing after installing packages:$MISSING_TOOLS$MISSING_LIBS
    The package names for this distribution may differ. Install them by hand and rerun."
	fi
	say "build dependencies installed"
}

# ---------------------------------------------------------------------------
# Summary shown before anything is written
# ---------------------------------------------------------------------------

show_plan() {
	_what=""
	want_node && _what="$_what node"
	want_wallet && _what="$_what wallet"
	want_miner && _what="$_what miner($MINER_FEATURES)"

	say_bare ""
	say_bare "Epic Cash source installer $INSTALLER_VERSION"
	say_bare ""
	say_bare "  platform    $PLATFORM $ARCH"
	say_bare "  building    $(echo "$_what" | sed 's/^ //')"
	want_node && say_bare "  node        $NODE_REPO at $NODE_REF"
	want_wallet && say_bare "  wallet      $WALLET_REPO at $WALLET_REF"
	want_miner && say_bare "  miner       $MINER_REPO at $(printf '%.7s' "$MINER_REF")"
	want_miner && say_bare "              a fork, because upstream does not compile on a current toolchain."
	want_miner && say_bare "              upstream is $MINER_UPSTREAM"
	[ "$WITH_TOR" = "1" ] && say_bare "  features    with-tor"
	say_bare "  sources     $SRC_DIR"
	say_bare "  binaries    $BIN_DIR"
	want_miner && say_bare "  miner data  $MINER_HOME"
	if [ "$FAST_SYNC" = "1" ]; then
		say_bare "  fast sync   $BOOTSTRAP_URL"
		say_bare "              unpacked into $HOME/.epic/main/chain_data after the build"
	fi
	say_bare ""
	say_bare "  Compiling from source takes 10 to 30 minutes per component. No prebuilt binary is"
	say_bare "  downloaded. sudo is never used unless you passed --install-deps."
	say_bare ""
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

main() {
	# Defaults, then environment, then flags. Flags win because they are the most explicit.
	COMPONENT="${EPIC_COMPONENT:-node_wallet}"
	ASSUME_YES="${EPIC_YES:-0}"
	INSTALL_DEPS="${EPIC_INSTALL_DEPS:-0}"
	CHECK_ONLY="${EPIC_CHECK_ONLY:-0}"
	WITH_TOR="${EPIC_WITH_TOR:-0}"
	MINER_FEATURES="${EPIC_MINER_FEATURES:-cpu}"
	BIN_DIR="${EPIC_BIN_DIR:-$HOME/.local/bin}"
	SRC_DIR="${EPIC_SRC_DIR:-$HOME/.epic/src}"
	JOBS="${EPIC_JOBS:-}"
	NO_MODIFY_PATH="${EPIC_NO_MODIFY_PATH:-0}"
	NO_PATCH_CMAKE="${EPIC_NO_PATCH_CMAKE:-0}"
	FAST_SYNC="${EPIC_FAST_SYNC:-0}"
	BOOTSTRAP_URL="${EPIC_BOOTSTRAP_URL:-$BOOTSTRAP_URL_DEFAULT}"
	FAST_SYNC_STATUS="not requested"
	CHAIN_BACKUP=""
	CMAKE_NEEDS_PATCH=0

	PATH_NEEDS_RELOAD=0
	PATH_NEEDS_ACTION=0
	RUSTUP_WAS_INSTALLED=0

	parse_args "$@"
	validate_component

	[ -n "${HOME:-}" ] || err "HOME is not set, so there is nowhere to install to"

	MINER_HOME="$HOME/.epic/miner"
	INSTALL_META="$HOME/.epic/install"
	JOBS_ARG=""
	[ -n "$JOBS" ] && JOBS_ARG="-j $JOBS"

	detect_platform
	detect_pkg_mgr
	setup_macos_env

	# Needed by the preflight probes, so it is created before them rather than after consent.
	WORK_TMP="$(mktemp -d "${TMPDIR:-/tmp}/epic-install.XXXXXX")" ||
		err "could not create a temporary directory"

	show_plan

	# Preflight before any prompt, so a doomed run fails in seconds rather than after consent.
	report_and_install_deps
	want_miner && check_cmake_empty_target
	check_disk

	if [ "$CHECK_ONLY" = "1" ]; then
		say_bare ""
		say "check complete. Nothing was changed. Drop --check to install."
		rm -rf "$WORK_TMP" 2>/dev/null || true
		return 0
	fi

	if ! confirm "Build and install the above?"; then
		say "cancelled, nothing was changed"
		rm -rf "$WORK_TMP" 2>/dev/null || true
		return 0
	fi

	ensure_rust

	ensure mkdir -p "$SRC_DIR" "$BIN_DIR" "$INSTALL_META"

	RECEIPT="$INSTALL_META/receipt.txt"
	# Not truncated: the receipt accumulates across runs so the uninstaller knows about
	# components installed earlier.
	[ -f "$RECEIPT" ] || : >"$RECEIPT"

	want_node && build_node
	want_wallet && build_wallet
	want_miner && build_miner

	want_node && install_binary "$SRC_DIR/$NODE_DIR/target/release/$NODE_BIN" "$NODE_BIN"
	want_wallet && install_binary "$SRC_DIR/$WALLET_DIR/target/release/$WALLET_BIN" "$WALLET_BIN"
	want_miner && install_miner

	setup_path
	write_uninstaller
	verify_install

	# After verification, so a failed build or a broken binary is reported before committing to
	# a multi-gigabyte download.
	if [ "$FAST_SYNC" = "1" ]; then
		fast_sync
	fi

	next_steps

	rm -rf "$WORK_TMP" 2>/dev/null || true
	return 0
}

# The script is one function, invoked here. If the download is cut short, this line never
# arrives and nothing runs, which is the point.
main "$@" || exit 1
