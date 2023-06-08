{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-23.05";
    fenix.url = "github:nix-community/fenix";
    cargo-clif = {
      url = "github:bjorn3/rustc_codegen_cranelift";
      flake = false;
    };
  };
  outputs = {
    self,
    nixpkgs,
    fenix,
    cargo-clif,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {inherit system;};

    # rust toolchain
    toolchain = fenix.packages.${system}.complete.withComponents ["cargo" "rustc" "rustfmt" "rust-src" "rustc-dev" "llvm-tools-preview"];
    env = {
      nativeBuildInputs = [pkgs.removeReferencesTo];
      buildInputs = [toolchain pkgs.git];

      CARGO = "${toolchain}/bin/cargo";
      RUSTC = "${toolchain}/bin/rustc";
      RUSTDOC = "${toolchain}/bin/rustdoc";
    };

    # rust dependencies from crates.io
    crates = map (
      {
        name,
        version,
        checksum,
        ...
      }: let
        crate = pkgs.fetchurl {
          url = "https://crates.io/api/v1/crates/${name}/${version}/download";
          name = "download-${name}-${version}";
          sha256 = checksum;
        };
      in
        pkgs.runCommandLocal "unpack-${name}-${version}" {} ''
          mkdir -p $out
          tar xzf ${crate} -C $out
          echo '{"package":"${checksum}","files":{}}' > $out/${name}-${version}/.cargo-checksum.json
        ''
    ) (builtins.filter (builtins.hasAttr "checksum") (pkgs.lib.flatten (map (x: (fromTOML x).package) (map builtins.readFile (builtins.filter (x: builtins.baseNameOf x == "Cargo.lock") (pkgs.lib.filesystem.listFilesRecursive cargo-clif))))));
    nix-sources = pkgs.runCommand "deps" {} ''
      mkdir -p $out
      ${builtins.concatStringsSep "\n" (map (crate: ''
          for f in $(ls ${crate}); do
            test -e $out/$f || ln -s ${crate}/$f $out/$f
          done
        '')
        crates)}
    '';
    cargoconfig = pkgs.writeText "cargo-config" ''
      [source.crates-io]
      replace-with = "nix-sources"
      [source.nix-sources]
      directory = "${nix-sources}"
    '';

    # git repos downloaded by `./y.rs prepare`
    files = builtins.filter (pkgs.lib.hasSuffix ".rs") (pkgs.lib.filesystem.listFilesRecursive (cargo-clif + /build_system));
    match = regex: string: builtins.filter builtins.isList (builtins.split regex string);
    matches = pkgs.lib.flatten (map (match "(GitRepo::github[(][^)]*[)])") (map builtins.readFile files));
    clean = map (builtins.replaceStrings ["\n" " "] ["" ""]) matches;
    repos = map (x: builtins.head (match "GitRepo::github[(]\"(.*)\",\"(.*)\",\"(.*)\",\".*\",?[)]" x)) clean;
    downloads = builtins.listToAttrs (map (x: let
        user = builtins.elemAt x 0;
        repo = builtins.elemAt x 1;
        rev = builtins.elemAt x 2;
      in {
        name = repo;
        value = builtins.fetchGit {
          inherit rev;
          url = "https://github.com/${user}/${repo}.git";
        };
      })
      repos);
    download = pkgs.runCommand "cargo-clif-downloads" {} ''
      mkdir -p $out
      ${builtins.concatStringsSep "\n" (map (name: "ln -s ${downloads.${name}} $out/${name}") (builtins.attrNames downloads))}
    '';
  in {
    packages.${system}.default = pkgs.stdenv.mkDerivation (env
      // {
        name = "cargo-clif";
        src = cargo-clif;

        patches = [./build_system.patch];

        configurePhase = ''
          export CARGO_HOME=$PWD/.cargo-home
          mkdir -p $CARGO_HOME
          ln -s ${cargoconfig} $CARGO_HOME/config

          cp -Lr ${download} download
          chmod -R u+w download
        '';

        buildPhase = ''
          rustc y.rs
          ./y prepare
          ./y build
        '';

        installPhase = ''
          mkdir -p $out/bin
          for f in $(ls dist/bin); do
            mv dist/bin/$f $out/bin/''${f%-clif}
          done
          for f in $(ls ${toolchain}/bin); do
            test -e $out/bin/$f || ln -s ${toolchain}/bin/$f $out/bin/$f
          done
          mv dist/lib $out
          find $out -type f | xargs remove-references-to -t ${nix-sources}
        '';
      });

    devShells.${system}.default = pkgs.mkShell {
      buildInputs = [toolchain];
    };

    checks.${system}.default =
      pkgs.runCommand "test" {
        buildInputs = [self.packages.${system}.default pkgs.stdenv.cc];
      } ''
        mkdir -p $out
        cd $out
        cargo new cargo-clif-test
        cd cargo-clif-test
        [[ "$(cargo run)" = "Hello, world!" ]]
      '';
  };

  nixConfig = {
    extra-substituters = ["https://cargo-clif-nix.cachix.org"];
    extra-trusted-public-keys = ["cargo-clif-nix.cachix.org-1:pU9n2ylKVZPgv+pXDWJfyajcbLXVQk5YwM9ukRHN1qA="];
  };
}
