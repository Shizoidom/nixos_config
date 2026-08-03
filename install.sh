#!/usr/bin/env bash

set -e

REAL_USER=$(logname 2>/dev/null || echo $USER)
TARGET_DIR="/home/$REAL_USER/.config/nixos"

echo "⚙️ Разворачиваем строгий минималистичный NixOS/Hyprland сетап..."

# 1. Исправляем права на каталог с запасом под root/user
sudo mkdir -p "$TARGET_DIR/system" "$TARGET_DIR/home" "$TARGET_DIR/config/waybar"
sudo chown -R $REAL_USER:users "$TARGET_DIR"

# 2. Забираем hardware-configuration
if [ -f /etc/nixos/hardware-configuration.nix ]; then
    cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/system/hardware-configuration.nix"
else
    echo "❌ Ошибка: /etc/nixos/hardware-configuration.nix не найден!"
    exit 1
fi

# 3. Flake.nix
cat <<EOF > "$TARGET_DIR/flake.nix"
{
  description = "Minimalist Adult Hyprland Setup for Mechrevo";

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

# 4. Графика Nvidia RTX 5070M + AMD
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
    open = false;
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

# 5. Системный конфигуратор + SDDM + Шрифты + Настройки Nix
cat <<EOF > "$TARGET_DIR/system/configuration.nix"
{ pkgs, ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;

  nixpkgs.config.allowUnfree = true;

  nix.settings = {
    experimental-features = [ "nix-command" "flakes" ];
    max-jobs = "auto";
    max-substitution-jobs = 32;
    http-connections = 50;
    warn-dirty = false;
  };

  networking.hostName = "mechrevo";
  networking.networkmanager.enable = true;

  time.timeZone = "Europe/Moscow";
  i18n.defaultLocale = "ru_RU.UTF-8";

  # Дисплейный менеджер SDDM (загрузка сразу в графику без черных экранов)
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # Системные шрифты для иконок и красивого кода
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    font-awesome
  ];

  services.power-profiles-daemon.enable = true;
  security.rtkit.enable = true;
  
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    clash-verge-rev
    neovim
  ];

  users.users.$REAL_USER = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
    shell = pkgs.zsh;
  };

  system.stateVersion = "24.11";
}
EOF

# 6. Настройки Hyprland (Актуальный синтаксис 0.40+, без аниме, Catppuccin рамки)
cat <<EOF > "$TARGET_DIR/home/hyprland.nix"
{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang";

    extraConfig = ''
      monitor = eDP-1, 2560x1600@240, 0x0, 1.25
      monitor = , preferred, auto, 1.0

      workspace = 1, monitor:eDP-1, default:true
      workspace = 2, monitor:eDP-1
      workspace = 3, monitor:eDP-1
      workspace = 4, monitor:eDP-1
      workspace = 5, default:true
      workspace = 6
      workspace = 7

      exec-once = waybar
      exec-once = swaync

      misc {
          disable_hyprland_logo = true
          force_default_wallpaper = 0
          background_color = 0x11111b
      }

      general {
          gaps_in = 5
          gaps_out = 10
          border_size = 2
          col.active_border = rgba(cba6f7ee) rgba(89b4faee) 45deg
          col.inactive_border = rgba(313244aa)
          layout = dwindle
      }

      decoration {
          rounding = 8
          blur {
              enabled = true
              size = 6
              passes = 3
              new_optimizations = true
          }
          shadow {
              enabled = true
              range = 12
              render_power = 3
              color = rgba(1a1a1aee)
          }
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

# 7. Конфигурация Waybar (Стилизованная панель-капсула как на скриншоте)
cat <<EOF > "$TARGET_DIR/home/waybar.nix"
{ pkgs, ... }:

{
  programs.waybar = {
    enable = true;
    settings = [{
      layer = "top";
      position = "top";
      height = 32;
      margin-top = 6;
      margin-left = 10;
      margin-right = 10;

      modules-left = [ "hyprland/workspaces" ];
      modules-center = [ "clock" ];
      modules-right = [ "cpu" "memory" "temperature" "network" "battery" ];

      "hyprland/workspaces" = {
        disable-scroll = true;
        all-outputs = true;
        format = "{name}";
      };

      "clock" = {
        format = " {:%H:%M  %d-%m-%Y}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
      };

      "cpu" = {
        format = " {usage}%";
      };

      "memory" = {
        format = " {percentage}%";
      };

      "temperature" = {
        critical-threshold = 80;
        format = " {temperatureC}°C";
      };

      "network" = {
        format-wifi = " {signalStrength}%";
        format-ethernet = "🔌 Wired";
        format-disconnected = "⚠️ Disconnected";
      };

      "battery" = {
        format = "{icon} {capacity}%";
        format-icons = [ "" "" "" "" "" ];
      };
    }];

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "JetBrainsMono Nerd Font", Roboto, Helvetica, Arial, sans-serif;
        font-size: 13px;
        min-height: 0;
      }

      window#waybar {
        background-color: transparent;
        color: #cdd6f4;
      }

      #workspaces {
        background-color: #1e1e2e;
        border-radius: 12px;
        padding: 0 6px;
        border: 1px solid #313244;
      }

      #workspaces button {
        padding: 0 8px;
        color: #a6adc8;
      }

      #workspaces button.active {
        color: #cba6f7;
        font-weight: bold;
      }

      #clock, #cpu, #memory, #temperature, #network, #battery {
        background-color: #1e1e2e;
        padding: 4px 12px;
        border-radius: 12px;
        margin-left: 6px;
        border: 1px solid #313244;
      }

      #clock {
        color: #89b4fa;
      }

      #cpu { color: #f38ba8; }
      #memory { color: #fab387; }
      #temperature { color: #f9e2af; }
      #network { color: #a6e3a1; }
      #battery { color: #94e2d5; }
    '';
  };
}
EOF

# 8. Home Manager (Основные пакеты)
cat <<EOF > "$TARGET_DIR/home/home.nix"
{ pkgs, ... }:

{
  imports = [
    ./hyprland.nix
    ./waybar.nix
  ];

  home.username = "$REAL_USER";
  home.homeDirectory = "/home/$REAL_USER";

  home.packages = with pkgs; [
    kitty
    fuzzel
    swaynotificationcenter
    fastfetch
    git
    vscode
    firefox
    ryzenadj
    appimage-run
    clash-verge-rev
    dolphin
  ];

  programs.home-manager.enable = true;
  home.stateVersion = "24.11";
}
EOF

# 9. Финальное обновление прав
sudo chown -R $REAL_USER:users "$TARGET_DIR"

cd "$TARGET_DIR"

# 10. Инициализация Git и запуск сборки
echo "📦 Инициализируем локальный репозиторий Git..."
nix-shell -p git --run "git init && git config user.name '$REAL_USER' && git config user.email '$REAL_USER@local' && git add ."

echo "🚀 Пересобираем NixOS с новыми параметрами..."
sudo nix-shell -p git --run "NIX_CONFIG='experimental-features = nix-command flakes' nixos-rebuild switch --flake .#mechrevo"

echo "🔥 Сборка завершена идеально! Введен SDDM. Просто выполни 'sudo reboot'."
