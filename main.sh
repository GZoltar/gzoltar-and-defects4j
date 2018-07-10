#!/bin/bash
set -e # makes the shell to fail if any command returns a non-zero status

SCRIPT_DIR=$(cd `dirname $0` && pwd)
source "$SCRIPT_DIR/utils.sh" || exit 1

# -------------------------------------------------------- Envs & Args

# Check whether JAVA_HOME is set
[ "$JAVA_HOME" != "" ] || die "[ERROR] JAVA_HOME is not set!"
# Check whether ANT_HOME is set
[ "$ANT_HOME" != "" ] || die "[ERROR] ANT_HOME is not set!"
# Check whether D4J_HOME is set
[ "$D4J_HOME" != "" ] || die "[ERROR] D4J_HOME is not set!"

USAGE="Usage: $0 <pid> <bid>"
[ $# -eq 2 ] || die "$USAGE";
PID="$1"
BID="$2"

export PATH="$JAVA_HOME/bin:$ANT_HOME/bin:$PATH"

# --------------------------------------------------------------- Main

echo "PID: $$"
hostname
java -version
ant -version

echo ""
echo "[INFO] Checkout $PID-${BID}b"
tmp_dir=$(_checkout "$PID" "$BID" "b");
if [ $? -ne 0 ]; then
  echo "[ERROR] Checkout of the BUGGY version has failed!"
  rm -rf "$tmp_dir"
  exit 1;
fi

echo ""
echo "[INFO] Compile $PID-${BID}b"
_compile "$tmp_dir"
if [ $? -ne 0 ]; then
  echo "[ERROR] Compilation of $PID-${BID}b has failed!"
  rm -rf "$tmp_dir"
  exit 1;
fi

# ------------------------------------ Run manually-written test cases

echo ""
echo "[INFO] Running relevant developer-written test cases with GZoltar on $PID-${BID}b"
"$D4J_HOME/framework/bin/defects4j" fault-localization -w "$tmp_dir" -y sfl -e ochiai -g line

if [ $? -ne 0 ]; then
  echo "[ERROR] Execution of all manually-written test cases with GZoltar on $PID-${BID}b has failed!"
  echo "[DEBUG] Log:"
  cat "$tmp_dir/.fault-localization.log"
  rm -rf "$tmp_dir"
  exit 1;
fi

if [ ! -s "$tmp_dir/gzoltar.ser" ]; then
  echo "[ERROR] File '$tmp_dir/gzoltar.ser' does not exit or it is empty!"
  rm -rf "$tmp_dir"
  exit 1;
elif [ ! -s "$tmp_dir/sfl/txt/matrix.txt" ]; then
  echo "[ERROR] File '$tmp_dir/sfl/txt/matrix.txt' does not exit or it is empty!"
  rm -rf "$tmp_dir"
  exit 1;
elif [ ! -s "$tmp_dir/fault_localization.csv" ]; then
  echo "[ERROR] File '$tmp_dir/fault_localization.csv' does not exit or it is empty!"
  rm -rf "$tmp_dir"
  exit 1;
fi

# ------------------------------------------------------ Sanity checks

TESTS_FILE="$tmp_dir/sfl/txt/tests.csv"
SPECTRA_FILE="$tmp_dir/sfl/txt/spectra.csv"
MATRIX_FILE="$tmp_dir/sfl/txt/matrix.txt"
LINE_OCHIAI_RANKING_FILE="$tmp_dir/sfl/txt/line.ochiai.ranking.csv"

echo ""
echo "[INFO] Running a few sanity checks on $PID-${BID}b"

## 1. Does GZoltar and D4J agree on the number of triggering test cases?

num_triggering_test_cases_gzoltar=$(grep -a ",FAIL," "$TESTS_FILE" | wc -l)
num_triggering_test_cases_d4j=$(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID" | wc -l)

if [ "$num_triggering_test_cases_gzoltar" -ne "$num_triggering_test_cases_d4j" ]; then
  echo "[ERROR] Number of triggering test cases reported by GZoltar ($num_triggering_test_cases_gzoltar) is not the same as reported by D4J ($num_triggering_test_cases_d4j)!"
  rm -rf "$tmp_dir"
  exit 1;
fi

## 2. Does GZoltar and D4J agree on the list of triggering test cases?

agree=true
while read -r trigger_test; do
  class_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f1 -d':')
  unit_test_name=$(echo "$trigger_test" | cut -f2 -d' ' | cut -f3 -d':')

  # e.g., org.apache.commons.math.complex.ComplexTest#testMath221,FAIL,3111187,junit.framework.AssertionFailedError:
  if ! grep -a -q "^$class_test_name#$unit_test_name,FAIL," "$TESTS_FILE"; then
    echo "[ERROR] Triggering test case '$class_test_name#$unit_test_name' has not been reported by GZoltar!"
    agree=false
  fi
done < <(grep -a "^--- " "$D4J_HOME/framework/projects/$PID/trigger_tests/$BID")

if [[ $agree == false ]]; then
  rm -rf "$tmp_dir"
  exit 1;
fi

## 3. Has the faulty class(es) been reported?

num_classes_not_reported=0
modified_classes_file="$D4J_HOME/framework/projects/$PID/modified_classes/$BID.src"
while read -r modified_class; do
  class_name=$(echo "${modified_class%.*}\$${modified_class##*.}")
  echo "[DEBUG] modified_class: $modified_class, class_name: $class_name"
  if grep -q "^$class_name#" "$SPECTRA_FILE"; then
    echo "[DEBUG] Has '$class_name' been reported? Yes."
  else
    echo "[DEBUG] Has '$class_name' been reported? No."
    num_classes_not_reported=$((num_classes_not_reported+1))
  fi
done < <(cat "$modified_classes_file")

if [ "$num_classes_not_reported" -eq "1" ] && [ "$PID" == "Mockito" ] && [ "$BID" == "19" ]; then
  # one of the modified classes of Mockito-19 is an interface without
  # any code. as interfaces with no code have no lines of code in bytecode,
  # GZoltar does instrument it and therefore does not report it in the
  # spectra file
  echo "Mockito-19 excluded from the check on the number of modified classes reported."
elif [ "$num_classes_not_reported" -ne "0" ]; then
  rm -rf "$tmp_dir"
  exit 1;
fi

## 4. Has the faulty line(s) been covered by triggering test case(s)?

buggy_lines_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.buggy.lines"
num_buggy_lines=$(wc -l "$buggy_lines_file" | cut -f1 -d' ')

unrankable_lines_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.unrankable.lines"
num_unrankable_lines=0
if [ -f "$unrankable_lines_file" ]; then
  num_unrankable_lines=$(wc -l "$unrankable_lines_file" | cut -f1 -d' ')
fi

candidates_file="$D4J_HOME/framework/projects/$PID/buggy_lines/$BID.candidates"

if [ "$num_buggy_lines" -ne "$num_unrankable_lines" ]; then

  # find out whether all failing test cases cover at least one buggy line
  while read -r test_coverage; do
    false_positive=true

    failing_test_id=$(echo "$test_coverage" | cut -f1 -d':')
    echo "[INFO] Test case id '$failing_test_id'"

    test_cov_file="/tmp/$USER-test-method-coverage-$$.txt"
    echo "$test_coverage" | cut -f2 -d':' | awk '{for (i = 1; i <= NF; ++i) if ($i == 1) print i}' > "$test_cov_file"

    while read -r buggy_line; do
      echo "  [DEBUG] Buggy_line: $buggy_line"
      java_file=$(echo "$buggy_line" | cut -f1 -d'#')
      line_number=$(echo "$buggy_line" | cut -f2 -d'#')
      echo "  [DEBUG] Java_file: $java_file"
      echo "  [DEBUG] Line_number: $line_number"

      if grep -q "^$java_file#$line_number," "$LINE_OCHIAI_RANKING_FILE"; then
        echo "  [DEBUG] Test case id '$failing_test_id' covers => buggy line: '$java_file#$line_number'"
        false_positive=false
        break # break this while loop, as we already know that it
        # is not a false positive
      fi
    done < <(grep -v "FAULT_OF_OMISSION" "$buggy_lines_file")

    if [[ $false_positive == true ]]; then
      # at this point, no buggy line has been found, try to find a
      # suitable candidate line, if any
      if [ -s "$candidates_file" ]; then
        while read -r candidate_line; do
          echo "  [DEBUG] candidate_line: $candidate_line"
          candidate=$(echo "$candidate_line" | cut -f2 -d',')
          echo "  [DEBUG] candidate: $candidate"

          if grep -q "^$candidate," "$LINE_OCHIAI_RANKING_FILE"; then
            echo "  [DEBUG] Test case id '$failing_test_id' covers => candidate line: '$candidate'"
            false_positive=false
            break # break this while loop, as we already know that it
            # is not a false positive
          fi
        done < <(cat "$candidates_file")
      fi
    fi

    ##
    # Known exceptions

    if [ "$PID" == "Closure" ] && [ "$BID" == "67" ]; then
      #  ) {
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi
    if [ "$PID" == "Closure" ] && [ "$BID" == "114" ]; then
      # } else {
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi
    if [ "$PID" == "Closure" ] && [ "$BID" == "119" ]; then
      # case x:
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi

    if [ "$PID" == "Math" ] && [ "$BID" == "12" ]; then
      # implements X
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi
    if [ "$PID" == "Math" ] && [ "$BID" == "104" ]; then
      # private static final double DEFAULT_EPSILON = 10e-9;
      # ^ private fields do not have a line number in bytecode
      continue
    fi

    if [ "$PID" == "Lang" ] && [ "$BID" == "29" ]; then
      # static float toJavaVersionInt(String version) {
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi
    if [ "$PID" == "Lang" ] && [ "$BID" == "56" ]; then
      # private fields are not in the bytecode
      # private Rule[] mRules;
      # private int mMaxLengthEstimate;
      # ^ the above lines do not have a line number in bytecode
      continue
    fi

    if [ "$PID" == "Mockito" ] && [ "$BID" == "8" ]; then
      # } else {
      # ^ buggy line to which there is not a line number in bytecode
      continue
    fi

    if [[ $false_positive == true ]]; then
      echo "[ERROR] Test case id '$failing_test_id' does not cover any buggy line!"
      rm -rf "$tmp_dir"
      exit 1;
    fi
  done < <(grep -n " -$" "$MATRIX_FILE")

fi

# do not leave anything behind
rm -rf "$tmp_dir"

# EOF

