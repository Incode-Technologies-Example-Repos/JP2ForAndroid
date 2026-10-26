#!/bin/bash
# Reads a Maven repo credential. The value comes from the environment variable with the key name.
# If that variable is empty, the value comes from the same key in ~/.gradle/gradle.properties.
# Source this file, then call: read_credential <key>
read_credential() {
  local key="$1"
  local value="${!key}"
  if [ -z "$value" ] && [ -f "$HOME/.gradle/gradle.properties" ]; then
    value=$(grep "^$key=" "$HOME/.gradle/gradle.properties" | head -1 | cut -d'=' -f2-)
  fi
  echo "$value"
}

# Runs curl with the credentials in $user and $password.
# curl reads them from stdin, so they are not in the command line that ps shows.
auth_curl() {
  local credentials="$user:$password"
  credentials=${credentials//\\/\\\\}
  credentials=${credentials//\"/\\\"}
  printf 'user = "%s"\n' "$credentials" | curl --config - "$@"
}
