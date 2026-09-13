#!/bin/sh
# floonet.sh - one command to join the Epic Cash floonet test network as a mining node.
#
# Linux only, deliberately. The mining plugins and the RandomX light-mode path are only
# exercised on Linux x86-64, and a test network is not the place to debug three platforms.
#
# What this does that install.sh does not:
#
#   install.sh builds mainnet binaries. It has no notion of a chain type, and a mainnet
#   configuration on floonet is not merely suboptimal, it does not work. This script delegates
#   every build to install.sh - one source of truth for compiling - and then does the floonet
#   part, which is six configuration changes, each of which is load-bearing:
#
#     only_randomx = true                 without it your node rejects every block on the chain
#     chain_type = "Floonet"              the --floonet flag alone is not enough, see below
#     seeding_type / seeds                floonet's hardcoded DNS seed does not exist
#     peer_min_preferred_outbound_count = 1   1, not 0: 0 leaves the node stuck at height 0
#     enable_stratum_server = true        the miner needs something to talk to
#     burn_reward = true                  mine with no wallet at all
#
# No wallet is installed and none is needed. burn_reward = true makes the node mint each
# coinbase to a throwaway key it generates itself, so blocks are produced and validated with
# nothing to set up and nothing to lose. You are contributing hashrate and testing consensus,
# not accumulating anything. Add a wallet later if you want the coins.
#
# Read it before running it:
#   curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/floonet.sh | less
#
# See what it would do and change nothing:
#   curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/floonet.sh | sh -s -- --check
#
# MIT licensed. Not an official Epic Cash project.

set -u

# The entire body is a function, invoked on the last line. A download truncated halfway
# therefore does nothing at all rather than running the first half of an install.
main() {

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

INSTALLER_URL="${EPIC_INSTALLER_URL:-https://raw.githubusercontent.com/blacktyger/epic-script/main/install.sh}"

# The public seed for this network. Floonet's only hardcoded DNS seed,
# floonet.epiccash.com, has never existed - the Epic source itself carries the comment
# "does not exist yet" next to it - so seeding_type = "DNSSeed" finds nothing and a seed
# list is the only way onto the chain.
SEED_ADDR="${FLOONET_SEED:-floo-node.btlabs.uk:13414}"
EXPLORER_URL="${FLOONET_EXPLORER:-https://floo-explorer.btlabs.uk}"

# Floonet's own defaults from epic/config/src/config.rs. Left alone on purpose: they do not
# collide with mainnet's 3413/3414/3416, so a machine can run both.
API_PORT="${FLOONET_API_PORT:-13413}"
P2P_PORT="${FLOONET_P2P_PORT:-13414}"
STRATUM_PORT="${FLOONET_STRATUM_PORT:-13416}"

EPIC_DIR="${EPIC_DIR:-$HOME/.epic}"
FLOO_DIR="$EPIC_DIR/floo"
SRC_DIR="${EPIC_SRC_DIR:-$EPIC_DIR/src}"
BIN_DIR="${EPIC_BIN_DIR:-$HOME/.local/bin}"
MINER_HOME="${EPIC_MINER_HOME:-$EPIC_DIR/miner}"
LOG_DIR="$EPIC_DIR/install/logs"

THREADS="${FLOONET_THREADS:-}"
ASSUME_YES="${FLOONET_YES:-0}"
CHECK_ONLY="${FLOONET_CHECK:-0}"
INSTALL_DEPS="${FLOONET_INSTALL_DEPS:-0}"
WITH_SYSTEMD="${FLOONET_SYSTEMD:-0}"
SKIP_BUILD="${FLOONET_SKIP_BUILD:-0}"
NO_PATCH_MINER="${FLOONET_NO_PATCH_MINER:-0}"
JOBS="${FLOONET_JOBS:-}"

# RandomX light mode needs ~256 MB per thread. Add headroom for the node itself and the OS.
MB_PER_THREAD=300
NODE_RESERVE_MB=700

STEP=0
TOTAL=6

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
	C_RESET=$(printf '\033[0m'); C_DIM=$(printf '\033[2m')
	C_BOLD=$(printf '\033[1m'); C_RED=$(printf '\033[31m')
	C_GREEN=$(printf '\033[32m'); C_YELLOW=$(printf '\033[33m')
else
	C_RESET=''; C_DIM=''; C_BOLD=''; C_RED=''; C_GREEN=''; C_YELLOW=''
fi

step()   { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$C_BOLD" "$STEP" "$TOTAL" "$1" "$C_RESET"; }
say()    { printf '        %s\n' "$1"; }
ok()     { printf '        %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
detail() { printf '        %s%s%s\n' "$C_DIM" "$1" "$C_RESET"; }
warn()   { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$1" >&2; }
err()    { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$1" >&2; exit 1; }
ensure() { "$@" || err "command failed: $*"; }
have()   { command -v "$1" >/dev/null 2>&1; }

banner() {
	printf '%s' "$C_BOLD"
	cat <<'ART'
  ___ _                       _
 / __| |___  ___ _ _  ___| |_
 |  _| / _ \/ _ \ ' \/ -_)  _|
 |_| |_\___/\___/_||_\___|\__|
ART
	printf '%s' "$C_RESET"
	printf '%s  Epic Cash floonet - mining node installer (Linux)%s\n\n' "$C_DIM" "$C_RESET"
}

confirm() {
	# $1 question. Returns 0 for yes. Under --yes, or with no terminal, answers per ASSUME_YES.
	[ "$ASSUME_YES" = "1" ] && return 0
	if [ ! -t 0 ]; then
		# Piped with no tty: refuse rather than silently proceeding with something the user
		# has not seen. --yes is the way to say yes in advance.
		warn "no terminal to ask on: \"$1\""
		say  "re-run with --yes to answer yes in advance, or download the script and run it directly"
		return 1
	fi
	printf '        %s [y/N] ' "$1"
	read -r _ans </dev/tty || return 1
	case "$_ans" in y | Y | yes | YES) return 0 ;; *) return 1 ;; esac
}

usage() {
	cat <<'USAGE'
floonet.sh - install and configure an Epic Cash floonet mining node (Linux only)

  curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/floonet.sh | sh

Options                        Variable                   Meaning
  --check                      FLOONET_CHECK              preflight only, change nothing
  --yes                        FLOONET_YES                answer yes to everything up front
  --install-deps               FLOONET_INSTALL_DEPS       let the build install missing packages
  --threads <n>                FLOONET_THREADS            mining threads (default: from free RAM)
  --jobs <n>                   FLOONET_JOBS               parallel build jobs
  --systemd                    FLOONET_SYSTEMD            install systemd --user units
  --skip-build                 FLOONET_SKIP_BUILD         configure only, binaries already present
  --no-patch-miner             FLOONET_NO_PATCH_MINER     refuse the RandomX light-mode patch
  --seed <host:port>           FLOONET_SEED               seed node (default floo-node.btlabs.uk:13414)
  --bin-dir <path>             EPIC_BIN_DIR               default ~/.local/bin
  --src-dir <path>             EPIC_SRC_DIR               default ~/.epic/src
  -h, --help

Piping to sh has no terminal, so unattended runs need --yes:
  curl -fsSL https://raw.githubusercontent.com/blacktyger/epic-script/main/floonet.sh | sh -s -- --yes --install-deps

No wallet is installed. The node mines with burn_reward = true, which mints each coinbase to a
throwaway key, so there is nothing to configure and nothing to lose.
USAGE
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
	case "$1" in
	--check) CHECK_ONLY=1 ;;
	--yes | -y) ASSUME_YES=1 ;;
	--install-deps) INSTALL_DEPS=1 ;;
	--systemd) WITH_SYSTEMD=1 ;;
	--skip-build) SKIP_BUILD=1 ;;
	--no-patch-miner) NO_PATCH_MINER=1 ;;
	--threads) shift; [ $# -gt 0 ] || err "--threads needs a value"; THREADS="$1" ;;
	--jobs) shift; [ $# -gt 0 ] || err "--jobs needs a value"; JOBS="$1" ;;
	--seed) shift; [ $# -gt 0 ] || err "--seed needs a value"; SEED_ADDR="$1" ;;
	--bin-dir) shift; [ $# -gt 0 ] || err "--bin-dir needs a value"; BIN_DIR="$1" ;;
	--src-dir) shift; [ $# -gt 0 ] || err "--src-dir needs a value"; SRC_DIR="$1" ;;
	-h | --help) usage; exit 0 ;;
	*) err "unknown option: $1 (try --help)" ;;
	esac
	shift
