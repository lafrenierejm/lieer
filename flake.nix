{
  description = "Fast fetch and two-way tag synchronization between notmuch and GMail";

  inputs = {
    nixpkgs.url = "https://channels.nixos.org/nixos-unstable/nixexprs.tar.zst";
    flake-parts.url = "github:hercules-ci/flake-parts";
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nix-systems = {
      url = "github:nix-systems/default";
      flake = false;
    };
    pyproject-nix = {
      url = "github:pyproject-nix/pyproject.nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    pyproject-build-systems = {
      url = "github:pyproject-nix/build-system-pkgs";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.uv2nix.follows = "uv2nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    uv2nix = {
      url = "github:pyproject-nix/uv2nix";
      inputs.pyproject-nix.follows = "pyproject-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs:
    let
      # Read pyproject.toml and uv.lock from the repository root.
      workspace = inputs.uv2nix.lib.workspace.loadWorkspace { workspaceRoot = ./.; };

      # Prefer prebuilt wheels; packages that only ship an sdist are built from
      # source and may need the overrides below.
      overlay = workspace.mkPyprojectOverlay { sourcePreference = "wheel"; };

      # Editable install of lieer itself for the development shell.
      editableOverlay = workspace.mkEditablePyprojectOverlay {
        root = "$REPO_ROOT";
      };
    in
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        inputs.git-hooks.flakeModule
        inputs.treefmt-nix.flakeModule
      ];
      systems = import inputs.nix-systems;
      perSystem =
        {
          config,
          self',
          pkgs,
          ...
        }:
        let
          inherit (pkgs) lib;

          pythonSet =
            (pkgs.callPackage inputs.pyproject-nix.build.packages { python = pkgs.python313; }).overrideScope
              (
                lib.composeManyExtensions [
                  inputs.pyproject-build-systems.overlays.default
                  overlay
                  # Fixups for sdist-only packages.
                  (final: prev: {
                    # notmuch2 is built with cffi against libnotmuch's headers.
                    notmuch2 = prev.notmuch2.overrideAttrs (old: {
                      nativeBuildInputs =
                        (old.nativeBuildInputs or [ ])
                        ++ final.resolveBuildSystem {
                          setuptools = [ ];
                          cffi = [ ];
                        };
                      buildInputs = (old.buildInputs or [ ]) ++ [ pkgs.notmuch ];
                    });
                  })
                ]
              );

          # The ruff version pinned in uv.lock, so formatting matches `uv run ruff`.
          ruff = lib.addMetaAttrs { mainProgram = "ruff"; } pythonSet.ruff;

          # ty pinned by uv.lock.
          # Pointed at a virtualenv containing every dependency for resolving third-party imports.
          tyEnv = pythonSet.mkVirtualEnv "lieer-ty-env" workspace.deps.all;
          ty = pkgs.symlinkJoin {
            name = "ty-${pythonSet.ty.version}";
            paths = [ pythonSet.ty ];
            nativeBuildInputs = [ pkgs.makeWrapper ];
            postBuild = ''
              wrapProgram $out/bin/ty --set VIRTUAL_ENV ${tyEnv}
            '';
            meta.mainProgram = "ty";
          };

          editablePythonSet = pythonSet.overrideScope editableOverlay;
          inherit (pkgs.callPackages inputs.pyproject-nix.build.util { }) mkApplication;
        in
        {
          packages = rec {
            lieer = mkApplication {
              venv = pythonSet.mkVirtualEnv "lieer-env" workspace.deps.default;
              package = pythonSet.lieer;
            };
            default = lieer;
          };

          apps.default = {
            type = "app";
            meta.description = "Fast fetch and two-way tag synchronization between notmuch and GMail.";
            program = lib.getExe' self'.packages.default "gmi";
          };

          pre-commit = {
            check.enable = true;
            settings.package = pkgs.prek;
            settings.hooks = {
              actionlint.enable = true;
              convco.enable = true;
              editorconfig-checker.enable = true;
              end-of-file-fixer.enable = true;
              ripsecrets.enable = true;
              trim-trailing-whitespace.enable = true;
              treefmt.enable = true;
              ty = {
                enable = true;
                package = ty;
              };
              typos.enable = true;
              zizmor.enable = true;
            };
          };

          treefmt.config = {
            projectRootFile = ".git/config";
            package = pkgs.treefmt;
            flakeCheck = false; # use pre-commit's check instead
            programs = {
              nixfmt.enable = true;
              prettier.enable = true;
              ruff-check = {
                enable = true;
                package = ruff;
              };
              ruff-format = {
                enable = true;
                package = ruff;
              };
            };
          };

          devShells.default = pkgs.mkShell {
            # Inherit all of the pre-commit and treefmt hooks.
            inputsFrom = [
              config.pre-commit.devShell
              config.treefmt.build.devShell
            ];
            packages = config.pre-commit.settings.enabledPackages ++ [
              (editablePythonSet.mkVirtualEnv "lieer-dev-env" workspace.deps.all)
              pkgs.notmuch
              pkgs.uv
            ];
            env = {
              # Use the Nix-built environment; don't let uv manage or download one.
              UV_NO_SYNC = "1";
              UV_PYTHON = editablePythonSet.python.interpreter;
              UV_PYTHON_DOWNLOADS = "never";
            };
            shellHook = ''
              unset PYTHONPATH
              export REPO_ROOT=$(git rev-parse --show-toplevel)
            '';
          };
        };
    };
}
