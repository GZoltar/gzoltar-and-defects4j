#!/bin/bash

export TZ='America/Los_Angeles' # some D4J bugs requires this specific TimeZone

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

##
# Prints error message to the stdout and exit.
##
die() {
  echo "$@" >&2
  exit 1
}

##
# Checkouts a D4J's project-bug.
##
_checkout() {
  local USAGE="Usage: _checkout <pid> <bid> <fixed (f) or buggy (b)>"
  if [ "$#" != 3 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local pid="$1"
  local bid="$2"
  local version="$3" # either b or f

  local output_dir="/tmp/$USER/gz-d4j/_$$-$pid-$bid"
  rm -rf "$output_dir"; mkdir -p "$output_dir"

  "$D4J_HOME/framework/bin/defects4j" checkout -p "$pid" -v "${bid}$version" -w "$output_dir" || return 1

  echo "$output_dir"
  return 0
}

##
# Compiles a D4J's project-bug.
##
_compile() {
  local USAGE="Usage: _compile <project dir>"
  if [ "$#" != 1 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local project_dir="$1"

  if [[ $project_dir == *"-Mockito-"* ]]; then
    rm -f "$project_dir/buildSrc/src/test/groovy/testutil/OfflineCheckerTest.groovy" # this test case may cause the compilation to fail

    echo "[DEBUG] Mockito project identified, export '$project_dir/.gradle-local-home' as the 'GRADLE_USER_HOME'" >&2
    export GRADLE_USER_HOME="$project_dir/.gradle-local-home"
  fi

  pushd . > /dev/null 2>&1
  cd "$project_dir"
    "$D4J_HOME/framework/bin/defects4j" compile || return 1
  popd > /dev/null 2>&1

  return 0
}

# EOF

