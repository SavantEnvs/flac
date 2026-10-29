#!/usr/bin/env bash
#
# mayhem/build.sh — build FLAC's eight OSS-Fuzz harnesses (libFuzzer + standalone) and the project's
# own test suite. Runs in /mayhem as `mayhem`; re-runnable and offline (all inputs are in the image).
#
# Three out-of-tree autotools builds, all under gitignored `build-*` dirs (upstream's `/*[Bb]uild*/`):
#   build-fuzz        sanitized + libFuzzer-instrumented libs, links the harnesses against libFuzzer
#   build-standalone  sanitized, no libFuzzer instrumentation, links the harnesses against the run-once main
#   build-tests       NORMAL flags, builds the test programs mayhem/test.sh runs
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

HARNESSES="fuzzer_decoder fuzzer_encoder fuzzer_encoder_v2 fuzzer_seek fuzzer_metadata fuzzer_reencoder fuzzer_tool_flac fuzzer_tool_metaflac"

./autogen.sh >/dev/null

# Leak detection off at build time (ASan/UBSan stay on and halting).
mkdir -p build-fuzz build-standalone build-tests
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o build-fuzz/lsan_off.o
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o build-standalone/standalone_main.o

CONF="--disable-doxygen-docs --disable-examples --disable-shared --enable-static --disable-rpath"

# Only the libraries the harnesses link: with the fuzzing macro, src/flac and src/metaflac as standalone
# programs reference alloc_check_* counters that only the harnesses (oss-fuzz/common.h) define.
make_fuzz_libs() { for d in src/share src/libFLAC src/libFLAC++; do make -C "$d" -j"$MAYHEM_JOBS" >/dev/null; done; }

# 1) libFuzzer binaries. `fuzzer-no-link` instruments the libFLAC objects themselves (not only the harness TU).
# Upstream's OSS-Fuzz contract: the macro compiles out intended signed-overflow in the audio path
# (lpc.c/fixed.c restore_signal), exit() paths in the CLI tools, and other fuzz-hostile code.
FUZZ_DEFS="-DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_DEFS -fsanitize=fuzzer-no-link"
( cd build-fuzz
  ../configure CC="$CC" CXX="$CXX" CFLAGS="$FUZZ_CFLAGS" CXXFLAGS="$FUZZ_CFLAGS" \
      LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" LIB_FUZZING_ENGINE="$LIB_FUZZING_ENGINE" \
      --enable-oss-fuzzers $CONF >/dev/null
  make_fuzz_libs
  make -C oss-fuzz -j"$MAYHEM_JOBS" LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $SRC/build-fuzz/lsan_off.o" >/dev/null )
for h in $HARNESSES; do cp -f "build-fuzz/oss-fuzz/$h" "/mayhem/$h"; done

# 2) standalone reproducers: same harnesses, no fuzzer engine, linked against the run-once main.
STANDALONE_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $FUZZ_DEFS"
( cd build-standalone
  ../configure CC="$CC" CXX="$CXX" CFLAGS="$STANDALONE_CFLAGS" CXXFLAGS="$STANDALONE_CFLAGS" \
      LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" --enable-oss-fuzzers $CONF >/dev/null
  make_fuzz_libs
  make -C oss-fuzz -j"$MAYHEM_JOBS" LIB_FUZZING_ENGINE= \
      LDFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS $SRC/build-fuzz/lsan_off.o $SRC/build-standalone/standalone_main.o" >/dev/null )
for h in $HARNESSES; do cp -f "build-standalone/oss-fuzz/$h" "/mayhem/$h-standalone"; done

# 3) the project's test programs, NORMAL flags (no sanitizers); mayhem/test.sh only runs the scripts.
( cd build-tests
  ../configure CC="$CC" CXX="$CXX" CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" $CONF >/dev/null
  make -j"$MAYHEM_JOBS" >/dev/null
  make -C src -j"$MAYHEM_JOBS" check TESTS= >/dev/null )