done

banner

# ---------------------------------------------------------------------------
# A tiny, section-aware TOML editor
#
# This is the one piece of real logic in the script, and it needs to be section-aware rather
# than a global sed. `stratum_server_addr` exists in both [server.stratum_mining_config] in the
# node config and [mining] in the miner config; `seeds` and `threads` are similarly ambiguous.
# A global substitution would edit the wrong one, or all of them.
#
# Rules: operate only between the named section header and the next section header. Replace the
# key if present, including when it is commented out, and append it to the end of the section
# if it is absent entirely.
# ---------------------------------------------------------------------------

toml_set() {
	# toml_set <file> <section> <key> <value-verbatim>
	_f="$1"; _sec="$2"; _key="$3"; _val="$4"
	[ -f "$_f" ] || err "toml_set: no such file: $_f"

	awk -v section="$_sec" -v key="$_key" -v val="$_val" '
	# Blank lines at the end of a section are held back, so that an appended key lands against
	# the last real line of its section rather than after the gap before the next header.
	function release_blanks() {
		for (i = 1; i <= nblank; i++) print blanks[i]
		nblank = 0
	}
	function append_key() {
		if (in_target && !done) { print key " = " val; done = 1 }
	}
	BEGIN { in_target = 0; done = 0; seen_section = 0; nblank = 0 }
	{
		line = $0
		if (line ~ /^[[:space:]]*$/) { blanks[++nblank] = line; next }

		if (line ~ /^[[:space:]]*\[/) {
			append_key()          # we are leaving the target section
			release_blanks()
			hdr = line
			gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", hdr)
			gsub(/[[:space:]]/, "", hdr)
			in_target = (hdr == section)
			if (in_target) seen_section = 1
			print line
			next
		}

		release_blanks()
		if (in_target && !done) {
			# Match `key = ...`, `#key = ...` or `# key = ...`, so a commented-out default is
			# replaced rather than duplicated below it.
			if (line ~ ("^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=")) {
				print key " = " val
				done = 1
				next
			}
		}
		print line
	}
	END {
		append_key()
		release_blanks()
		# The section was not in the file at all: create it.
		if (!seen_section) {
			print ""
			print "[" section "]"
			print key " = " val
		}
	}
	' "$_f" >"$_f.tmp" || err "failed to edit $_f"
	ensure mv "$_f.tmp" "$_f"
}

toml_get() {
	# toml_get <file> <section> <key> - prints the raw value, empty if unset/commented.
	awk -v section="$2" -v key="$3" '
	BEGIN { in_target = 0 }
	/^[[:space:]]*\[/ {
		hdr = $0; gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", hdr); gsub(/[[:space:]]/, "", hdr)
		in_target = (hdr == section); next
	}
	in_target {
		pat = "^[[:space:]]*" key "[[:space:]]*="
		if ($0 ~ pat) { sub(pat, "", $0); gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0); print; exit }
	}
	' "$1"
}

# ---------------------------------------------------------------------------
# Seed resolution
#
# `seeds` in epic-server.toml deserialises to Vec<PeerAddr> where PeerAddr wraps a
# std::net::SocketAddr, and SocketAddr does not parse hostnames. A hostname there is not
# ignored or warned about - it is a hard failure that panics the node on startup:
#
#   TOML parse error at line N, column M
#   seeds = ["floo-node.btlabs.uk:13414"]
#            ^^^^^^^^^^^^^^^^^^^^^^^^^^^
#   invalid socket address syntax
#
# So the seed has to be resolved to IP:port before it is written. Every published guide that
# prints a hostname here produces a node that will not start.
# ---------------------------------------------------------------------------

resolve_seed() {
	# resolve_seed <host> - prints one IPv4 address, or nothing.
	_h="$1"
	# Already an IPv4 literal?
	case "$_h" in
	*[!0-9.]*) ;;
	*) printf '%s' "$_h"; return 0 ;;
	esac
	if have getent; then
		_ip=$(getent ahostsv4 "$_h" 2>/dev/null | awk '/STREAM|RAW|^[0-9]/ {print $1; exit}')
		[ -n "$_ip" ] || _ip=$(getent hosts "$_h" 2>/dev/null | awk '{print $1; exit}')
		[ -n "$_ip" ] && { printf '%s' "$_ip"; return 0; }
	fi
	if have dig; then
		_ip=$(dig +short A "$_h" 2>/dev/null | grep -E '^[0-9.]+$' | head -n 1)
		[ -n "$_ip" ] && { printf '%s' "$_ip"; return 0; }
	fi
	if have python3; then
		_ip=$(python3 -c "import socket,sys
try: print(socket.gethostbyname(sys.argv[1]))
except Exception: pass" "$_h" 2>/dev/null)
		[ -n "$_ip" ] && { printf '%s' "$_ip"; return 0; }
	fi
	return 1
}

