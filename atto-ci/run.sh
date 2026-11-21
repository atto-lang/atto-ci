#!/usr/bin/env bash
# Remote (Linux) suite runner for atto-ci mirror snapshots. Mirrors gate/lib.sh detect():
#   java: mvn-full + node-test     llvm: ctest-full + node-test     net: dotnet-full + node-test
# Writes atto-ci-out/{<suite>.status,<suite>.fail,<suite>.log.tail} and summary.tsv.
set -uo pipefail
out=atto-ci-out; mkdir -p "$out"
kind=$(ls atto-ci/kind-* 2>/dev/null | head -1 | sed 's#.*/kind-##')
# Restore the source repo's own workflows (parked so they never trigger in the mirror): source
# policy tests read them. Stage them so `git ls-files` sees exactly the source tree's set.
rm -f .github/workflows/atto-ci.yml
if [ -d atto-ci/orig-workflows ]; then
  mkdir -p .github/workflows && cp -a atto-ci/orig-workflows/. .github/workflows/
  git add -A .github/workflows >/dev/null 2>&1 || true
fi
git rm -q --cached .github/workflows/atto-ci.yml >/dev/null 2>&1 || true
export CI=1 DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
export JOBS=$(nproc 2>/dev/null || sysctl -n hw.ncpu)
# Per-suite wall-clock limit (a PR that deadlocks a test must not stall a whole batch round).
tmo(){ local t=$1; shift; perl -e 'my $t=shift; my $p=fork(); if(!$p){setpgrp(0,0); exec @ARGV; exit 127} $SIG{ALRM}=sub{kill "-KILL",$p; exit 124}; alarm $t; waitpid($p,0); exit($?>>8 || ($?&127?128:0))' "$t" "$@"; }
if [ "$(uname)" = Darwin ]; then T_JAVA=2100; else T_JAVA=900; fi; T_LLVM=2400; T_NET=1200; T_NODE=900
record(){ # suite status
  echo "$2" > "$out/$1.status"; tail -n 200 "$out/$1.log" > "$out/$1.log.tail" 2>/dev/null || true
  printf '%s\t%s\t%s\n' "$1" "$2" "$(wc -l < "$out/$1.fail" 2>/dev/null | tr -d ' ')" >> "$out/summary.tsv"; }
node_suite(){
  local files; files=$(git ls-files '*.test.mjs' 2>/dev/null)
  [ -z "$files" ] && return
  tmo $T_NODE node --test $files > "$out/node-test.log" 2>&1; local s=$?
  # spec reporter ("✖ name (1.2ms)") or TAP ("not ok N - name")
  { grep -E '^[[:space:]]*✖ ' "$out/node-test.log" | grep -v 'failing tests:' | sed -E 's/^[[:space:]]*✖ //; s/ \([0-9.]+m?s\)$//'
    grep -E '^[[:space:]]*not ok [0-9]+ - ' "$out/node-test.log" | sed -E 's/^[[:space:]]*not ok [0-9]+ - //'; } | sort -u > "$out/node-test.fail"
  record node-test $s; }
