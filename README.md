```
nix-shell
RUSTFLAGS='-C target-cpu=native' cargo run --release src/main.rs
zig run -lc -OReleaseFast -mcpu native ./bench.zig
zig build-exe -OReleaseFast -target wasm32-wasi -mcpu=mvp+bulk_memory+simd128 ./bench.zig && wasmtime ./bench.wasm
```