#!/usr/bin/env bash
# ------------------------------------------------------------------------------
# 
# This script runs GZoltar on a specified D4J project/bug using manually written.
# 
# Usage:
# ./main.sh <pid> <bid>
# 
# Parameters:
# - <pid>  Defects4J's project ID: Chart, Closure, Lang, Math, Mockito or Time.
# - <bid>  Bug ID
# 
# Examples:
# 
# - Executing GZoltar on bug Chart-5 and using manually written tests
#   $ ./main.sh Chart 5
# 
# Environment variables:
# - JAVA_HOME  Needs to be set and must point to the Java installation.
# - ANT_HOME   Needs to be set and must point to the Ant installation.
# - D4J_HOME   Needs to be set and must point to the Defects4J installation.
# 
# ------------------------------------------------------------------------------

SCRIPT_DIR=$(cd `dirname $0` && pwd)
source "$SCRIPT_DIR/utils.sh" || exit 1

# ------------------------------------------------------------------ Envs & Args

# Check whether JAVA_HOME is set
[ "$JAVA_HOME" != "" ] || die "[ERROR] JAVA_HOME is not set!"
# Check whether ANT_HOME is set
[ "$ANT_HOME" != "" ] || die "[ERROR] ANT_HOME is not set!"
# Check whether D4J_HOME is set
[ "$D4J_HOME" != "" ] || die "[ERROR] D4J_HOME is not set!"

export PATH="$JAVA_HOME/bin:$ANT_HOME/bin:$PATH"