# ---------------------------------------------------------------------------
# 1. Preflight
# ---------------------------------------------------------------------------

step "Preflight"

_os="$(uname -s 2>/dev/null || echo unknown)"
[ "$_os" = "Linux" ] || err "this script is Linux only; you are on $_os.
        The mining plugins and the RandomX light-mode path are only exercised on Linux x86-64.
        For a node and wallet on macOS or Windows use install.sh instead."
ok "Linux $(uname -m)"

for _c in curl git awk sed grep; do
	have "$_c" || err "missing required command: $_c"
done
ok "required tools present"

if [ "$(id -u)" = "0" ]; then
	warn "running as root. Binaries and chain data will land in /root."
	confirm "Continue as root?" || err "aborted"
fi

# Memory. RandomX light mode is ~256 MB per thread; the node wants a few hundred more. This is
# the check whose absence hurts most: the miner's upstream default is RandomX *fast* mode, which
# wants ~2 GB of dataset per epoch and pre-builds the next one too, so peak approaches 4 GB. On a
# small VPS that is an instant OOM, and the kernel picks the largest process, which may well be
# something you care about more than the miner.
_avail_mb=0
if [ -r /proc/meminfo ]; then
	_avail_mb=$(awk '/^MemAvailable:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0)
fi
[ -n "$_avail_mb" ] || _avail_mb=0
_swap_mb=0
if [ -r /proc/meminfo ]; then
	_swap_mb=$(awk '/^SwapTotal:/ {printf "%d", $2/1024; exit}' /proc/meminfo 2>/dev/null || echo 0)
fi
_nproc=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)

say "available memory: ${_avail_mb} MB, swap: ${_swap_mb} MB, cpus: ${_nproc}"

# Pick a thread count that fits, unless told otherwise.
if [ -z "$THREADS" ]; then
	_budget=$((_avail_mb - NODE_RESERVE_MB))
	_fit=$((_budget / MB_PER_THREAD))
	[ "$_fit" -lt 1 ] && _fit=1
	# Leave a core for the node and the OS on small machines.
	_cpu_cap=$((_nproc - 1))
	[ "$_cpu_cap" -lt 1 ] && _cpu_cap=1
	if [ "$_fit" -lt "$_cpu_cap" ]; then THREADS="$_fit"; else THREADS="$_cpu_cap"; fi
	detail "chose $THREADS mining thread(s): $_cpu_cap by cpu, $_fit by memory, lower wins"
else
	detail "using $THREADS mining thread(s) as requested"
fi

_need_mb=$((NODE_RESERVE_MB + THREADS * MB_PER_THREAD))
if [ "$_avail_mb" -lt "$_need_mb" ]; then
	warn "about ${_need_mb} MB wanted for the node plus ${THREADS} mining thread(s), but only ${_avail_mb} MB is available"
	if [ "$_swap_mb" = "0" ]; then
		say "there is no swap, so an overshoot means the OOM killer rather than slowness"
	fi
	confirm "Continue anyway?" || err "aborted. Try --threads 1, or free some memory."
fi

# A build needs headroom of its own, well beyond running.
if [ "$SKIP_BUILD" != "1" ] && [ "$_avail_mb" -lt 1200 ]; then
	warn "compiling needs roughly 1.5 GB; ${_avail_mb} MB available"
	say  "rustc will be the largest process on the box, and with ${_swap_mb} MB of swap it may be OOM-killed"
	say  "consider: --jobs 1, adding swap, or building elsewhere and using --skip-build"
	confirm "Continue anyway?" || err "aborted"
fi

_free_disk_mb=$(df -Pm "$HOME" 2>/dev/null | awk 'NR==2 {print $4}')
[ -n "$_free_disk_mb" ] || _free_disk_mb=0
say "free disk in \$HOME: ${_free_disk_mb} MB"
if [ "$SKIP_BUILD" != "1" ] && [ "$_free_disk_mb" -lt 4000 ]; then
	warn "a source build wants ~4 GB; ${_free_disk_mb} MB free"
	confirm "Continue anyway?" || err "aborted"
fi

# Is the seed reachable? Not fatal - it may be firewalled outbound, or temporarily down - but
# knowing now beats discovering it after a 20 minute compile.
_seed_host=$(printf '%s' "$SEED_ADDR" | sed 's/:[0-9]*$//')
_seed_port=$(printf '%s' "$SEED_ADDR" | sed 's/.*://')

# Resolve now, because the config needs a literal address and because failing here is far
# better than a node that panics on every start.
SEED_IP=$(resolve_seed "$_seed_host" || true)
if [ -n "$SEED_IP" ]; then
	SEED_SOCKADDR="$SEED_IP:$_seed_port"
	if [ "$SEED_IP" = "$_seed_host" ]; then
		ok "seed $SEED_SOCKADDR"
	else
		ok "seed $_seed_host resolves to $SEED_IP"
	fi
