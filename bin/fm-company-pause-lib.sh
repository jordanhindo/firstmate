# shellcheck shell=bash
# shellcheck disable=SC2034 # FM_COMPANY_* results are read by sourcing callers.
# fm-company-pause-lib.sh - the ONE runtime-shell consumer of company pause mode.
#
# Company pause mode semantics live in the company's existing records and
# company-runtime CLI, while runtime shell only CONSUMES the public mode reader.
# This library is that single consumer.
# It never stores a mode, never parses companyState, never invents a default, and
# never writes. Named call sites (bin/fm-spawn.sh, bin/fm-session-start.sh,
# bin/fm-startup-network.sh, bin/fm-supervision-lib.sh) all come through here so a
# paused company is read the same way everywhere.
#
# Configuration resolution order:
#   1. explicit LATENT_SEA_COMPANY_STATE + LATENT_SEA_COMPANY_ROOT
#   2. otherwise <config-dir>/company-web.json stateRoot/companyRoot, where
#      <config-dir> is $FM_CONFIG_DIR when set, else $FM_HOME/config
#   3. neither source = non-company, and every caller keeps its old behavior
# A partial or unreadable source is an error, never silently non-company.
#
# Pinned reader bridge:
#   node <companyRoot>/bin/company-runtime.mjs company-state --admission true
#   env LATENT_SEA_COMPANY_STATE=<absolute records root>
#       LATENT_SEA_COMPANY_ROOT=<absolute code root>, FM_HOME=<current home>
# Exit 0 = running, exit 3 = paused, anything else = malformed/unreadable and
# therefore blocked with a diagnostic. The resolved roots are scoped to the child
# command only; they are never exported into this shell. The reader does not write.
#
# Shellcheck note: this file is sourced, so it does not set shell options.
# Sourcing it twice is harmless: it only defines functions.

# fm_company_config_resolve [<home>]
# Populates:
#   FM_COMPANY_KIND    none | configured | error
#   FM_COMPANY_ROOT    absolute company code root (configured only)
#   FM_COMPANY_STATE   absolute records root (configured only)
#   FM_COMPANY_ERROR   one-line diagnostic when the configuration is refused
# Reads <config-dir>/company-web.json, where <config-dir> is FM_CONFIG_DIR when
# set and otherwise <home>/config.
# Returns 0 configured, 1 non-company, 2 partial/bad configuration.
fm_company_config_resolve() {
  local home=${1:-${FM_HOME:-}} cfg_dir cfg parsed state_root company_root
  FM_COMPANY_KIND=none
  FM_COMPANY_ROOT=
  FM_COMPANY_STATE=
  FM_COMPANY_ERROR=

  if [ -n "${LATENT_SEA_COMPANY_STATE:-}" ] || [ -n "${LATENT_SEA_COMPANY_ROOT:-}" ]; then
    if [ -z "${LATENT_SEA_COMPANY_STATE:-}" ] || [ -z "${LATENT_SEA_COMPANY_ROOT:-}" ]; then
      FM_COMPANY_KIND=error
      FM_COMPANY_ERROR="company configuration is partial: LATENT_SEA_COMPANY_STATE and LATENT_SEA_COMPANY_ROOT must be set together"
      return 2
    fi
    state_root=$LATENT_SEA_COMPANY_STATE
    company_root=$LATENT_SEA_COMPANY_ROOT
  else
    cfg_dir=${FM_CONFIG_DIR:-$home/config}
    cfg="$cfg_dir/company-web.json"
    if [ ! -e "$cfg" ] || [ -L "$cfg" ]; then
      return 1
    fi
    parsed=$(node -e 'const fs=require("node:fs");let c;try{c=JSON.parse(fs.readFileSync(process.argv[1],"utf8"))}catch(e){process.exit(2)}if(!c||typeof c!=="object"||Array.isArray(c))process.exit(2);process.stdout.write(String(c.stateRoot===undefined?"":c.stateRoot)+"\n"+String(c.companyRoot===undefined?"":c.companyRoot))' "$cfg" 2>/dev/null) || {
      FM_COMPANY_KIND=error
      FM_COMPANY_ERROR="company configuration $cfg is not readable valid JSON with stateRoot and companyRoot"
      return 2
    }
    state_root=${parsed%%$'\n'*}
    company_root=${parsed#*$'\n'}
    if [ -z "$state_root" ] || [ -z "$company_root" ]; then
      FM_COMPANY_KIND=error
      FM_COMPANY_ERROR="company configuration $cfg must set both stateRoot and companyRoot"
      return 2
    fi
  fi

  case "$state_root" in
    /*) ;;
    *)
      FM_COMPANY_KIND=error
      FM_COMPANY_ERROR="company records root must be an absolute path: $state_root"
      return 2
      ;;
  esac
  case "$company_root" in
    /*) ;;
    *)
      FM_COMPANY_KIND=error
      FM_COMPANY_ERROR="company code root must be an absolute path: $company_root"
      return 2
      ;;
  esac

  FM_COMPANY_KIND=configured
  FM_COMPANY_STATE=$state_root
  FM_COMPANY_ROOT=$company_root
  return 0
}

# fm_company_admission [<home>]
# Asks the company-owned reader whether work is admitted.
# Populates FM_COMPANY_MODE = none | running | paused | error and, on error,
# FM_COMPANY_ERROR with a diagnostic.
# Returns 0 admitted (non-company or running), 3 intentionally paused, 1 blocked
# malformed/unreadable configuration or reader state.
fm_company_admission() {
  local home=${1:-${FM_HOME:-}} rc=0 out
  FM_COMPANY_MODE=none

  fm_company_config_resolve "$home" || rc=$?
  case "$rc" in
    0) ;;
    1) return 0 ;; # non-company: unchanged behavior
    2) FM_COMPANY_MODE=error; return 1 ;;
  esac

  out=$(LATENT_SEA_COMPANY_STATE="$FM_COMPANY_STATE" LATENT_SEA_COMPANY_ROOT="$FM_COMPANY_ROOT" \
    FM_HOME="$home" \
    node "$FM_COMPANY_ROOT/bin/company-runtime.mjs" company-state --admission true 2>&1) || rc=$?
  case "$rc" in
    0)
      FM_COMPANY_MODE=running
      return 0
      ;;
    3)
      FM_COMPANY_MODE=paused
      return 3
      ;;
    *)
      FM_COMPANY_MODE=error
      out=$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-200)
      FM_COMPANY_ERROR="company mode reader failed (exit $rc): ${out:-no diagnostic}"
      return 1
      ;;
  esac
}

# fm_company_paused [<home>]
# Exit 0 only when the company is intentionally paused.
fm_company_paused() {
  local rc=0
  fm_company_admission "$@" || rc=$?
  [ "$rc" -eq 3 ]
}