USAGE="Usage: $0 <pid> <bid>"
[ $# -eq 2 ] || die "$USAGE"
PID="$1"
BID="$2"

# --------------------------------------------------------------------------- FL

echo "PID: $$"
hostname
java -version
ant -version
python --version

echo ""
echo "[INFO] Checkout $PID-${BID}b"
tmp_dir=$(_checkout "$PID" "$BID" "b")
if [ $? -ne 0 ]; then
  echo "[ERROR] Checkout of the $PID-${BID}b version has failed!"
  rm -rf "$tmp_dir"
  exit 1
fi

echo ""
echo "[INFO] Run GZoltar on $PID-${BID}b"
echo "[INFO] Start: $(date)"
_fault_localization "$PID" "$BID" "$tmp_dir"
if [ $? -ne 0 ]; then
  echo "[ERROR] Execution of GZoltar on $PID-${BID}b has failed!"
  rm -rf "$tmp_dir"
  exit 1
fi
echo "[INFO] End: $(date)"

# ---------------------------------------------------------------- Sanity checks

TESTS_FILE="$tmp_dir/sfl/txt/tests.csv"
SPECTRA_FILE="$tmp_dir/sfl/txt/spectra.csv"
MATRIX_FILE="$tmp_dir/sfl/txt/matrix.txt"
SOURCE_CODE_LINES_FILE="$tmp_dir/source_code_lines.txt"

_is_a_known_exception "$PID" "$BID"
is_a_known_exception="$?" # 0 yes, 1, no, it is not

echo ""
echo "[INFO] Running a few sanity checks on $PID-${BID}b"
echo ""

## 1. Do GZoltar and D4J agree on the number of triggering test cases?

num_triggering_test_cases_gzoltar=$(grep -a ",FAIL," "$TESTS_FILE" | wc -l)
num_triggering_test_cases_d4j=$(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | wc -l)

if [ "$is_a_known_exception" == "0" ]; then
  echo "[INFO] Do GZoltar and D4J agree on the number of triggering test cases? It is a know exception therefore check is not performed."
elif [ "$num_triggering_test_cases_gzoltar" -ne "$num_triggering_test_cases_d4j" ]; then
  echo "[ERROR] Do GZoltar and D4J agree on the number of triggering test cases? No, D4J: $num_triggering_test_cases_d4j vs GZoltar: $num_triggering_test_cases_gzoltar"
  echo "[DEBUG] D4J triggering test cases:"
  grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | cut -f2 -d' '
  echo "[DEBUG] GZoltar triggering test cases:"
  grep -a ",FAIL," "$TESTS_FILE" | cut -f1 -d','
  rm -rf "$tmp_dir"
  exit 1
else
  echo "[INFO] Do GZoltar and D4J agree on the number of triggering test cases? Yes, D4J: $num_triggering_test_cases_d4j == GZoltar: $num_triggering_test_cases_gzoltar."
fi

## 2. Do GZoltar and D4J agree on the list of triggering test cases?

if [ "$is_a_known_exception" == "0" ]; then
  echo "[INFO] Do GZoltar and D4J agree on the list of triggering test cases? It is a know exception therefore check is not performed."
else
  agree=true
  while read -r trigger_test; do
    class_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f1 -d':')
    unit_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f3 -d':')

    # e.g., org.apache.commons.math.complex.ComplexTest#testMath221,FAIL,3111187,junit.framework.AssertionFailedError:
    if ! grep -a -q -F "$class_test_name#$unit_test_name,FAIL," "$TESTS_FILE"; then
      echo "[ERROR] Triggering test case '$class_test_name#$unit_test_name' has not been reported by GZoltar!"
      agree=false
    fi
  done < <(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID")

  if [[ $agree == false ]]; then
    echo "[ERROR] Do GZoltar and D4J agree on the list of triggering test cases? No."
    rm -rf "$tmp_dir"
    exit 1
  else
    echo "[INFO] Do GZoltar and D4J agree on the list of triggering test cases? Yes."
  fi
fi

## 3. Has the faulty class(es) been reported?

num_classes_not_reported=0
modified_classes_file="$D4J_HOME/framework/projects/$PID/modified_classes/$BID.src"
while read -r modified_class; do
  echo "[DEBUG] modified_class: $modified_class"
  if grep -q "^$modified_class#" "$SPECTRA_FILE"; then
    echo "[DEBUG] Has '$modified_class' been reported? Yes."
  else
    echo "[DEBUG] Has '$modified_class' been reported? No."
    num_classes_not_reported=$((num_classes_not_reported+1))
  fi
done < <(cat "$modified_classes_file")

if [ "$num_classes_not_reported" -eq "1" ] && [ "$PID" == "Mockito" ] && [ "$BID" == "19" ]; then
  # one of the modified classes of Mockito-19 is an interface without
  # any code. as interfaces with no code have no lines of code in bytecode,
  # GZoltar does instrument it however it does not report it in the spectra file
  echo "Mockito-19 excluded from the check on the number of modified classes reported."
elif [ "$num_classes_not_reported" -ne "0" ]; then
  echo "[ERROR] Has the faulty class(es) been reported? No."
  rm -rf "$tmp_dir"
  exit 1
fi

echo "[INFO] Has the faulty class(es) been reported? Yes."

## 4. Does spectra file include at least one buggy-line?

buggy_lines_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.buggy.lines"
num_buggy_lines=$(wc -l "$buggy_lines_file" | cut -f1 -d' ')

unrankable_lines_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.unrankable.lines"
num_unrankable_lines=0
if [ -f "$unrankable_lines_file" ]; then
  num_unrankable_lines=$(wc -l "$unrankable_lines_file" | cut -f1 -d' ')
fi

candidates_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.candidates"

if [ "$is_a_known_exception" == "0" ]; then
  echo "[INFO] Does spectra file include at least one buggy-line? It is a know exception therefore check is not performed."
elif [ "$num_buggy_lines" -ne "$num_unrankable_lines" ]; then

  at_least_one_buggy_line_in_spectra_file=false
  while read -r buggy_line; do
    echo "[DEBUG] Buggy line: $buggy_line"
    class_name=$(echo "$buggy_line" | cut -f1 -d'#' | sed 's/.java$//' | tr '/' '.')
    line_number=$(echo "$buggy_line" | cut -f2 -d'#')

    if grep -q ":$class_name#$line_number$" "$SOURCE_CODE_LINES_FILE"; then
      echo "  [DEBUG] Buggy line '$class_name#$line_number' is part of another line"
      buggy_line=$(grep ":$class_name#$line_number$" "$SOURCE_CODE_LINES_FILE" | cut -f1 -d':')
      class_name=$(echo "$buggy_line" | cut -f1 -d'#')
      line_number=$(echo "$buggy_line" | cut -f2 -d'#')
    fi
    echo "  [DEBUG] Class name: $class_name"
    echo "  [DEBUG] Line number: $line_number"

    if grep -q "^$class_name#$line_number$" "$SPECTRA_FILE"; then
      echo "  [DEBUG] Buggy line $class_name#$line_number has been reported"
      at_least_one_buggy_line_in_spectra_file=true
      break # break this while loop, as we already know that it
      # is not a false positive
    fi
  done < <(grep -v "FAULT_OF_OMISSION" "$buggy_lines_file")

  if [[ $at_least_one_buggy_line_in_spectra_file == false ]]; then
    # at this point, no buggy line has been found, try to find a
    # suitable candidate line, if any
    if [ -s "$candidates_file" ]; then
      while read -r candidate_line; do
        echo "[DEBUG] Candidate line: $candidate_line"
        candidate=$(echo "$candidate_line" | cut -f2 -d',' | sed 's/.java#/#/' | tr '/' '.')

        if grep -q ":$candidate$" "$SOURCE_CODE_LINES_FILE"; then
          echo "  [DEBUG] Candidate line '$candidate' is part of another line"
          candidate=$(grep ":$candidate$" "$SOURCE_CODE_LINES_FILE" | cut -f1 -d':')
        fi
        echo "  [DEBUG] '$candidate'"

        if grep -q "^$candidate$" "$SPECTRA_FILE"; then
          echo "  [DEBUG] Candidate line $candidate has been reported"
          at_least_one_buggy_line_in_spectra_file=true
          break # break this while loop, as we already know that it
          # is not a false positive
        fi
      done < <(cat "$candidates_file")
    else
      echo "[DEBUG] Candidates file '$candidates_file' is empty or does not exist"
    fi
  fi

  if [[ $at_least_one_buggy_line_in_spectra_file == false ]]; then
    echo "[ERROR] Does spectra file include at least one buggy-line? No."
    rm -rf "$tmp_dir"
    exit 1
  else
    echo "[INFO] Does spectra file include at least one buggy-line? Yes."
  fi
else
  echo "[INFO] Does spectra file include at least one buggy-line? Check cannot be performed as there is not any rankable line."
fi

## 5. Do all test cases cover at least one buggy-line?

if [ "$is_a_known_exception" == "0" ]; then
  echo "[INFO] Do all test cases cover at least one buggy-line? It is a know exception therefore check is not performed."
elif [ "$num_buggy_lines" -ne "$num_unrankable_lines" ]; then

  # find out whether all failing test cases cover at least one buggy line
  while read -r test_coverage; do
    false_positive=true

    failing_test_id=$(echo "$test_coverage" | cut -f1 -d':')
    echo "[DEBUG] Test case id '$failing_test_id'"

    test_cov_file="$tmp_dir/$USER-test-$failing_test_id-covered-components-$$.txt"
    echo "$test_coverage" | cut -f2 -d':' | awk '{for (i = 1; i <= NF; ++i) if ($i == 1) print i}' > "$test_cov_file"

    while read -r buggy_line; do
      class_name=$(echo "$buggy_line" | cut -f1 -d'#' | sed 's/.java$//' | tr '/' '.')
      line_number=$(echo "$buggy_line" | cut -f2 -d'#')

      if grep -q ":$class_name#$line_number$" "$SOURCE_CODE_LINES_FILE"; then
        buggy_line=$(grep ":$class_name#$line_number$" "$SOURCE_CODE_LINES_FILE" | cut -f1 -d':')
        class_name=$(echo "$buggy_line" | cut -f1 -d'#')
        line_number=$(echo "$buggy_line" | cut -f2 -d'#')
      fi

      if ! grep -q "^$class_name#$line_number$" "$SPECTRA_FILE"; then
        continue
      fi

      spectra_id=$(grep -n "^$class_name#$line_number$" "$SPECTRA_FILE" | cut -f1 -d':')
      echo "  [DEBUG] Spectra id of '$class_name#$line_number' is $spectra_id"

      # Does test case id $failing_test_id touch this buggy line?
      if grep -q "^$spectra_id$" "$test_cov_file"; then
        false_positive=false
        break # break this while loop, as we already know that it
        # is not a false positive
      fi
    done < <(grep -v "FAULT_OF_OMISSION" "$buggy_lines_file")

    if [[ $false_positive == true ]]; then
      # at this point, no buggy line has been covered, try to find a suitable
      # candidate line, if any
      if [ -s "$candidates_file" ]; then
        while read -r candidate_line; do
          candidate=$(echo "$candidate_line" | cut -f2 -d',' | sed 's/.java#/#/' | tr '/' '.')

          if grep -q ":$candidate$" "$SOURCE_CODE_LINES_FILE"; then
            candidate=$(grep ":$candidate$" "$SOURCE_CODE_LINES_FILE" | cut -f1 -d':')
          fi

          if ! grep -q "^$candidate$" "$SPECTRA_FILE"; then
            continue
          fi

          spectra_id=$(grep -n "^$candidate$" "$SPECTRA_FILE" | cut -f1 -d':')
          echo "  [DEBUG] Spectra id of candidate '$candidate' is $spectra_id"

          # Does test case id $failing_test_id touch this candidate line?
          if grep -q "^$spectra_id$" "$test_cov_file"; then
            false_positive=false
            break # break this while loop, as we already know that it
            # is not a false positive
          fi
        done < <(cat "$candidates_file")
      else
        echo "[DEBUG] Candidates file '$candidates_file' is empty or does not exist"
      fi
    fi
    rm -f "$test_cov_file"

    if [[ $false_positive == true ]]; then
      echo "[ERROR] Test case id '$failing_test_id' does not cover any buggy line!"
      rm -rf "$tmp_dir"
      exit 1
    else
      echo "[INFO] Do all test cases cover at least one buggy-line? Yes."
    fi
  done < <(grep -n " -$" "$MATRIX_FILE")
else
  echo "[INFO] Do all test cases cover at least one buggy-line? Check cannot be performed as there is not any rankable line."
fi

echo "DONE!"

# Clean up
rm -rf "$tmp_dir"

exit 0

# EOF