else
	err "cannot resolve $_seed_host.
        The node's seeds list takes IP:port only - a hostname makes it panic on startup - so
        this has to resolve before anything is written. Check DNS, or pass a literal address:
          --seed 1.2.3.4:$_seed_port"
fi

if have nc; then
	if nc -z -w 5 "$SEED_IP" "$_seed_port" >/dev/null 2>&1; then
		ok "seed $SEED_SOCKADDR accepts TCP"
	else
		warn "cannot reach $SEED_SOCKADDR. Check outbound firewall rules; the node will retry forever."
	fi
fi

# Port collisions. A mainnet node on 3413/3414 is fine - these are different ports - but a
# second floonet node is not.
for _p in "$API_PORT" "$P2P_PORT" "$STRATUM_PORT"; do
	if have ss && ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":${_p}\$"; then
		err "port $_p is already in use. Another floonet node? Stop it, or override with
        FLOONET_API_PORT / FLOONET_P2P_PORT / FLOONET_STRATUM_PORT."
	fi
done
ok "ports $API_PORT, $P2P_PORT, $STRATUM_PORT are free"

if [ -d "$FLOO_DIR/chain_data" ]; then
	say "existing floonet chain data at $FLOO_DIR/chain_data will be reused"
fi

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------

printf '\n%sPlan%s\n' "$C_BOLD" "$C_RESET"
say "build      node and miner via install.sh (skipped: $([ "$SKIP_BUILD" = 1 ] && echo yes || echo no))"
say "binaries   $BIN_DIR"
say "sources    $SRC_DIR"
say "chain data $FLOO_DIR"
say "miner      $MINER_HOME, RandomX light mode, $THREADS thread(s)"
say "seed       $SEED_SOCKADDR  ($_seed_host, resolved: the config takes IP:port only)"
say "wallet     none - burn_reward = true"
say "systemd    $([ "$WITH_SYSTEMD" = 1 ] && echo "--user units" || echo "no, run by hand")"

if [ "$CHECK_ONLY" = "1" ]; then
	printf '\n%s--check given: stopping without changing anything.%s\n' "$C_DIM" "$C_RESET"
	exit 0
fi

if ! confirm "Proceed?"; then
	err "aborted"
fi

ensure mkdir -p "$FLOO_DIR" "$SRC_DIR" "$BIN_DIR" "$MINER_HOME" "$LOG_DIR"

# ---------------------------------------------------------------------------
# 2. Build the node and the miner, via install.sh
# ---------------------------------------------------------------------------

step "Node and miner binaries"

EPIC_BIN="$BIN_DIR/epic"
MINER_BIN="$BIN_DIR/epic-miner"

if [ "$SKIP_BUILD" = "1" ]; then
	say "--skip-build: using whatever is already on PATH"
	have epic || err "--skip-build given but no 'epic' on PATH"
	have epic-miner || err "--skip-build given but no 'epic-miner' on PATH"
	EPIC_BIN="$(command -v epic)"
	MINER_BIN="$(command -v epic-miner)"
	ok "node $EPIC_BIN"
	ok "miner $MINER_BIN"
else
	# Delegate to install.sh rather than reimplementing dependency detection, Rust
	# bootstrapping, the CMake build-script patches and the miner's launcher. That script is
	# the single source of truth for building Epic from source; this one owns floonet.
	_installer="$LOG_DIR/../install.sh"
	if [ -f "./install.sh" ]; then
		_installer="./install.sh"
		say "using the local ./install.sh"
	else
		say "fetching install.sh"
		ensure curl -fsSL --proto '=https' --tlsv1.2 "$INSTALLER_URL" -o "$_installer"
		ensure chmod +x "$_installer"
	fi

	set -- --component all
	# 'all' would build the wallet too, which we do not want. install.sh has no
	# node-plus-miner component, so run it twice; the second run reuses the first's checkout,
	# Rust install and dependency checks, so the overhead is seconds.
	say "building the node (this is a real compile: 10-30 minutes)"
	_args="--component node"
	[ "$ASSUME_YES" = "1" ] && _args="$_args --yes"
	[ "$INSTALL_DEPS" = "1" ] && _args="$_args --install-deps"
	[ -n "$JOBS" ] && _args="$_args --jobs $JOBS"
	# shellcheck disable=SC2086
	EPIC_BIN_DIR="$BIN_DIR" EPIC_SRC_DIR="$SRC_DIR" sh "$_installer" $_args ||
		err "install.sh failed building the node"

	say "building the miner"
	_args="--component miner"
	[ "$ASSUME_YES" = "1" ] && _args="$_args --yes"
	[ "$INSTALL_DEPS" = "1" ] && _args="$_args --install-deps"
	[ -n "$JOBS" ] && _args="$_args --jobs $JOBS"
	# shellcheck disable=SC2086
	EPIC_BIN_DIR="$BIN_DIR" EPIC_SRC_DIR="$SRC_DIR" EPIC_MINER_HOME="$MINER_HOME" \
		sh "$_installer" $_args || err "install.sh failed building the miner"

	ok "node and miner installed"
fi

# Make sure this shell can see them for the verification step below.
PATH="$BIN_DIR:$PATH"
export PATH

# ---------------------------------------------------------------------------
# 3. RandomX light mode
#
# The single most important safety property of this script, and the reason it touches source.
#
# randomx-miner hardcodes RandomX fast mode: `rx_state.full_mem = true`, with no configuration
# path to turn it off. Fast mode allocates a ~2080 MB dataset per epoch and the miner
# pre-builds the next epoch as well, so peak usage approaches 4 GB. Worse, init_dataset() is
# called unconditionally, so even a config that asked for light mode would still allocate it.
#
# On a machine with several spare gigabytes that is simply fast. On a small VPS it is an
# out-of-memory kill, and the kernel chooses the largest resident process, which is not
# necessarily the miner. This exact failure killed a live mainnet node on the machine this
# script was developed on.
#
# So: probe for a `full_mem` option in the miner source. If the fork has grown one, do nothing.
# If not, show the change and ask before applying it. Same contract as install.sh's CMake
# patch, and it disappears on its own once the fix lands upstream.
# ---------------------------------------------------------------------------