case "$kind" in
  java)
    # SHARD/SHARDS split the suite by test class (macOS runners are ~8x slower than Linux here).
    extra=""
    if [ "${SHARDS:-1}" -gt 1 ]; then
      cls=$(git ls-files "src/test/java/*" | grep -E "/(Test[^/]*|[^/]*(Test|Tests|TestCase))\.java$" | sed "s#.*/##; s#\.java$##" | sort -u | awk -v i="${SHARD:-0}" -v n="$SHARDS" "(NR-1)%n==i" | paste -sd, -)
      extra="-Dtest=$cls -Dsurefire.failIfNoSpecifiedTests=false"
    fi
    tmo $T_JAVA mvn -B -ntp -Dstyle.color=never -Dmaven.test.failure.ignore=true -Dsurefire.rerunFailingTestsCount=2 $extra test > "$out/mvn-full.log" 2>&1; s=$?
    # failing test ids from surefire XML: java:Class.method
    find . -path '*/surefire-reports/TEST-*.xml' -print0 2>/dev/null | xargs -0 -r perl -ne '
      if (/<testcase [^>]*name="([^"]*)"[^>]*classname="([^"]*)"/ || /<testcase [^>]*classname="([^"]*)"[^>]*name="([^"]*)"/) {
        ($n,$c) = $1 =~ /\./ ? ($2,$1) : ($1,$2); $cur="java:".( $c =~ s/^.*\.//r ).".$n"; }
      print "$cur\n" if /<(failure|error)[ >]/ && $cur;' | sort -u > "$out/mvn-full.fail"
    grep -E 'Tests run: [0-9]+' "$out/mvn-full.log" | tail -1 > "$out/mvn-full.count"
    # No test summary = the build (or surefire) never ran: never read that as "no failures".
    [ -s "$out/mvn-full.count" ] || echo "BUILD_FAILED" >> "$out/mvn-full.fail"
    [ "$s" = 124 ] && echo "TIMEOUT(mvn-full)" >> "$out/mvn-full.fail"
    record mvn-full $s; [ "${SHARD:-0}" = 0 ] && node_suite ;;
  llvm)
    # macOS: Apple clang + SDK libc++ (as the local gate does); brew llvm@19 only for LLVM libs/tools.
    if [ "$(uname)" = Darwin ]; then L=$(brew --prefix llvm@19); export CC=/usr/bin/clang CXX=/usr/bin/clang++ PATH=$L/bin:$PATH LLVM_DIR=$L/lib/cmake/llvm
    else export CC=clang-19 CXX=clang++-19 PATH=/usr/lib/llvm-19/bin:$PATH LLVM_DIR=/usr/lib/llvm-19/lib/cmake/llvm; fi
    tmo $T_LLVM bash -c 'cmake -S . -B b -DCMAKE_BUILD_TYPE=Release -DLLVM_DIR="$LLVM_DIR" && cmake --build b -j"$JOBS" && ctest --test-dir b -j"$JOBS" --timeout 300' > "$out/ctest-full.log" 2>&1; s=$?
    [ "$s" = 124 ] && echo "TIMEOUT(ctest-full)" >> "$out/ctest-full.timeout"
    sed 's/^[0-9]*://' b/Testing/Temporary/LastTestsFailed.log 2>/dev/null | sed 's/^/ctest:/' | sort -u > "$out/ctest-full.fail"
    grep -E 'tests passed' "$out/ctest-full.log" | tail -1 > "$out/ctest-full.count"
    [ -f b/oreslang-llvmc ] || echo "BUILD_FAILED" >> "$out/ctest-full.fail"
    # The compiler can build while another target fails, so ctest never runs and the fail list is empty:
    # that must never read as "no failures" (it let llvm PRs through on 2026-11-15).
    [ -s "$out/ctest-full.count" ] || grep -qx BUILD_FAILED "$out/ctest-full.fail" || echo "BUILD_FAILED" >> "$out/ctest-full.fail"
    cat "$out/ctest-full.timeout" >> "$out/ctest-full.fail" 2>/dev/null
    record ctest-full $s; node_suite ;;
  net)
    export MSBUILDDISABLENODEREUSE=1 DOTNET_CLI_USE_MSBUILD_SERVER=0 UseSharedCompilation=false
    tmo $T_NET bash -c 'dotnet build compiler/Ores.Net.Compiler/Ores.Net.Compiler.csproj -c Release -warnaserror && dotnet build verification/Ores.Net.Fence.Tests/Ores.Net.Fence.Tests.csproj -c Release -warnaserror && dotnet run -c Release --project verification/Ores.Net.Tests' > "$out/dotnet-full.log" 2>&1; s=$?
    : > "$out/dotnet-full.fail"
    if [ "$s" != 0 ]; then
      { grep -E ' error [A-Z]+[0-9]+' "$out/dotnet-full.log" | sed -E 's#^.*/##; s/ \[.*//' | sort -u | head -20
        grep -m1 -E 'Unhandled exception' "$out/dotnet-full.log" | cut -c1-300; } > "$out/dotnet-full.fail"
      [ "$s" = 124 ] && echo "TIMEOUT(dotnet-full)" >> "$out/dotnet-full.fail"
      [ -s "$out/dotnet-full.fail" ] || echo "dotnet-full exit $s" > "$out/dotnet-full.fail"
    fi
    record dotnet-full $s; node_suite ;;
  *) echo "unknown kind '$kind'" >&2; exit 2 ;;
esac
cat "$out/summary.tsv"
exit 0
