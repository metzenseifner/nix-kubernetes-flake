{
  description = ''
    Infrastructure provisioner module for Vanilla Kubernetes NixOS Modules Flake
    providing control plane node and worker node exports.

    installed normally direclty with the kubeadm CLI Util

    Missing from vanilla kubernetes:
    - dashboard
    - ingress
    - networking
    - observability
    - storage

    Node roles are covered by NixOS VM tests that boot the real thing:
    nix build .#checks.aarch64-linux.control-plane-node -L
  '';
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };
  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;

      # ═══════════════════════════════════════════════════════════════════
      #  VM Test Catalog
      #
      #    checks.⟨sys⟩
      #      = { stem f ↦ runNixOSTest f | f ∈ ./**, f ∈ *.test.nix }
      #
      #  In plain English: any file named `<thing>.test.nix`, anywhere in
      #  this flake, is a NixOS VM test of `<thing>`, and it lives in the
      #  same directory as `<thing>` rather than in a tests/ tree that has
      #  to be kept parallel to this one. Adding a test is adding a file —
      #  there is no entry to write here.
      #
      #  The suffix carries the whole convention, which is what keeps
      #  colocation cheap: `control-plane-node.nix` and
      #  `control-plane-node.test.nix` sort next to each other, the check
      #  is named after the module, and a module whose test went missing
      #  is visible from a directory listing.
      #
      #  A test file is a plain NixOS *test module* — `{ name; nodes;
      #  testScript; }` — and knows nothing about `pkgs` or about systems.
      #  Applying `runNixOSTest` is this flake's job, done once per target
      #  platform below, so the same file is the aarch64 check and the
      #  x86_64 check without being written twice.
      #
      #  The attribute name is the bare stem, never a path, for the same
      #  reason the host catalog in ../../flake.nix is flat: it is what you
      #  type. Two `<stem>.test.nix` files in different directories would
      #  therefore silently shadow one another, so they are an eval error
      #  instead.
      # ═══════════════════════════════════════════════════════════════════
      testFiles =
        let
          walk =
            dir:
            lib.concatLists (
              lib.mapAttrsToList (
                name: type:
                if type == "directory" then
                  walk (dir + "/${name}")
                else if type == "regular" && lib.hasSuffix ".test.nix" name then
                  [
                    {
                      name = lib.removeSuffix ".test.nix" name;
                      path = dir + "/${name}";
                    }
                  ]
                else
                  [ ]
              ) (builtins.readDir dir)
            );
        in
        walk ./.;

      # testModules :: {name, path} -> testmodules
      testModules =
        let
          byStem = lib.groupBy (test: test.name) testFiles;

          shadowed = lib.filterAttrs (_: tests: builtins.length tests > 1) byStem;

          report = lib.concatStringsSep "\n" (
            lib.mapAttrsToList (
              stem: tests: "  ${stem}: ${lib.concatMapStringsSep ", " (test: toString test.path) tests}"
            ) shadowed
          );
        in
        if shadowed != { } then
          throw ''
            Two VM test files share a name. The check set is flat, so one would
            shadow the other; rename one of each pair:

            ${report}
          ''
        else
          lib.mapAttrs (_: tests: (builtins.head tests).path) byStem;

      # The platforms a node may be bolted to. `runNixOSTest` boots a guest
      # of the host's own architecture, so a check is only meaningful on a
      # builder of that platform — aarch64-linux is what the nodes under
      # nixosConfigurations/kubernetes actually run.
      testPlatforms = [
        "aarch64-linux"
        "x86_64-linux"
      ];
    in
    {
      nixosModules = {
        control-plane-node = ./nodes/control-plane-node.nix;
        worker-plane-node = ./nodes/worker-plane-node.nix;
        utilities = ./utilities;
      };

      checks = lib.genAttrs testPlatforms (
        system: lib.mapAttrs (_: nixpkgs.legacyPackages.${system}.testers.runNixOSTest) testModules
      );

      # nixosConfigurations = nixpkgs.lib.nixosSystem {
      #   inherit system;
      #   modules = [
      #     ./hosts/control.nix
      #     ./hosts/hardware/control.nix
      #   ];
      # };

    };
}