step "RandomX light mode"

MINER_SRC="$SRC_DIR/epic-miner"
LIGHT_MODE_AVAILABLE=0

if [ ! -d "$MINER_SRC" ]; then
	warn "no miner source at $MINER_SRC, cannot check for light-mode support"
	say  "if the miner allocates gigabytes on start, that is why"
elif grep -q 'full_mem' "$MINER_SRC/core/src/config.rs" 2>/dev/null; then
	LIGHT_MODE_AVAILABLE=1
	ok "the miner already supports full_mem; nothing to patch"
elif [ "$NO_PATCH_MINER" = "1" ]; then
	warn "--no-patch-miner given, and this miner build has no light-mode option"
	say  "it will run RandomX fast mode: ~2 GB per epoch, up to ~4 GB peak"
	confirm "Continue with fast mode?" || err "aborted"
else
	say "this miner hardcodes RandomX fast mode (~2 GB/epoch, ~4 GB peak) with no way to opt out."
	say "the patch adds a full_mem option and honours it, defaulting to light mode (~256 MB/thread):"
	printf '\n'
	detail "core/src/config.rs        + pub full_mem: bool   (in RxConfig, default false)"
	detail "randomx-miner/src/miner.rs  - rx_state.full_mem = true"
	detail "                            + rx_state.full_mem = config.full_mem"
	detail "                            + skip init_dataset() entirely when full_mem is false,"
	detail "                              because create_vm() already builds a cache-only VM"
	printf '\n'

	if confirm "Apply the light-mode patch and rebuild the miner?"; then
		_cfg="$MINER_SRC/core/src/config.rs"
		_min="$MINER_SRC/randomx-miner/src/miner.rs"
		[ -f "$_cfg" ] || err "expected $_cfg"
		[ -f "$_min" ] || err "expected $_min"

		# 3a. Add the config field to RxConfig, immediately after large_pages.
		if ! grep -q 'full_mem' "$_cfg"; then
			awk '
			/pub large_pages: bool,/ {
				print
				print "\t/// RandomX fast mode (RANDOMX_FLAG_FULL_MEM): a ~2080 MB dataset per epoch for"
				print "\t/// roughly an order of magnitude more hashrate. Light mode (false) uses ~256 MB"
				print "\t/// per VM instead. Defaults to false so the safe option is the default; the miner"
				print "\t/// also pre-builds the next epoch, putting fast-mode peak near 4 GB."
				print "\t#[serde(default)]"
				print "\tpub full_mem: bool,"
				next
			}
			{ print }
			' "$_cfg" >"$_cfg.tmp" && mv "$_cfg.tmp" "$_cfg" || err "failed to patch $_cfg"

			# RxConfig has a manual Default impl; keep it consistent or the struct will not build.
			if grep -q 'large_pages: false,' "$_cfg"; then
				sed 's/large_pages: false,/large_pages: false,\n\t\t\tfull_mem: false,/' \
					"$_cfg" >"$_cfg.tmp" && mv "$_cfg.tmp" "$_cfg"
			fi
			ok "patched core/src/config.rs"
		fi

		# 3b. Honour it, and skip the dataset allocation in light mode. Both halves are needed:
		# without the second, init_dataset() still allocates the full dataset and "light mode"
		# saves nothing at all.
		if grep -q 'rx_state.full_mem = true;' "$_min"; then
			sed 's/rx_state\.full_mem = true;/rx_state.full_mem = config.full_mem;/' \
				"$_min" >"$_min.tmp" && mv "$_min.tmp" "$_min" || err "failed to patch $_min"
			ok "patched randomx-miner/src/miner.rs (full_mem now from config)"
		fi
		if grep -q 'if let Err(e) = rx.init_dataset(threads as u8) {' "$_min" &&
			! grep -q 'if rx.full_mem {' "$_min"; then
			awk '
			/if let Err\(e\) = rx\.init_dataset\(threads as u8\) \{/ && !done {
				match($0, /^[[:space:]]*/)
				ind = substr($0, 1, RLENGTH)
				print ind "if rx.full_mem {"
				print ind "\t" "if let Err(e) = rx.init_dataset(threads as u8) {"
				getline; print "\t" $0            # error!(...)
				getline; print "\t" $0            # result = ...
				getline; print "\t" $0            # }
				print ind "} else {"
				print ind "\t" "// Light mode: create_vm() builds a cache-only VM when dataset is None."
				print ind "}"
				done = 1
				next
			}
			{ print }
			' "$_min" >"$_min.tmp" && mv "$_min.tmp" "$_min" || err "failed to patch $_min"
			ok "patched randomx-miner/src/miner.rs (dataset skipped in light mode)"
		fi

		if grep -q 'full_mem' "$_cfg"; then
			say "rebuilding the miner with the patch"
			_build_log="$LOG_DIR/floonet-miner-rebuild.log"
			_jobs_arg=""
			[ -n "$JOBS" ] && _jobs_arg="-j $JOBS"
			# shellcheck disable=SC2086
			if (cd "$MINER_SRC" && cargo build --release $_jobs_arg) >"$_build_log" 2>&1; then
				ok "miner rebuilt"
				_built="$MINER_SRC/target/release/epic-miner"
				if [ -f "$_built" ] && [ -f "$MINER_HOME/epic-miner" ]; then
					ensure install -m 755 "$_built" "$MINER_HOME/epic-miner"
					ok "reinstalled $MINER_HOME/epic-miner"
				fi
				LIGHT_MODE_AVAILABLE=1
			else
				warn "the rebuild failed; see $_build_log"
				tail -n 20 "$_build_log" >&2
				say "continuing with the unpatched binary, which means fast mode"
				confirm "Continue?" || err "aborted"
			fi
		fi

		say "note: this leaves uncommitted changes in $MINER_SRC."
		detail "a later 'install.sh --component miner' will stop rather than discard them;"
		detail "pass --force-checkout to that script if you want them gone."
	else
		warn "declined. The miner will use RandomX fast mode: ~2 GB per epoch, ~4 GB peak."
		confirm "Continue with fast mode?" || err "aborted"
	fi
fi

# ---------------------------------------------------------------------------
# 4. Node configuration
# ---------------------------------------------------------------------------

step "Floonet node configuration"

SERVER_TOML="$FLOO_DIR/epic-server.toml"

if [ -f "$SERVER_TOML" ]; then
	_backup="$SERVER_TOML.bak.$(date +%Y%m%d%H%M%S)"
	ensure cp "$SERVER_TOML" "$_backup"
	say "kept a copy of the existing config at $(basename "$_backup")"
else
	# Let the node write its own config, then change only what floonet needs. Generating and
	# patching keeps the diff small and auditable, and inherits upstream defaults for the
	# dozens of keys we have no opinion about, instead of pinning them forever.
	say "generating a fresh floonet config"
	(cd "$FLOO_DIR" && "$EPIC_BIN" --floonet server config >/dev/null 2>&1) ||
		err "'epic --floonet server config' failed"
	[ -f "$SERVER_TOML" ] || err "expected $SERVER_TOML to exist after generating it"
	ok "wrote $SERVER_TOML"
fi

# --- The six changes that matter -------------------------------------------

# 1. chain_type, explicitly. A config file's chain_type overrides the --floonet flag, and it
#    defaults to Mainnet under serde when absent. Get this wrong and a "floonet" node quietly
#    uses mainnet rules and the mainnet data directory.
toml_set "$SERVER_TOML" "server" "chain_type" '"Floonet"'

# 2. only_randomx. THE critical one. This network runs a 100% RandomX block policy, and there
#    is no flag in a block header announcing that: every node and miner has to be configured
#    identically or they reject each other's blocks with InvalidSortAlgo. A default-policy node
#    will sync nothing from us and will happily mine a fork of one.
#    The --onlyrandomx command-line flag is parsed and then discarded, so it must be set here.
toml_set "$SERVER_TOML" "server" "only_randomx" "true"

# 3. Seeds. floonet.epiccash.com, the only hardcoded floonet DNS seed, does not exist, so
#    seeding_type = "DNSSeed" resolves nothing. Entries must be host:port; a bare hostname is
#    dropped silently, and the example in the generated config uses mainnet ports.
toml_set "$SERVER_TOML" "server.p2p_config" "seeding_type" '"List"'
toml_set "$SERVER_TOML" "server.p2p_config" "seeds" "[\"$SEED_SOCKADDR\"]"
toml_set "$SERVER_TOML" "server.p2p_config" "port" "$P2P_PORT"

# 4. peer_min_preferred_outbound_count. Non-obvious, absolutely required, and 1 rather than 0.
#    The sync loop begins each iteration by checking whether it has at least this many OUTBOUND
#    peers; below that it sets AwaitingPeers and `continue`s. The default is 4. A small test
#    network has one seed, so a joining node reaches exactly 1 outbound peer, never satisfies the
#    check, and stays in "awaiting_peers" forever - never reaching the branch that sets NoSync.
#    The stratum server then never serves work and the whole thing looks broken for no reason.
#
#    0 looks like the safe answer and is worse. With 0 the guard passes immediately, so the node
#    reaches NoSync *before any peer connects*. From NoSync, needs_syncing() takes its other
#    branch and only re-enables sync when
#
#        peer_difficulty > local_difficulty + sum(last 5 block difficulties)
#
#    Floonet's genesis seeds ProgPow at 2^26 = 67108864, and a RandomX-only chain never
#    meaningfully increments it - at height 203 the seed offers ProgPow 67109067, i.e. 203 above
#    genesis - while the threshold is roughly twice the genesis value. That margin is never
#    reached. The node handshakes, holds a healthy connection, logs that the seed has more work,
#    and sits at height 0 forever. Worse here than on a plain node: burn_reward = true means it
#    also mines, so it builds its own chain from genesis instead of following the network.
#
#    1 keeps the node in its startup AwaitingPeers state until the first peer connects, so
#    needs_syncing() takes the is_syncing branch, sees the seed ahead, and syncs normally.
#    Measured against the public seed: 0 -> stuck at height 0; 1 -> synced genesis to tip.
toml_set "$SERVER_TOML" "server.p2p_config" "peer_min_preferred_outbound_count" "1"

# 5/6. Stratum, and mining with no wallet.
#    burn_reward = true makes the node pass None as the wallet listener URL, which routes
#    coinbase creation to burn_reward(): a throwaway ExtKeychain generated on the spot. Blocks
#    are produced and fully valid; the reward is simply unspendable by anyone. Without it the
#    node blocks block production entirely while it fails to reach a wallet, retrying every 5s.
toml_set "$SERVER_TOML" "server.stratum_mining_config" "enable_stratum_server" "true"
toml_set "$SERVER_TOML" "server.stratum_mining_config" "stratum_server_addr" "\"127.0.0.1:$STRATUM_PORT\""
toml_set "$SERVER_TOML" "server.stratum_mining_config" "burn_reward" "true"

toml_set "$SERVER_TOML" "server" "api_http_addr" "\"127.0.0.1:$API_PORT\""

# The foundation levy pays a second coinbase output every 1440 blocks, and the node verifies
# the SHA-256 of a chain-specific foundation file to build it. The file ships in the node source
# we just cloned. Point at a copy under the user's own data directory: no sudo, and it cannot be
# broken by a system package update.
_found_src="$SRC_DIR/epic/debian/foundation_floonet.json"
if [ -f "$_found_src" ]; then
	ensure cp "$_found_src" "$FLOO_DIR/foundation_floonet.json"
	toml_set "$SERVER_TOML" "server" "foundation_path" "\"$FLOO_DIR/foundation_floonet.json\""
	ok "installed foundation_floonet.json"
elif [ -f /usr/share/epic/foundation_floonet.json ]; then
	toml_set "$SERVER_TOML" "server" "foundation_path" '"/usr/share/epic/foundation_floonet.json"'
	ok "using the system foundation_floonet.json"
else
	warn "no foundation_floonet.json found. Blocks are fine until height 1440, which is the
        first foundation-levy height; it will fail there. Find it at debian/foundation_floonet.json
        in the epic source and set foundation_path."
fi

ok "configured $SERVER_TOML"
detail "chain_type          $(toml_get "$SERVER_TOML" server chain_type)"
detail "only_randomx        $(toml_get "$SERVER_TOML" server only_randomx)"
detail "seeds               $(toml_get "$SERVER_TOML" server.p2p_config seeds)"
detail "min outbound peers  $(toml_get "$SERVER_TOML" server.p2p_config peer_min_preferred_outbound_count)"
detail "stratum             $(toml_get "$SERVER_TOML" server.stratum_mining_config stratum_server_addr)"
detail "burn_reward         $(toml_get "$SERVER_TOML" server.stratum_mining_config burn_reward)"

# ---------------------------------------------------------------------------
# 5. Miner configuration
# ---------------------------------------------------------------------------

step "Miner configuration"

MINER_TOML="$MINER_HOME/epic-miner.toml"

if [ ! -f "$MINER_TOML" ]; then
	if [ -f "$SRC_DIR/epic-miner/epic-miner.toml" ]; then
		ensure cp "$SRC_DIR/epic-miner/epic-miner.toml" "$MINER_TOML"
	else
		err "no epic-miner.toml to start from at $MINER_TOML"
	fi
else
	_backup="$MINER_TOML.bak.$(date +%Y%m%d%H%M%S)"
	ensure cp "$MINER_TOML" "$_backup"
	say "kept a copy of the existing miner config at $(basename "$_backup")"
fi

# The node dictates the algorithm from its block policy and ignores whatever the miner asks
# for in getjobtemplate - but the miner still has to construct the right solver locally, so
# this must say RandomX or it builds a Cuckoo solver and submits shares the node counts as
# accepted while they never become blocks. Rising accepted shares with a static height is
# exactly that symptom.
toml_set "$MINER_TOML" "mining" "algorithm" '"RandomX"'
toml_set "$MINER_TOML" "mining" "stratum_server_addr" "\"127.0.0.1:$STRATUM_PORT\""
toml_set "$MINER_TOML" "mining" "stratum_server_tls_enabled" "false"
toml_set "$MINER_TOML" "mining" "run_tui" "false"
toml_set "$MINER_TOML" "mining.randomx_config" "threads" "$THREADS"
toml_set "$MINER_TOML" "mining.randomx_config" "jit" "true"
toml_set "$MINER_TOML" "mining.randomx_config" "hard_aes" "true"
# large_pages needs privileges to be worth anything and fails noisily without them.
toml_set "$MINER_TOML" "mining.randomx_config" "large_pages" "false"

if [ "$LIGHT_MODE_AVAILABLE" = "1" ]; then
	toml_set "$MINER_TOML" "mining.randomx_config" "full_mem" "false"
	ok "RandomX light mode, $THREADS thread(s), about $((THREADS * 256)) MB"
else
	warn "no light-mode support in this build: expect ~2 GB per epoch and up to ~4 GB peak"
fi

if [ -d "$MINER_HOME/plugins" ]; then
	toml_set "$MINER_TOML" "mining" "miner_plugin_dir" "\"$MINER_HOME/plugins\""
fi

# The miner logs to a relative path by default, which lands wherever it was started from.
toml_set "$MINER_TOML" "logging" "log_file_path" "\"$MINER_HOME/epic-miner.log\""

ok "configured $MINER_TOML"

# ---------------------------------------------------------------------------
# 6. Verify, and optional systemd units
# ---------------------------------------------------------------------------

step "Verify"

# Start the node briefly and confirm it comes up as floonet with the right policy, rather than
# declaring success because a file was written. This is the check that catches a config the node
# silently disagrees with.
_verify_log="$LOG_DIR/floonet-verify.log"
say "starting the node to check the configuration"
(cd "$FLOO_DIR" && "$EPIC_BIN" --floonet server run >"$_verify_log" 2>&1) &
_node_pid=$!

_ok_policy=0
_ok_api=0
_i=0
while [ "$_i" -lt 40 ]; do
	sleep 1
	_i=$((_i + 1))
	kill -0 "$_node_pid" 2>/dev/null || break
	grep -q '100% RandomX' "$_verify_log" 2>/dev/null && _ok_policy=1
	if [ "$_ok_policy" = "1" ] && curl -fsS --max-time 2 -o /dev/null \
		"http://127.0.0.1:$API_PORT/v1/status" 2>/dev/null; then
		_ok_api=1
		break
	fi
	# /v1/* needs the api secret; a 401 still proves the listener is up.
	if [ "$_ok_policy" = "1" ] && [ "$_i" -gt 8 ]; then
		_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 \
			"http://127.0.0.1:$API_PORT/v1/status" 2>/dev/null || echo 000)
		case "$_code" in 200 | 401) _ok_api=1; break ;; esac
	fi
