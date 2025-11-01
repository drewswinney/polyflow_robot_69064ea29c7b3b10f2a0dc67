{ config, pkgs, lib, webrtcPkg, pyEnv, webrtcEnv, ... }:

let
  user      = "admin";
  password  = "password";
  hostname  = "69064ea29c7b3b10f2a0dc67";
  homeDir   = "/home/${user}";

  py  = pkgs.python3;   # pinned to 3.12 by flake overlay

  rosPkgs = pkgs.rosPackages.humble;
  ros2pkg = rosPkgs.ros2pkg;
  ros2cli = rosPkgs.ros2cli;
  ros2launch = rosPkgs.ros2launch;
  launch = rosPkgs.launch;
  launch-ros = rosPkgs.launch-ros;
  rclpy = rosPkgs.rclpy;
  ament-index-python = rosPkgs.ament-index-python;
  rosidl-parser = rosPkgs.rosidl-parser;
  rosidl-runtime-py = rosPkgs.rosidl-runtime-py;
  composition-interfaces = rosPkgs.composition-interfaces;
  osrf-pycommon = rosPkgs.osrf-pycommon;
  rpyutils = rosPkgs.rpyutils;
  rcl-interfaces = rosPkgs.rcl-interfaces;
  builtin-interfaces = rosPkgs.builtin-interfaces;
  rmwImplementation = rosPkgs."rmw-implementation";
  rmwCycloneDDS = rosPkgs."rmw-cyclonedds-cpp";
  rmwDdsCommon = rosPkgs."rmw-dds-common";
  rosidlTypesupportCpp = rosPkgs."rosidl-typesupport-cpp";
  rosidlTypesupportC = rosPkgs."rosidl-typesupport-c";
  rosidlTypesupportIntrospectionCpp = rosPkgs."rosidl-typesupport-introspection-cpp";
  rosidlTypesupportIntrospectionC = rosPkgs."rosidl-typesupport-introspection-c";
  rosidlGeneratorPy = rosPkgs."rosidl-generator-py";
  yaml = pkgs.python3Packages."pyyaml";
  empy = pkgs.python3Packages."empy";
  catkin-pkg = pkgs.python3Packages."catkin-pkg";
  rosgraphMsgs = rosPkgs."rosgraph-msgs";
  stdMsgs = rosPkgs."std-msgs";

  rosRuntimePackages = [
    ros2pkg
    ros2cli
    ros2launch
    launch
    launch-ros
    rclpy
    ament-index-python
    rosidl-parser
    rosidl-runtime-py
    composition-interfaces
    osrf-pycommon
    rpyutils
    builtin-interfaces
    rcl-interfaces
    rmwImplementation
    rmwCycloneDDS
    rmwDdsCommon
    rosidlTypesupportCpp
    rosidlTypesupportC
    rosidlTypesupportIntrospectionCpp
    rosidlTypesupportIntrospectionC
    rosidlGeneratorPy
    rosgraphMsgs
    stdMsgs
    yaml
  ];

  pythonRoots = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  pythonPath = lib.makeSearchPath "lib/python${py.pythonVersion}/site-packages" pythonRoots;

  amentRoots = rosRuntimePackages ++ [ webrtcPkg ];
  amentPrefixPath = lib.concatStringsSep ":" (map (pkg: "${pkg}") amentRoots);

  webrtcRuntimeInputs = rosRuntimePackages ++ [ pyEnv webrtcEnv webrtcPkg ];
  runtimePrefixes = lib.concatStringsSep " " (map (pkg: "${pkg}") webrtcRuntimeInputs);
  libraryPath = lib.makeLibraryPath webrtcRuntimeInputs;

  webrtcLauncher = pkgs.writeShellApplication {
    name = "webrtc-launch";
    runtimeInputs = webrtcRuntimeInputs;
    text = ''
      set -eo pipefail

      # Guard PATH/PYTHONPATH before enabling nounset; systemd often runs with them unset.
      PATH="''${PATH-}"
      PYTHONPATH="''${PYTHONPATH-}"
      AMENT_PREFIX_PATH="''${AMENT_PREFIX_PATH-}"
      LD_LIBRARY_PATH="''${LD_LIBRARY_PATH-}"
      if [ -z "''${RMW_IMPLEMENTATION-}" ]; then
        RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
      fi
      export RMW_IMPLEMENTATION

      set -u
      shopt -s nullglob

      PYTHONPATH_BASE="${pythonPath}"
      if [ -n "$PYTHONPATH_BASE" ]; then
        PYTHONPATH="$PYTHONPATH_BASE''${PYTHONPATH:+:}''${PYTHONPATH}"
      fi

      AMENT_PREFIX_BASE="${amentPrefixPath}"
      if [ -n "$AMENT_PREFIX_BASE" ]; then
        AMENT_PREFIX_PATH="$AMENT_PREFIX_BASE''${AMENT_PREFIX_PATH:+:}''${AMENT_PREFIX_PATH}"
      fi

      LIBRARY_PATH_BASE="${libraryPath}"
      if [ -n "$LIBRARY_PATH_BASE" ]; then
        LD_LIBRARY_PATH="$LIBRARY_PATH_BASE''${LD_LIBRARY_PATH:+:}''${LD_LIBRARY_PATH}"
      fi

      export PYTHONPATH
      export AMENT_PREFIX_PATH
      export LD_LIBRARY_PATH

      # Local setup scripts expect AMENT_TRACE_SETUP_FILES to be unset when absent.
      set +u
      for prefix in ${runtimePrefixes}; do
        for script in "$prefix"/setup.bash "$prefix"/local_setup.bash \
                      "$prefix"/install/setup.bash "$prefix"/install/local_setup.bash \
                      "$prefix"/share/*/local_setup.bash "$prefix"/share/*/setup.bash; do
          if [ -f "$script" ]; then
            echo "[INFO] Sourcing $script" >&2
            # shellcheck disable=SC1090
            . "$script"
          fi
        done
      done
      set -u

      exec ros2 launch webrtc webrtc.launch.py
    '';
  };
