#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -whole-module-optimization -module-cache-path .build/module-cache \
  Sources/PowerWatchCore/Models.swift Sources/PowerWatchCore/NativeSampler.swift \
  Sources/PowerWatchCore/GPUSampler.swift Sources/PowerWatchCore/Measurement.swift \
  benchmarks/swift/main.swift -o build/benchmark-swift
clang -O3 -c benchmarks/rust/macos.c -o build/benchmark-macos.o
if [ -x build/rust-toolchain/cargo/bin/rustc ]; then
  export RUSTUP_HOME="$PWD/build/rust-toolchain/rustup"
  export CARGO_HOME="$PWD/build/rust-toolchain/cargo"
  compiler="$PWD/build/rust-toolchain/cargo/bin/rustc"
else
  compiler=rustc
fi
"$compiler" --edition=2024 -C opt-level=3 -C lto=fat -C codegen-units=1 \
  benchmarks/rust/main.rs -C link-arg="$PWD/build/benchmark-macos.o" -l proc -o build/benchmark-rust