done

# Did it actually leave height 0? Polled while the node is still running.
#
# Everything else above can pass on a node that never syncs a single block. A wrong
# peer_min_preferred_outbound_count produces exactly that: correct policy, working API,
# stratum up, seed dialled - and a chain that stays at genesis forever. This is the check
# that catches it, so do not remove it.
_ok_sync=0
_height=""
_secret_file="$FLOO_DIR/.api_secret"
if [ -r "$_secret_file" ]; then
	_i=0
	while [ "$_i" -lt 25 ]; do
		_i=$((_i + 1))
		kill -0 "$_node_pid" 2>/dev/null || break
		_status=$(curl -fsS --max-time 3 -u "epic:$(cat "$_secret_file")" \
			"http://127.0.0.1:$API_PORT/v1/status" 2>/dev/null || true)
		if [ -n "$_status" ]; then
			# no jq dependency: pull the first "height":N out of the response
			_height=$(printf '%s' "$_status" | tr ',{}' '\n\n\n' \
				| sed -n 's/.*"height"[[:space:]]*:[[:space:]]*\([0-9]\{1,\}\).*/\1/p' | head -n 1)
			case "$_height" in
			'' | 0) : ;;
			*)
				_ok_sync=1
				break
				;;
			esac
		fi
		sleep 1
	done
