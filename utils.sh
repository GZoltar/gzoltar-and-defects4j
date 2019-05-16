#!/usr/bin/env bash

PWD=$(cd `dirname ${BASH_SOURCE[0]}` && pwd)

export TZ='America/Los_Angeles' # some D4J's requires this specific TimeZone

export _JAVA_OPTIONS="-Xmx4096M -XX:MaxHeapSize=2048M"
export MAVEN_OPTS="-Xmx1024M"
export ANT_OPTS="-Xmx4096M -XX:MaxHeapSize=2048M"

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# Speed up grep command
alias grep="LANG=C grep"

#
# Prints error message to the stdout and exit.
#
die() {
  echo "$@" >&2
  exit 1
}

#
# Checkouts a D4J's project-bug.
#
_checkout() {
  local USAGE="Usage: ${FUNCNAME[0]} <pid> <bid> <fixed (f) or buggy (b)> <output_dir>"
  if [ "$#" != 4 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local pid="$1"
  local bid="$2"
  local version="$3" # either b or f
  local output_dir="$4"

  "$D4J_HOME/framework/bin/defects4j" checkout -p "$pid" -v "${bid}$version" -w "$output_dir" || return 1

  if [ "$pid" == "Time" ]; then
    if [ "$bid" -eq "18" ] || [ "$bid" -eq "22" ] || [ "$bid" -eq "24" ] || [ "$bid" -eq "27" ]; then
      # For Time-{18, 22, 24, and 27}, test case 'org.joda.time.TestPeriodType::testForFields4'
      # only fails when executed in isolation, i.e., it does not fail when it is
      # executed in the same JVM as other test cases from the same test class
      # but it does fail if executed in a single JVM. As it does not cover any
      # buggy code, it is safe to conclude it is a dependent test case and could
      # be excluded. Ideally, it should be discarded by the D4J checkout command,
      # however, as the same test class, including test case 'testForFields4',
      # is also executed by other Time bugs we took a conservative approach and
      # only discard it for bugs Time-{18, 22, 24, and 27}.
      pushd . > /dev/null 2>&1
      cd "$output_dir"
        echo "--- org.joda.time.TestPeriodType::testForFields4" > extra.dependent_tests
        "$D4J_HOME/framework/util/rm_broken_tests.pl" extra.dependent_tests $("$D4J_HOME/framework/bin/defects4j" export -p dir.src.tests) || return 1
      popd > /dev/null 2>&1
    fi
  fi

  return 0
}

#
# Runs GZoltar fault localization tool on a specific D4J's project-bug.
#
_run_gzoltar() {
  local USAGE="Usage: ${FUNCNAME[0]} <pid> <bid> <tmp_dir>"
  if [ "$#" != 3 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  [ "$D4J_HOME" != "" ] || die "[ERROR] D4J_HOME is not set!"
  [ -d "$D4J_HOME" ] || die "[ERROR] $D4J_HOME does not exist!"

  local pid="$1"
  local bid="$2"
  local tmp_dir="$3"

  echo "[INFO] Start: $(date)" >&2
  "$D4J_HOME/framework/bin/defects4j" fault-localization \
        -w "$tmp_dir" \
        -y sfl \
        -e ochiai \
        -g line || return 1
  echo "[INFO] End: $(date)" >&2

  local ser_file="$tmp_dir/gzoltar.ser"
  local spectra_file="$tmp_dir/sfl/txt/spectra.csv"
  local matrix_file="$tmp_dir/sfl/txt/matrix.txt"
  local tests_file="$tmp_dir/sfl/txt/tests.csv"
  local source_code_lines_file="$tmp_dir/source_code_lines.txt"

  [ -s "$ser_file" ] || die "[ERROR] $ser_file does not exist or it is empty!"
  [ -s "$spectra_file" ] || die "[ERROR] $spectra_file does not exist or it is empty!"
  [ -s "$matrix_file" ] || die "[ERROR] $matrix_file does not exist or it is empty!"
  [ -s "$tests_file" ] || die "[ERROR] $tests_file does not exist or it is empty!"
  [ -s "$source_code_lines_file" ] || die "[ERROR] $source_code_lines_file does not exist or it is empty!"

  mv "$spectra_file" "$tmp_dir/" || return 1
  spectra_file="$tmp_dir/spectra.csv"

  mv "$matrix_file" "$tmp_dir/" || return 1
  matrix_file="$tmp_dir/matrix.txt"

  mv "$tests_file" "$tmp_dir/" || return 1
  tests_file="$tmp_dir/tests.csv"

  # Remove header
  tail -n +2 "$spectra_file" > "$spectra_file.tmp" && mv -f "$spectra_file.tmp" "$spectra_file" || return 1
  tail -n +2 "$tests_file" > "$tests_file.tmp" && mv -f "$tests_file.tmp" "$tests_file" || return 1

  # Fix format
  # Replace / by .
  sed -i 's/\//./g' "$source_code_lines_file" || return 1
  # Remove .java extension
  sed -i 's/.java#/#/g' "$source_code_lines_file" || return 1

  # Backup original spectra file
  cp "$spectra_file" $(dirname "$spectra_file")/.spectra || return 1

  # Remove inner class(es) names (as there is not a .java file for each one)
  sed -i -E 's/(\$\w+)\$.*#/\1#/g' "$spectra_file" || return 1

  # Remove method name of each row in the spectra file
  sed -i 's/#.*:/#/g' "$spectra_file" || return 1

  # Replace class name symbol
  sed -i 's/\$/./g' "$spectra_file" || return 1

  return 0
}

#
# Checks whether a sanity check on the coverage of each triggering test case of
# a project-bug can or cannot be performed. A sanity check on a project-bug can
# only be performed if and only if a buggy line / candidate line could be
# identified in bytecode.
#
_is_it_a_known_exception() {
  local USAGE="Usage: ${FUNCNAME[0]} <pid> <bid>"
  if [ "$#" != 2 ]; then
    echo "$USAGE" >&2
    return 1
  fi

  local pid="$1"
  local bid="$2"

  if [ "$pid" == "Closure" ] && [ "$bid" == "100" ]; then
    # there are two different ways of triggering this bug: either covering the
    # return statement (i.e., line number 146) or the lines annotated as a
    # 'fault of omission'. If a test case does not execute the return statement
    # it is impossible to cover any line annotated as a 'fault of omission'
    # because there is not a bytecode instruction for any of the candidates
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "103" ]; then
    # there are two faulty classes, however there is one test case that does not
    # execute any line annotated as FAULT_OMISSION, i.e., it does not execute
    # any candidate line (manually check and it is correct)
    return 0
  fi

  if [ "$pid" == "Closure" ] && [ "$bid" == "119" ]; then
    # there is not a bytecode instruction for the candidate lines
    return 0
  fi

  if [ "$pid" == "Math" ] && [ "$bid" == "12" ]; then
    # there is not a bytecode instruction for the buggy line or the two lines
    # annotated as a 'fault of omission'
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

  return 1
}
