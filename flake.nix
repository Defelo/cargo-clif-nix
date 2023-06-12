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
    default-toolchain = fenix.packages.${system}.complete;
    default-components = ["cargo" "clippy" "rust-docs" "rust-std" "rustc" "rustfmt" "rust-analyzer" "rust-src"];
    required-components = ["cargo" "rustc" "rust-src" "rustc-dev" "llvm-tools-preview"];

    # apply patches before downloading crates
    patched-cargo-clif = pkgs.stdenv.mkDerivation {
      name = "patched-cargo-clif";
      src = cargo-clif;
      patches = [
        ./build_system.patch
        ./index_map.patch
      ];
      installPhase = "cp -r . $out";
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
    ) (builtins.filter (builtins.hasAttr "checksum") (pkgs.lib.flatten (map (x: (fromTOML x).package) (map builtins.readFile (builtins.filter (x: builtins.baseNameOf x == "Cargo.lock") (pkgs.lib.filesystem.listFilesRecursive patched-cargo-clif))))));
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
    files = builtins.filter (pkgs.lib.hasSuffix ".rs") (pkgs.lib.filesystem.listFilesRecursive (patched-cargo-clif + /build_system));
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
    packages.${system} = {
      inherit default-toolchain;
      default = self.lib.with-toolchain default-toolchain default-components;
    };
    lib = {
      with-toolchain = toolchain': components: let
        toolchain = toolchain'.withComponents (required-components ++ components);
      in
        pkgs.symlinkJoin {
          name = "cargo-clif-with-toolchain";
          paths = [toolchain (self.lib.cargo-clif toolchain)];
          postBuild = let
            cargo-clippy = pkgs.writeShellScript "cargo-clippy" ''
              export PATH=${toolchain}/bin:$PATH
              exec -a cargo-clippy ${toolchain}/bin/cargo-clippy "$@"
            '';
          in (builtins.concatStringsSep "\n" [
            "ln -sf cargo-clif $out/bin/cargo"
            "ln -sf ${cargo-clippy} $out/bin/cargo-clippy"
          ]);
        };
      cargo-clif = toolchain:
        pkgs.stdenv.mkDerivation {
          name = "cargo-clif";
          src = patched-cargo-clif;

          nativeBuildInputs = [pkgs.removeReferencesTo];
          buildInputs = [toolchain pkgs.git];

          CARGO = "${toolchain}/bin/cargo";
          RUSTC = "${toolchain}/bin/rustc";
          RUSTDOC = "${toolchain}/bin/rustdoc";

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
            mv dist $out
            find $out -type f | xargs remove-references-to -t ${nix-sources}
          '';
        };
    };

    devShells.${system}.default = let
      toolchain = default-toolchain.withComponents required-components;
    in
      pkgs.mkShell {
        CARGO = "${toolchain}/bin/cargo";
        RUSTC = "${toolchain}/bin/rustc";
        RUSTDOC = "${toolchain}/bin/rustdoc";
        buildInputs = [toolchain];
      };

    checks.${system} = let
      test = ''
        mkdir -p $out
        cd $out
        cargo new cargo-clif-test
        cd cargo-clif-test
        [[ "$(cargo run)" = "Hello, world!" ]]
        readelf -p .comment target/debug/cargo-clif-test | grep -q cg_clif
      '';
    in {
      default =
        pkgs.runCommand "test-default" {
          buildInputs = [self.packages.${system}.default pkgs.stdenv.cc];
        }
        ''
          ${test}
          cargo clippy
          rust-analyzer diagnostics . 2> stderr
          ! [[ -s stderr ]]
        '';
      no-components =
        pkgs.runCommand "test-no-components" {
          buildInputs = [(self.lib.with-toolchain default-toolchain []) pkgs.stdenv.cc];
        }
        test;
    };
  };

  nixConfig = {
    extra-substituters = ["https://cargo-clif-nix.cachix.org"];
    extra-trusted-public-keys = ["cargo-clif-nix.cachix.org-1:pU9n2ylKVZPgv+pXDWJfyajcbLXVQk5YwM9ukRHN1qA="];
  };
}
