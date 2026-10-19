#!/usr/bin/env bash
# codmod.sh - drop-in replacement for the native codmod binary on macOS (Apple silicon).
# Runs the linux/amd64 codmod image (see Dockerfile / build.sh) with Apple's `container` CLI.
#
# Install on PATH as `codmod` (works from scripts and Gemini CLI MCP config, unlike an alias):
#   ln -sf ~/Develop/codmod-mac/codmod.sh /usr/local/bin/codmod
#
# ---------------------------------------------------------------------------------------------
# MOUNT MODES
#
#   Least privilege (default) - the container only sees what the command needs, at the SAME
#   absolute paths as on the Mac:
#     read-only : paths given to -c/--codebase, --from-report, --from, --context-file,
#                 --supporting-documents, --from-template, and any other existing path argument
#     read-write: the folder of the -o/--output-path file (created if missing)
#     read-write: ${XDG_CONFIG_HOME:-~/.config}/codmod          (codmod config.yaml + logs)
#     read-only : gcloud ADC only - application_default_credentials.json, active_config,
#                 configurations/ (NOT credentials.db / access_tokens.db), or the file in
#                 $GOOGLE_APPLICATION_CREDENTIALS
#
#   Home mode - CODMOD_MOUNT_HOME=1 codmod ...
#     $HOME is mounted read-write at the same path (what a native binary could touch),
#     plus the paths above for anything outside $HOME.
#
# OUTPUT FOLDER
#   codmod itself requires -o. Point it anywhere; that folder (and only that folder) is
#   mounted read-write:
#     codmod create full -c . -o ~/codmod-reports/my-app.html -p PROJECT -r REGION
#   Or set a default output folder (env var, or edit the line below). When -o is omitted for
#   create/revise/convert, the wrapper adds
#     -o $CODMOD_OUTPUT_DIR/<codebase-name>-<command>-<timestamp>.<format>
#
# OTHER SETTINGS (env vars)
#   CODMOD_EXTRA_RO=/a:/b       extra paths to mount read-only  (':'-separated)
#   CODMOD_EXTRA_RW=/c          extra paths to mount read-write (':'-separated)
#   CODMOD_IMAGE=codmod:0.9.1   use another image tag (default codmod:latest)
#   CODMOD_WRAPPER_DEBUG=1      print the mount plan and container command
#   CODMOD_ENTRYPOINT=sh        run another program in the same sandbox (debugging)
#
# codmod mcpserver (Gemini CLI): paths arrive at runtime, so the wrapper mounts the current
# directory read-only plus CODMOD_OUTPUT_DIR read-write (or the current directory read-write if
# that is unset). For MCP across arbitrary projects use CODMOD_MOUNT_HOME=1.
# ---------------------------------------------------------------------------------------------
set -euo pipefail

# ===== User settings ==========================================================================
CODMOD_OUTPUT_DIR="${CODMOD_OUTPUT_DIR:-}"  # e.g. "$HOME/codmod-reports"; empty = native behaviour
CODMOD_MOUNT_HOME="${CODMOD_MOUNT_HOME:-0}" # 1 = mount all of $HOME read-write
# ==============================================================================================

IMAGE="${CODMOD_IMAGE:-codmod:latest}"
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
GCLOUD_DIR="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}"

log() { [ -n "${CODMOD_WRAPPER_DEBUG:-}" ] && echo "codmod.sh: $*" >&2 || true; }

