{
  description = "NixOS (Pi 4) + ROS 2 Humble + prebuilt colcon workspace";

  nixConfig = {
    substituters = [
      "https://cache.nixos.org"
      "https://ros.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "ros.cachix.org-1:dSyZxI8geDCJrwgvCOHDoAfOm5sV1wCPjBkKL+38Rvo="
    ];
  };

  ##############################################################################
  # Inputs
  ##############################################################################
  inputs = {
    nix-ros-overlay.url = "github:lopsided98/nix-ros-overlay/master";
    nixpkgs.follows = "nix-ros-overlay/nixpkgs";
    poetry2nix.url = "github:nix-community/poetry2nix";
    poetry2nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  ##############################################################################
  # Outputs
  ##############################################################################
  outputs = { self, nixpkgs, nix-ros-overlay, poetry2nix, ... }:
  let
    system = "aarch64-linux";

    # Overlay: pin python3 -> python312 (ROS Humble Python deps are happy here)
    pinPython312 = final: prev: {
      python3         = prev.python312;
      python3Packages = prev.python312Packages;
    };

    # pkgs with overlays
    pkgs = import nixpkgs {
      inherit system;
      overlays = [
        nix-ros-overlay.overlays.default
        pinPython312
      ];
    };
    poetry2nixPkgs = poetry2nix.lib.mkPoetry2Nix { inherit pkgs; };

    lib     = pkgs.lib;
    rosPkgs = pkgs.rosPackages.humble;

    # Python (3.12) + helpers
    py = pkgs.python3;
    pyPkgs = py.pkgs or pkgs.python3Packages;
    sp = py.sitePackages;

    # Build a fixed osrf-pycommon (PEP 517), reusing nixpkgs' source
    osrfSrc = pkgs.python3Packages."osrf-pycommon".src;

    osrfFixed = pyPkgs.buildPythonPackage {
      pname        = "osrf-pycommon";
      version      = "2.0.2";
      src          = osrfSrc;
      pyproject    = true;
      build-system = [ py.pkgs.setuptools py.pkgs.wheel ];
      doCheck      = false;
    };

    # Build-time env for colcon
    pyEnv = py.withPackages (ps: [
      ps.pyyaml
      ps.empy
      ps.catkin-pkg
      osrfFixed
    ]);

    webrtcSrc = ./workspace/src/webrtc;

    webrtcEnv = poetry2nixPkgs.mkPoetryEnv {
      projectDir = webrtcSrc;
      preferWheels = true;
      python = py;
    };

    webrtcPkg = pkgs.python3Packages.buildPythonPackage {
      pname   = "webrtc";
      version = "0.0.1";
      # Point this at the folder that contains package.xml, setup.py, resource/, launch/, and the Python pkg dir `webrtc/`
      src     = webrtcSrc;

      format  = "setuptools";

      dontUseCmakeConfigure = true;
      dontUseCmakeBuild     = true;
      dontUseCmakeInstall   = true;
      dontWrapPythonPrograms = true;

      nativeBuildInputs = [
        pkgs.python3Packages.setuptools
      ];

      # Python/ROS runtime deps your node imports (expand as needed)
      propagatedBuildInputs = with rosPkgs; [
        rclpy
        launch
        launch-ros
        ament-index-python
        composition-interfaces
      ] ++ [
        pkgs.python3Packages.pyyaml
      ];

      # After the Python install, add the ROS "ament index" marker, share files, and the libexec shim
      postInstall = ''
        set -euo pipefail

        # 1: ament index registration
        mkdir -p $out/share/ament_index/resource_index/packages
        echo webrtc > $out/share/ament_index/resource_index/packages/webrtc

        # 2: package share (package.xml + launch)
        mkdir -p $out/share/webrtc/
        cp ${webrtcSrc}/package.xml $out/share/webrtc/
        cp ${webrtcSrc}/webrtc.launch.py $out/share/webrtc

        # If you keep a resource marker, install it too (recommended)
        if [ -f ${webrtcSrc}/resource/webrtc ]; then
          install -Dm644 ${webrtcSrc}/resource/webrtc $out/share/webrtc/resource
        fi

        # 3: libexec shim so launch_ros finds the executable under lib/webrtc/webrtc_node
        mkdir -p $out/lib/webrtc
        cat > $out/lib/webrtc/webrtc_node <<'EOF'
#!${pkgs.bash}/bin/bash
exec ${pkgs.python3}/bin/python3 -m webrtc.node "$@"
EOF
        chmod +x $out/lib/webrtc/webrtc_node
    '';
    };
  in
  {
    # Export packages
    packages.${system} = {
      webrtcPkg = webrtcPkg;
    };

    # Full NixOS config for Pi 4 (sd-image)
    nixosConfigurations.rpi4 = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = {
        inherit webrtcPkg webrtcEnv pyEnv;
      };
      modules = [
        ({ ... }: {
          nixpkgs.overlays = [
            nix-ros-overlay.overlays.default
            pinPython312
          ];
        })
        ./configuration.nix
      ];
    };
  };
}