in
{
  ##############################################################################
  # Hardware / boot
  ##############################################################################
  nixpkgs.overlays = [
    (final: super: {
      makeModulesClosure = x:
        super.makeModulesClosure (x // { allowMissing = true; });
    })
  ];

  imports = [
    "${builtins.fetchGit {
      url = "https://github.com/NixOS/nixos-hardware.git";
      rev = "26ed7a0d4b8741fe1ef1ee6fa64453ca056ce113";
    }}/raspberry-pi/4"
  ];

  boot = {
    # Default kernel is fine; swap if you need rpi4-specific later.
    initrd.availableKernelModules = [ "xhci_pci" "usbhid" "usb_storage" ];
    loader = {
      grub.enable = false;
      generic-extlinux-compatible.enable = true;
    };
  };

  fileSystems."/" = {
    device = lib.mkDefault "/dev/disk/by-label/NIXOS_SD";
    fsType = "ext4";
    options = [ "noatime" ];
  };

  ##############################################################################
  # System basics
  ##############################################################################
  system.autoUpgrade.flags = [ "--max-jobs" "1" "--cores" "1" ];

  networking = {
    hostName = hostname;
    networkmanager.enable = true;
    nftables.enable = true;
  };

  services.openssh.enable = true;
  services.timesyncd.enable = lib.mkDefault true;
  services.timesyncd.servers = [ "pool.ntp.org" ];
  systemd.additionalUpstreamSystemUnits = [ "systemd-time-wait-sync.service" ];
  systemd.services.systemd-time-wait-sync.wantedBy = [ "multi-user.target" ];

  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  hardware.enableRedistributableFirmware = true;
  system.stateVersion = "23.11";

  # Optional: keep a copy of this file on the device
  environment.etc."nixos/configuration.nix" = {
    source = ./configuration.nix;
    mode = "0644";
  };

  ##############################################################################
  # Users
  ##############################################################################
  users.mutableUsers = false;
  users.users.${user} = {
    isNormalUser = true;
    password = password;
    extraGroups = [ "wheel" ];
    home = homeDir;
  };
  security.sudo.wheelNeedsPassword = false;

  ##############################################################################
  # Packages
  ##############################################################################
  environment.systemPackages =
    (with pkgs; [ git python3 ]) ++
    (with rosPkgs; [ ros2cli ros2launch ros2pkg launch launch-ros ament-index-python ros-base ]) ++
    [ webrtcPkg pyEnv ];

  ##############################################################################
  # Services
  ##############################################################################
  systemd.services.polyflow-webrtc = {
    description = "Run Polyflow WebRTC launch with ros2 launch";
    wantedBy = [ "multi-user.target" ];
    after    = [ "network-online.target" ];
    wants    = [ "network-online.target" ];

    environment = {
      ROS_DOMAIN_ID = "0";
      LANG = "en_US.UTF-8";
      LC_ALL = "en_US.UTF-8";
    };

    serviceConfig = {
      User             = user;
      Group            = "users";
      WorkingDirectory = homeDir;
      StateDirectory   = "polyflow";
      StandardOutput   = "journal";
      StandardError    = "journal";
      Restart          = "always";
      RestartSec       = "3s";
      ExecStart        = "${webrtcLauncher}/bin/webrtc-launch";
    };
  };
}