# under PATH ROOT -> true if PATH equals ROOT or is inside it
under() { case "$1/" in "$2"/*) return 0 ;; *) return 1 ;; esac; }

# ----- mount table: DST (path inside container == path on Mac), SRC (physical host path), MODE
DST=() SRC=() MODE=()

# add_mount PATH ro|rw  - PATH must exist (file or directory)
add_mount() {
  local p="$1" mode="$2" L P i n
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  [ -e "$p" ] || return 0
  if [ -d "$p" ]; then
    L="$(cd "$p" && pwd -L)"
  else
    L="$(cd "$(dirname "$p")" && pwd -L)/$(basename "$p")"
  fi
  P="$(realpath "$p")"
  # Never shadow system directories of the container (or expose whole top-level trees).
  case "$L" in
    / | /bin | /sbin | /usr | /etc | /lib | /lib64 | /var | /dev | /proc | /sys | /root | /run | \
      /home | /opt | /private | /Users | /Volumes | /System | /Library | /Applications) return 0 ;;
    /proc/* | /sys/* | /dev/* | /etc/* | /usr/* | /bin/* | /sbin/* | /lib/* | /run/*) return 0 ;;
  esac
  n=${#DST[@]}
  for ((i = 0; i < n; i++)); do
    if under "$L" "${DST[$i]}" && under "$P" "${SRC[$i]}"; then
      # Already visible with the same or stronger access.
      if [ "${MODE[$i]}" = rw ] || [ "$mode" = ro ]; then return 0; fi
    elif under "$L" "${DST[$i]}"; then
      # Symlink inside a mounted tree pointing elsewhere: mount the target at its own path.
      L="$P"
    fi
  done
  DST+=("$L") SRC+=("$P") MODE+=("$mode")
}

# add_output FILE - mount the folder that will receive the output file read-write
add_output() {
  local d
  d="$(dirname "$1")"
  case "$d" in /*) ;; *) d="$PWD/$d" ;; esac
  mkdir -p "$d"
  add_mount "$d" rw
}

add_list() { # add_list "a:b:c" ro|rw
  local IFS=: x
  for x in $1; do [ -n "$x" ] && add_mount "$x" "$2"; done
  return 0
}

# ----- parse codmod arguments -------------------------------------------------------------
# Home mode: mount $HOME first, so everything inside it is covered read-write.
[ "$CODMOD_MOUNT_HOME" = 1 ] && add_mount "$HOME" rw

CMD1="" CMD2=""
[ $# -ge 1 ] && case "$1" in -*) ;; *) CMD1="$1" ;; esac
[ -n "$CMD1" ] && [ $# -ge 2 ] && case "$2" in -*) ;; *) CMD2="$2" ;; esac

OUT_GIVEN=0 NEEDS_NO_OUT=0 FORMAT=html FIRST_CODEBASE="" next=""
for a in "$@"; do
  if [ -n "$next" ]; then
    case "$next" in
      out) OUT_GIVEN=1; add_output "$a" ;;
      cb) add_mount "$a" ro; [ -z "$FIRST_CODEBASE" ] && FIRST_CODEBASE="$a" ;;
      in) add_mount "$a" ro ;;
      fmt) FORMAT="$a" ;;
    esac
    next=""; continue
  fi
  case "$a" in
    -o | --output-path) next=out ;;
    --output-path=*) OUT_GIVEN=1; add_output "${a#*=}" ;;
    -o?*) OUT_GIVEN=1; v="${a#-o}"; add_output "${v#=}" ;;
    -c | --codebase) next=cb ;;
    --codebase=* | -c?*)
      case "$a" in --codebase=*) v="${a#*=}" ;; *) v="${a#-c}"; v="${v#=}" ;; esac
      add_mount "$v" ro; [ -z "$FIRST_CODEBASE" ] && FIRST_CODEBASE="$v" ;;
    --from-report | --from | --context-file | --supporting-documents | --from-template) next=in ;;
    --from-report=* | --from=* | --context-file=* | --supporting-documents=* | --from-template=*)
      add_mount "${a#*=}" ro ;;
    --format) next=fmt ;;
    --format=*) FORMAT="${a#*=}" ;;
    --estimate-cost | -h | --help) NEEDS_NO_OUT=1 ;;
    */* | . | ..) add_mount "$a" ro ;; # any other existing path argument
  esac
done

