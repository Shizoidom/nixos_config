#!/usr/bin/env bash

set -e

# Определение пользователя и путей
REAL_USER=$(logname 2>/dev/null || echo $USER)
TARGET_DIR="/home/$REAL_USER/.config/nixos"

echo "🚀 Запуск полной автонастройки NixOS для $REAL_USER..."

# Создаем директорию конфига
mkdir -p "$TARGET_DIR/system"
mkdir -p "$TARGET_DIR/home"

# 1. Забираем реальный hardware-configuration
if [ -f /etc/nixos/hardware-configuration.nix ]; then
    cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/system/hardware-configuration.nix"
    echo "✅ Скопирован /etc/nixos/hardware-configuration.nix"
else
    echo "❌ Ошибка: /etc/nixos/hardware-configuration.nix не найден!"
    exit 1
fi

# 2. Создаем flake.nix
cat <<EOF > "$TARGET_DIR/flake.nix"
{
  description = "Adult Reproducible Hyprland Setup for Mechrevo Jiaolong 16 Pro";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, home-manager, ... }@inputs: {
    nixosConfigurations.mechrevo = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./system/hardware-configuration.nix
        ./system/configuration.nix
        ./system/nvidia.nix

        home-manager.nixosModules.home-manager
        {
          home-manager.useGlobalPkgs = true;
          home-manager.useUserPackages = true;
          home-manager.users.$REAL_USER = import ./home/home.nix;
        }
      ];
    };
  };
}
EOF

# 3. Создаем system/nvidia.nix (RTX 5070M + Ryzen 9 7945HX)
cat <<EOF > "$TARGET_DIR/system/nvidia.nix"
{ config, pkgs, ... }:

{
  hardware.graphics = {
    enable = true;
    enable32Bit = true;
  };

  services.xserver.videoDrivers = [ "nvidia" ];

  hardware.nvidia = {
    modesetting.enable = true;
    powerManagement.enable = true;
    powerManagement.finegrained = true;
    open = true;
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.stable;

    prime = {
      offload = {
        enable = true;
        enableOffloadCmd = true;
      };
      amdgpuBusId = "PCI:75:0:0";
      nvidiaBusId = "PCI:1:0:0";
    };
  };

  environment.sessionVariables = {
    LIBVA_DRIVER_NAME = "nvidia";
    GBM_BACKEND = "nvidia-drm";
    __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    NIXOS_OZONE_WL = "1";
    ELECTRON_OZONE_PLATFORM_HINT = "auto";
  };
}
EOF

# 4. Создаем system/configuration.nix
cat <<EOF > "$TARGET_DIR/system/configuration.nix"
{ pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  networking.hostName = "mechrevo";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  services.power-profiles-daemon.enable = true;

  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  users.users.$REAL_USER = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;
  };

  programs.zsh.enable = true;
  system.stateVersion = "24.11";
}
EOF

# 5. Создаем home/hyprland.nix (Два монитора + Стиль)
cat <<EOF > "$TARGET_DIR/home/hyprland.nix"
{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;
    extraConfig = ''
      # --- ДВА МОНИТОРА ---
      monitor = eDP-1, 2560x1600@240, 0x0, 1.25
      monitor = , preferred, auto-right, 1

      workspace = 1, monitor:eDP-1, default:true
      workspace = 2, monitor:eDP-1
      workspace = 3, monitor:eDP-1
      workspace = 4, monitor:eDP-1
      
      workspace = 5, default:true
      workspace = 6
      workspace = 7

      exec-once = waybar
      exec-once = swaync

      # --- ВЗРОСЛЫЙ СТИЛЬ ---
      general {
          gaps_in = 4
          gaps_out = 8
          border_size = 1
          col.active_border = rgba(89b4faee) rgba(b4befeee) 45deg
          col.inactive_border = rgba(313244aa)
          layout = dwindle
      }

      decoration {
          rounding = 6
          blur {
              enabled = true
              size = 5
              passes = 2
          }
          drop_shadow = yes
          shadow_range = 10
          col.shadow = rgba(1a1a1aee)
      }

      animations {
          enabled = yes
          bezier = easeOutQuint, 0.23, 1, 0.32, 1
          animation = windows, 1, 3, easeOutQuint
          animation = workspaces, 1, 3, default, slide
      }

      \$mainMod = SUPER
      bind = \$mainMod, RETURN, exec, kitty
      bind = \$mainMod, Q, killactive,
      bind = \$mainMod, E, exec, dolphin
      bind = \$mainMod, SPACE, exec, fuzzel
      bind = \$mainMod, F, togglefloating,

      bind = \$mainMod, h, movefocus, l
      bind = \$mainMod, l, movefocus, r
      bind = \$mainMod, k, movefocus, u
      bind = \$mainMod, j, movefocus, d

      bind = \$mainMod, 1, workspace, 1
      bind = \$mainMod, 2, workspace, 2
      bind = \$mainMod, 3, workspace, 3
      bind = \$mainMod, 4, workspace, 4
      bind = \$mainMod, 5, workspace, 5
      bind = \$mainMod, 6, workspace, 6
    '';
  };
}
EOF

# 6. Создаем home/home.nix
cat <<EOF > "$TARGET_DIR/home/home.nix"
{ pkgs, ... }:

{
  imports = [ ./hyprland.nix ];

  home.username = "$REAL_USER";
  home.homeDirectory = "/home/$REAL_USER";

  home.packages = with pkgs; [
    kitty
    fuzzel
    waybar
    swaync
    fastfetch
    git
    vscode
    firefox
    ryzenadj
  ];

  programs.home-manager.enable = true;
  home.stateVersion = "24.11";
}
EOF

# Выставляем права владельца
chown -R $REAL_USER:users "$TARGET_DIR"

# Инициализируем Git для Nix Flakes
cd "$TARGET_DIR"
git init
git config user.name "$REAL_USER" || true
git config user.email "$REAL_USER@local" || true
git add .

echo "⚙️ Запуск билда и установки NixOS..."
sudo nixos-rebuild switch --flake .#mechrevo --extra-experimental-features 'nix-command flakes'

echo "🔥 ВСЁ ГОТОВО! Перезагрузись и заходи в Hyprland."