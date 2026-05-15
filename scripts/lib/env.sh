#!/usr/bin/env bash
set -euo pipefail

read_env_var() {
  local env_file="$1"
  local key="$2"
  local val
  val="$(
    awk -v k="$key" '
      $0 ~ "^[[:space:]]*"k"=" {
        sub("^[^=]*=", "");
        print;
        exit;
      }
    ' "$env_file"
  )"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  if [[ "$val" =~ ^\".*\"$ ]]; then
    val="${val:1:${#val}-2}"
  elif [[ "$val" =~ ^\'.*\'$ ]]; then
    val="${val:1:${#val}-2}"
  fi
  echo "$val"
}