# ----- default output folder ----------------------------------------------------------------
EXTRA_ARGS=()
case "$CMD1" in create | revise | convert)
  if [ "$OUT_GIVEN" = 0 ] && [ "$NEEDS_NO_OUT" = 0 ] && [ -n "$CODMOD_OUTPUT_DIR" ]; then
    case "$FORMAT" in markdown) ext=md ;; *) ext="$FORMAT" ;; esac
    name="$(basename "$(cd "${FIRST_CODEBASE:-.}" 2>/dev/null && pwd || echo report)")"
    out="$CODMOD_OUTPUT_DIR/${name}-${CMD1}${CMD2:+-$CMD2}-$(date +%Y%m%d-%H%M%S).${ext}"
    add_output "$out"
    EXTRA_ARGS=(-o "$out")
    echo "codmod.sh: no -o given, writing report to $out" >&2
  fi ;;
esac

# ----- always-needed mounts ------------------------------------------------------------------
mkdir -p "$CONFIG_HOME/codmod"
add_mount "$CONFIG_HOME/codmod" rw
for f in application_default_credentials.json active_config configurations; do
  add_mount "$GCLOUD_DIR/$f" ro
done
[ -n "${GOOGLE_APPLICATION_CREDENTIALS:-}" ] && add_mount "$GOOGLE_APPLICATION_CREDENTIALS" ro

if [ "$CMD1" = mcpserver ]; then
  if [ -n "$CODMOD_OUTPUT_DIR" ]; then
    mkdir -p "$CODMOD_OUTPUT_DIR"; add_mount "$CODMOD_OUTPUT_DIR" rw; add_mount "$PWD" ro
  else
    add_mount "$PWD" rw
  fi
fi

add_list "${CODMOD_EXTRA_RW:-}" rw
add_list "${CODMOD_EXTRA_RO:-}" ro

# ----- container command -----------------------------------------------------------------------
# Timezone of the Mac, so logs/report timestamps match the host.
TZ_VALUE="${TZ:-}"
if [ -z "$TZ_VALUE" ]; then
  TZ_VALUE="$(readlink /etc/localtime 2>/dev/null || true)"
  TZ_VALUE="${TZ_VALUE#*zoneinfo/}"
fi

ARGS=(run --rm --progress none --platform linux/amd64 -w "$PWD"
  -e "HOME=$HOME" -e "USER=${USER:-$(id -un)}" -e "TMPDIR=/var/tmp")
[ -n "$TZ_VALUE" ] && ARGS+=(-e "TZ=$TZ_VALUE")

for name in $(compgen -e); do
  case "$name" in
    GOOGLE_* | CLOUDSDK_* | GCE_* | XDG_CONFIG_HOME | \
      HTTP_PROXY | HTTPS_PROXY | NO_PROXY | http_proxy | https_proxy | no_proxy | \
      TERM | COLORTERM | NO_COLOR | LANG | LC_ALL)
      ARGS+=(-e "$name=${!name}") ;;
  esac
done

# Parents before children (nested rw-inside-ro mounts).
for i in $(for ((j = 0; j < ${#DST[@]}; j++)); do echo "${#DST[$j]} $j"; done | sort -n | cut -d' ' -f2); do
  if [ "${MODE[$i]}" = ro ]; then
    ARGS+=(-v "${SRC[$i]}:${DST[$i]}:ro")
  else
    ARGS+=(-v "${SRC[$i]}:${DST[$i]}")
  fi
  log "mount ${MODE[$i]} ${DST[$i]}"
done

# Interactive TTY when used from a terminal; plain stdin otherwise (pipes, MCP stdio).
if [ -t 0 ] && [ -t 1 ]; then ARGS+=(-it); else ARGS+=(-i); fi

[ -n "${CODMOD_ENTRYPOINT:-}" ] && ARGS+=(--entrypoint "$CODMOD_ENTRYPOINT")

ARGS+=("$IMAGE" "$@" ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"})

if [ -n "${CODMOD_WRAPPER_DEBUG:-}" ]; then
  printf 'container' >&2; printf ' %q' "${ARGS[@]}" >&2; printf '\n' >&2
fi

exec container "${ARGS[@]}"