fi

if kill -0 "$_node_pid" 2>/dev/null; then
	kill -TERM "$_node_pid" 2>/dev/null
	wait "$_node_pid" 2>/dev/null
fi

if [ "$_ok_policy" = "1" ]; then
	ok "the node reports a 100% RandomX block policy"
else
	# This is a hard failure, not a warning. A config the node will not load, or loads without
	# the RandomX policy, produces a node that either does not start or silently rejects every
	# block on the chain. Reporting "Done" here would be worse than useless.
	printf '\n'
	warn "the node did not come up with a 100% RandomX block policy"
	say "last lines of $_verify_log:"
	tail -n 15 "$_verify_log" >&2
	printf '\n'
	err "configuration did not verify. Nothing is running; fix the above and re-run.
        The config is at $SERVER_TOML and a backup of any previous one is beside it."
fi
[ "$_ok_api" = "1" ] && ok "the API answered on 127.0.0.1:$API_PORT"

if grep -q 'Starting stratum server' "$_verify_log" 2>/dev/null; then
	ok "the stratum server started, so the miner has something to connect to"
else
	warn "no stratum server in the log. Check enable_stratum_server in $SERVER_TOML."
fi

if grep -q "Connecting to seed and preferred peers address: $SEED_SOCKADDR" "$_verify_log" 2>/dev/null; then
	ok "the node dialled the seed at $SEED_SOCKADDR"
