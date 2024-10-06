let

pkgs = import <nixpkgs> {};

zig = pkgs.stdenv.mkDerivation {
    name = "zig";
    src = fetchTarball (
        if (pkgs.system == "x86_64-linux") then {
            url = "https://ziglang.org/builds/zig-linux-x86_64-0.14.0-dev.1694+3b465ebec.tar.xz";
            sha256 = "13nby79647bzwvkiygfhvpnq1vv8r3j9snsrvjyj3drl6p9mk8d2";
        } else
        throw ("Unknown system " ++ pkgs.system)
    );
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
    mkdir -p $out
    mv ./* $out/
    mkdir -p $out/bin
    mv $out/zig $out/bin
    '';
};

mlc = pkgs.stdenv.mkDerivation {
    name = "mlc";
    nativeBuildInputs = [ pkgs.autoPatchelfHook ];
    src = builtins.fetchurl (
        if (pkgs.system == "x86_64-linux") then {
            url = "https://downloadmirror.intel.com/834254/mlc_v3.11b.tgz";
            sha256 = "0918xgpwid4j5wgx96sv0xgj020s60w3kif9ckamkbs5s4kvsnjx";
        } else
        throw ("Unknown system " ++ pkgs.system)
    );
    unpackPhase = ''
       tar -xzf $src
    '';
    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;
    installPhase = ''
    mkdir -p $out
    mkdir -p $out/bin
    mv ./Linux/mlc $out/bin/mlc
    '';
};

in

pkgs.mkShell rec {
    nativeBuildInputs = [
        zig
        pkgs.cargo
        pkgs.wasmtime
        mlc
    ];
    buildInputs = [
    ];
}