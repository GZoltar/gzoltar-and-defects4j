#!/usr/bin/env bash

PWD=`pwd`

export MALLOC_ARENA_MAX=1 # Iceberg's requirement
export TZ='America/Los_Angeles' # some D4J's requires this specific TimeZone

export _JAVA_OPTIONS="-Xmx2048M -XX:MaxHeapSize=1024M"
export MAVEN_OPTS="-Xmx1024M"
export ANT_OPTS="-Xmx2048M -XX:MaxHeapSize=1024M"

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
  rm -rf "$output_dir"
  mkdir -p "$output_dir"
  "$D4J_HOME/framework/bin/defects4j" checkout -p "$pid" -v "${bid}$version" -w "$output_dir" || return 1

  echo "$output_dir"
  return 0
}

##
#
##
_fault_localization() {
  local USAGE="Usage: _fault_localization <pid> <bid> <tmp_dir>"
  if [ "$#" != 3 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local pid="$1"
  local bid="$2"
  local tmp_dir="$3"

  "$D4J_HOME/framework/bin/defects4j" fault-localization \
      -w "$tmp_dir" \
      -y sfl \
      -e ochiai \
      -g line || return 1

  local spectra_file="$tmp_dir/sfl/txt/spectra.csv"
  local matrix_file="$tmp_dir/sfl/txt/matrix.txt"
  local tests_file="$tmp_dir/sfl/txt/tests.csv"
  local source_code_lines_file="$tmp_dir/source_code_lines.txt"

  if [ ! -s "$spectra_file" ]; then
    echo "Spectra file '$spectra_file' is empty or does not exist" >&2
    return 1
  fi

  if [ ! -s "$matrix_file" ]; then
    echo "Matrix file '$matrix_file' is empty or does not exist" >&2
    return 1
  fi

  if [ ! -s "$tests_file" ]; then
    echo "Tests file '$tests_file' is empty or does not exist" >&2
    return 1
  fi

  if [ ! -f "$source_code_lines_file" ]; then
    echo "Source code line  file '$source_code_lines_file' does not exist" >&2
    return 1
  fi

#  # Remove extension
#  mv "$spectra_file" $(dirname "$spectra_file")/$(basename "$spectra_file" .csv) || return 1
#  spectra_file=$(dirname "$spectra_file")/$(basename "$spectra_file" .csv)
#  mv "$matrix_file" $(dirname "$matrix_file")/$(basename "$matrix_file" .txt) || return 1
#  matrix_file=$(dirname "$matrix_file")/$(basename "$matrix_file" .txt)
#  mv "$tests_file" $(dirname "$tests_file")/$(basename "$tests_file" .csv) || return 1
#  tests_file=$(dirname "$tests_file")/$(basename "$tests_file" .csv)

  # Remove header
  tail -n +2 "$spectra_file" > "$spectra_file.tmp" && mv -f "$spectra_file.tmp" "$spectra_file" || return 1
  tail -n +2 "$tests_file" > "$tests_file.tmp" && mv -f "$tests_file.tmp" "$tests_file" || return 1

  # Backup
  cp "$spectra_file" $(dirname "$spectra_file")/.spectra || return 1

  # Remove inner class(es) names (as there is not a .java file for each one)
  sed -i -E 's/(\$\w+)\$.*#/\1#/g' "$spectra_file" || return 1

  # Remove method name of each row in the spectra file
  sed -i 's/#.*:/#/g' "$spectra_file" || return 1

  # Replace class name symbol
  sed -i 's/\$/./g' "$spectra_file" || return 1

  # Replace / by .
  sed -i 's/\//./g' "$source_code_lines_file" || return 1
  # Remove .java extension
  sed -i 's/.java#/#/g' "$source_code_lines_file" || return 1

  return 0
}

##
# Checks whether a sanity check on the coverage of each triggering test case of
# a project-bug can or cannot be performed. A sanity check on a project-bug can
# only be performed if and only if a buggy line / candidate line could be
# identified in bytecode.
##
_is_a_known_exception() {
  local USAGE="Usage: _is_a_known_exception <pid> <bid>"
  if [ "$#" != 2 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local pid="$1"
  local bid="$2"

  if [ "$pid" == "Closure" ] && [ "$bid" == "67" ]; then
    # there is not a bytecode instruction for the buggy line
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "100" ]; then
    # there are two different ways of triggering this bug: either covering the
    # return statement (i.e., line number 146) or the lines annotated as a
    # 'fault of omission'. If a test case does not execute the return statement
    # it is impossible to cover any line annotated as a 'fault of omission'
    # because there is not a bytecode instruction for any of the candidates
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "103" ]; then
    # triggering test cases:
    #   com.google.javascript.jscomp.ControlFlowAnalysisTest::testInstanceOf
    #   com.google.javascript.jscomp.CheckUnreachableCodeTest::testInstanceOfThrowsException
    # do not cover faulty class 'com.google.javascript.jscomp.DisambiguateProperties'
    # and therefore its faulty code, and they do not cover any of the candidate
    # lines of a missing 'case' of class 'com/google/javascript/jscomp/ControlFlowAnalysis'
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "114" ]; then
    # there is not a bytecode instruction for the buggy line
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "119" ]; then
    # there is not a bytecode instruction for the candidate lines
    return 0
  fi

  if [ "$pid" == "Lang" ] && [ "$bid" == "29" ]; then
    # there is not a bytecode instruction for the buggy line
    return 0
  fi

  if [ "$pid" == "Lang" ] && [ "$bid" == "56" ]; then
    # there is not a bytecode instruction for the buggy lines
    return 0
  fi

  if [ "$pid" == "Math" ] && [ "$bid" == "12" ]; then
    # there is not a bytecode instruction for the buggy line or the two lines
    # annotated as a 'fault of omission'
    return 0
  fi

  if [ "$pid" == "Math" ] && [ "$bid" == "104" ]; then
    # there is not a bytecode instruction for the buggy line
    return 0
  fi

  if [ "$pid" == "Mockito" ] && [ "$bid" == "5" ]; then
    # the test case fails before any line could be cover/executed
    return 0
  fi

  if [ "$pid" == "Mockito" ] && [ "$bid" == "8" ]; then
    # there is not a bytecode instruction for the buggy line
    return 0
  fi

  if [ "$pid" == "Time" ] && [ "$bid" == "21" ]; then
    # the coverage of the second triggering test case (i.e.,
    # org.joda.time.TestDateTimeZone::testGetShortName_berlin) gets mixed due to
    # the execution of the other test cases in the same test class. this
    # behaviour has been double checked with the JaCoCo coverage tool and
    # therefore can be excluded
    return 0
  fi

  return 1
}

# EOF

