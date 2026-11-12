{
  description = "SDF renderer - Odin + SDL3 GPU + Slang";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs:
        let
          runtimeLibs = with pkgs; [
            sdl3
            vulkan-loader
            libGL
            wayland
            libxkbcommon
            libx11
            libxcursor
            libxrandr
            libxi
          ];
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              odin
              ols
              just
              shader-slang
              sdl3
              vulkan-tools
              vulkan-validation-layers
            ];

            # Odin's vendor:sdl3 links against system libSDL3; SDL dlopen()s the rest at runtime.
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath runtimeLibs;
            LIBRARY_PATH = pkgs.lib.makeLibraryPath [ pkgs.sdl3 ];
            VK_LAYER_PATH = "${pkgs.vulkan-validation-layers}/share/vulkan/explicit_layer.d";
          };
        });
    };
}