fi

if [ "$_ok_sync" = "1" ]; then
	ok "the node synced past genesis (height $_height), so it is following the network"
elif [ -r "$_secret_file" ]; then
	printf '\n'
	warn "the node started cleanly but is still at height 0 - it is not following the chain"
	say "Everything else verified, so this is almost certainly connectivity or the sync
        threshold rather than your build:
          * can this host reach $SEED_SOCKADDR outbound on TCP?
          * is peer_min_preferred_outbound_count = 1 in $SERVER_TOML?
            0 is the classic mistake here - the node then reaches no_sync before any
            peer connects and can never re-enter sync on this chain.
          * is the network itself producing blocks? check $EXPLORER_URL"
	say "the node is not left running; re-run once the above is sorted"
fi

if [ "$WITH_SYSTEMD" = "1" ]; then
	if ! have systemctl; then
		warn "--systemd given but systemctl is not present; skipping"
	else
		_unit_dir="$HOME/.config/systemd/user"
		ensure mkdir -p "$_unit_dir"

		# --user units, not system units: no sudo, and nothing here needs privileges or should
		# outlive the user's session by default.
		cat >"$_unit_dir/epic-floonet-node.service" <<UNIT
[Unit]
Description=Epic Cash floonet node
After=network-online.target

[Service]
Type=simple
WorkingDirectory=$FLOO_DIR
ExecStart=$EPIC_BIN --floonet server run
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
UNIT

		# The miner is memory-capped even in light mode. An unconstrained RandomX miner is the
		# most likely cause of an out-of-memory event on a small machine, and a cgroup limit
		# means the miner dies inside its own accounting instead of the kernel picking a victim.
		_mem_max=$((512 + THREADS * 400))
		cat >"$_unit_dir/epic-floonet-miner.service" <<UNIT
[Unit]
Description=Epic Cash floonet RandomX miner ($THREADS thread(s), light mode)
After=epic-floonet-node.service
Wants=epic-floonet-node.service

[Service]
Type=simple
WorkingDirectory=$MINER_HOME
ExecStart=$MINER_BIN
Restart=on-failure
RestartSec=15

# Keep the miner from being the reason something else dies. It loses to everything.
Nice=15
MemoryMax=${_mem_max}M
MemorySwapMax=0
OOMScoreAdjust=1000

[Install]
WantedBy=default.target
UNIT

		ensure systemctl --user daemon-reload
		ok "wrote systemd --user units to $_unit_dir"
		detail "systemctl --user enable --now epic-floonet-node epic-floonet-miner"
		detail "loginctl enable-linger $(id -un)   # to survive logout"
	fi
fi

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

printf '\n%sDone.%s The floonet node and miner are installed and configured.\n' "$C_GREEN$C_BOLD" "$C_RESET"

case ":$PATH:" in
*":$BIN_DIR:"*) ;;
*) printf '\n%s%s is not on your PATH. Add it, or start a new shell.%s\n' "$C_YELLOW" "$BIN_DIR" "$C_RESET" ;;
esac

cat <<NEXT

Start it, in two terminals:

  ${C_BOLD}epic --floonet server run${C_RESET}
      from ${FLOO_DIR}, or anywhere without an epic-server.toml in it

  ${C_BOLD}epic-miner${C_RESET}
      once the node logs "Starting stratum server"

What to expect

  The node prints "Block policy: 100% RandomX". If it does not, stop: the config did not
  take, and this node will reject every block on the chain.

  sync_status goes awaiting_peers -> no_sync within a few seconds of reaching the seed.
  It stays no_sync while running; that is the healthy state, not an error.

  Blocks arrive roughly every 8 seconds below height 200 and much more slowly after that.
  That is expected: floonet hardcodes difficulty to 1 below height 200 and starts real
  retargeting at 200, with a RandomX floor of 4000 - a 4000x step in a single block.

  Your rewards are burned. burn_reward = true mints each coinbase to a throwaway key. You
  are testing consensus and adding hashrate, not earning. Install a wallet later if you
  want the coins.

Check your work against the network

  ${EXPLORER_URL}
      live explorer: height, your blocks, peers, and the network parameters page

  curl -s ${EXPLORER_URL}/api/summary
      the same data as JSON

Files

  ${SERVER_TOML}
  ${MINER_TOML}
  ${LOG_DIR}/

If the node sits at awaiting_peers forever, it cannot reach ${SEED_ADDR}. Check outbound
firewall rules on port ${_seed_port}.

If accepted shares climb but the height does not move, the miner is solving the wrong
algorithm. Confirm algorithm = "RandomX" in ${MINER_TOML}.
NEXT

}

main "$@"
