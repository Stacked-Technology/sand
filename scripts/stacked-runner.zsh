# Source this after the existing stacked-runner function to replace only its
# upgrade branch. The other start/stop/status/logs behavior stays in place.

if (( ! $+functions[stacked-runner-legacy] )); then
  if (( $+functions[stacked-runner] )); then
    functions[stacked-runner-legacy]="${functions[stacked-runner]}"
  fi
fi

stacked-runner() {
  emulate -L zsh
  local upgrade_script="${SAND_UPGRADE_SCRIPT:-$HOME/Github/sand/scripts/stacked-runner-upgrade.sh}"

  if [[ "${1:-status}" == upgrade ]]; then
    (( $# == 1 )) || {
      print -u2 'Usage: stacked-runner upgrade'
      return 2
    }
    bash "$upgrade_script"
    return $?
  fi

  if (( $+functions[stacked-runner-legacy] )); then
    stacked-runner-legacy "$@"
    return $?
  fi

  print -u2 'stacked-runner is not configured; source the existing runner function first.'
  return 1
}
