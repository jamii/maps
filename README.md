```
nix-shell
RUSTFLAGS='-C target-cpu=native' cargo run --release src/main.rs
zig run -lc -OReleaseFast -mcpu native ./bench.zig
```