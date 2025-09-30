{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    {
      self,
      nixpkgs,
    }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      devShells.${system}.default =
        pkgs.callPackage (
          {
            mkShell,
            pkg-config,
            stdenv,
          }:
          mkShell {
            nativeBuildInputs = with pkgs; [
              fasm
            ];

            depsBuildBuild = [];
            buildInputs = [];
          }
        ) { };
    };
}
