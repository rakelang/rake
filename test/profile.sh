# Sourced by the native runtime tests. `use_profile PROFILE` selects how C
# harnesses for that profile are built and executed on this host:
#   lanes        f32 lanes per rack
#   compiler     C compiler
#   object_copy  objcopy for the profile's object format
#   vector_flags C flags enabling exactly the profile's vector extension
#   link_flags   flags linking a static AArch64 binary for QEMU
#   flags        vector_flags followed by link_flags
#   runner       command prefix that executes the binary
# AVX-512 runs natively on AVX-512F hardware and otherwise under the Intel SDE
# that the development shell pins as RAKE_SDE. Without either, the test fails
# rather than treating object verification as runtime agreement.
use_profile() {
  compiler=gcc
  object_copy=objcopy
  link_flags=()
  runner=()
  case "$1" in
    x86-sse2) lanes=4; vector_flags=(-msse2 -mno-avx -mno-fma) ;;
    x86-avx2) lanes=8; vector_flags=(-mavx2 -mfma) ;;
    x86-avx512)
      lanes=16
      vector_flags=(-mavx512f -mno-avx512dq -mno-avx512bw -mno-avx512vl)
      if ! grep -qw avx512f /proc/cpuinfo; then
        : "${RAKE_SDE:?AVX-512 runtime checks need AVX-512F hardware or the Intel SDE pinned as RAKE_SDE}"
        runner=("${RAKE_SDE}" -skx --)
      fi
      ;;
    aarch64-neon)
      lanes=4
      compiler=aarch64-unknown-linux-gnu-gcc
      object_copy=aarch64-unknown-linux-gnu-objcopy
      vector_flags=(-march=armv8-a)
      link_flags=(-static -isystem "${RAKE_AARCH64_LIBC_DEV}/include"
        -B"${RAKE_AARCH64_LIBC}/lib" -L"${RAKE_AARCH64_LIBC_STATIC}/lib")
      runner=(qemu-aarch64)
      ;;
    *) echo "unknown native profile: $1" >&2; return 1 ;;
  esac
  flags=("${vector_flags[@]}" "${link_flags[@]}")
}
