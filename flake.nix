{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-darwin"
        "x86_64-linux"
      ];
      forAllSystems =
        f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            just
            bash
            coreutils
            findutils
            gawk
            gnugrep
            gnused
            util-linux
            smartmontools
            e2fsprogs
            hdparm
          ];
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-rfc-style);
    };
}
