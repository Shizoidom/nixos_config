#!/usr/bin/env bash

set -e

# Автоопределение реального пользователя (даже при запуске через sudo)
REAL_USER=${SUDO_USER:-$(logname 2>/dev/null || echo $USER)}
USER_GROUP=$(id -gn "$REAL_USER" 2>/dev/null || echo "users")
TARGET_DIR="/home/$REAL_USER/.config/nixos"

if [ "$REAL_USER" = "root" ]; then
    echo "❌ Ошибка: Скрипт не должен запускаться от имени чистого root без SUDO_USER!"
    exit 1
fi

echo "⚙️ Запуск развертывания NixOS/Hyprland для пользователя: $REAL_USER ($TARGET_DIR)..."

# ==============================================================================
# 1. Подготовка каталогов и прав
# ==============================================================================
echo "📂 [1/13] Создание структуры каталогов..."
mkdir -p "$TARGET_DIR/system" "$TARGET_DIR/home"
chown -R "$REAL_USER:$USER_GROUP" "$TARGET_DIR"

# ==============================================================================
# 2. Проверка и копирование hardware-configuration.nix
# ==============================================================================
echo "🖥️ [2/13] Проверка hardware-configuration.nix..."
if [ -f /etc/nixos/hardware-configuration.nix ]; then
    cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/system/hardware-configuration.nix"
else
    echo "❌ Ошибка: /etc/nixos/hardware-configuration.nix не найден!"
    exit 1
fi

# ==============================================================================
# 3. Flake.nix
# ==============================================================================
echo "❄️ [3/13] Генерация flake.nix..."
cat <<EOF > "$TARGET_DIR/flake.nix"
{
  description = "Complete Dotfiles and NixOS Config for Mechrevo";

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

# ==============================================================================
# 4. Настройка Nvidia RTX 5070M + AMD PRIME
# ==============================================================================
echo "🎮 [4/13] Генерация system/nvidia.nix..."
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

# ==============================================================================
# 5. Системный конфигуратор (SDDM, Pipewire, Zsh, Fonts, Nix Optimizations)
# ==============================================================================
echo "⚙️ [5/13] Генерация system/configuration.nix..."
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

  # SDDM Display Manager
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };

  programs.hyprland = {
    enable = true;
    xwayland.enable = true;
  };

  # Звук и Bluetooth
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    jack.enable = true;
  };

  hardware.bluetooth.enable = true;
  services.blueman.enable = true;

  services.power-profiles-daemon.enable = true;

  # Шрифты (актуализированный пакет эмодзи)
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    font-awesome
    noto-fonts
    noto-fonts-color-emoji
  ];

  programs.zsh.enable = true;

  environment.systemPackages = with pkgs; [
    git
    curl
    wget
    neovim
    clash-verge-rev
    pavucontrol
    brightnessctl
    playerctl
    pamixer
    wl-clipboard
  ];

  users.users.$REAL_USER = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
    shell = pkgs.zsh;
  };

  system.stateVersion = "24.11";
}
EOF

# ==============================================================================
# 6. Конфигурация Kitty Terminal
# ==============================================================================
echo "💻 [6/13] Генерация home/kitty.nix..."
cat <<EOF > "$TARGET_DIR/home/kitty.nix"
{ pkgs, ... }:

{
  programs.kitty = {
    enable = true;
    settings = {
      font_family = "JetBrainsMono Nerd Font";
      font_size = 11.0;
      window_padding_width = 10;
      background_opacity = "0.90";
      confirm_os_window_close = 0;
      
      # Catppuccin Mocha Colors
      foreground = "#cdd6f4";
      background = "#1e1e2e";
      selection_foreground = "#1e1e2e";
      selection_background = "#f5e0dc";
      cursor = "#f5e0dc";
      cursor_text_color = "#1e1e2e";
      
      active_border_color = "#b4befe";
      inactive_border_color = "#6c7086";
      bell_border_color = "#f38ba8";
      
      color0 = "#45475a";
      color8 = "#585b70";
      color1 = "#f38ba8";
      color9 = "#f38ba8";
      color2 = "#a6e3a1";
      color10 = "#a6e3a1";
      color3 = "#f9e2af";
      color11 = "#f9e2af";
      color4 = "#89b4fa";
      color12 = "#89b4fa";
      color5 = "#f5c2e7";
      color13 = "#f5c2e7";
      color6 = "#94e2d5";
      color14 = "#94e2d5";
      color7 = "#bac2de";
      color15 = "#a6adc8";
    };
  };
}
EOF

# ==============================================================================
# 7. Конфигурация Fuzzel (App Launcher)
# ==============================================================================
echo "🔍 [7/13] Генерация home/fuzzel.nix..."
cat <<EOF > "$TARGET_DIR/home/fuzzel.nix"
{ pkgs, ... }:

{
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        font = "JetBrainsMono Nerd Font:size=11";
        prompt = "❯ ";
        terminal = "kitty";
        icon-theme = "Papirus-Dark";
        width = 40;
        lines = 10;
        horizontal-pad = 20;
        vertical-pad = 10;
        inner-pad = 8;
      };
      colors = {
        background = "1e1e2edd";
        text = "cdd6f4ff";
        match = "cba6f7ff";
        selection = "313244ff";
        selection-text = "cdd6f4ff";
        selection-match = "cba6f7ff";
        border = "cba6f7ff";
      };
      border = {
        width = 2;
        radius = 10;
      };
    };
  };
}
EOF

# ==============================================================================
# 8. Конфигурация SwayNC (Центр уведомлений)
# ==============================================================================
echo "🔔 [8/13] Генерация home/swaync.nix..."
cat <<EOF > "$TARGET_DIR/home/swaync.nix"
{ pkgs, ... }:

{
  services.swaync = {
    enable = true;
    style = ''
      * {
        font-family: "JetBrainsMono Nerd Font";
        font-size: 13px;
      }
      .notification-row {
        outline: none;
      }
      .notification {
        border-radius: 12px;
        margin: 6px;
        background-color: #1e1e2e;
        border: 1px solid #313244;
        color: #cdd6f4;
      }
      .notification-content {
        background: transparent;
        padding: 10px;
      }
      .close-button {
        background: #f38ba8;
        color: #11111b;
        text-shadow: none;
        border-radius: 100%;
        margin: 5px;
        padding: 2px;
      }
    '';
  };
}
EOF

# ==============================================================================
# 9. Настройки Hyprland
# ==============================================================================
echo "🖼️ [9/13] Генерация home/hyprland.nix..."
cat <<EOF > "$TARGET_DIR/home/hyprland.nix"
{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;

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
      exec-once = clash-verge-rev

      env = XCURSOR_SIZE,24
      env = HYPRCURSOR_SIZE,24

      misc {
          disable_hyprland_logo = true
          force_default_wallpaper = 0
          background_color = 0x11111b
          vfr = true
      }

      general {
          gaps_in = 4
          gaps_out = 8
          border_size = 2
          col.active_border = rgba(cba6f7ee) rgba(89b4faee) 45deg
          col.inactive_border = rgba(313244aa)
          layout = dwindle
      }

      decoration {
          rounding = 10
          blur {
              enabled = true
              size = 6
              passes = 3
              new_optimizations = true
              ignore_opacity = true
          }
          shadow {
              enabled = true
              range = 15
              render_power = 3
              color = rgba(1a1a1aee)
          }
      }

      animations {
          enabled = yes
          bezier = easeOutQuint, 0.23, 1, 0.32, 1
          bezier = smoothOut, 0.36, 0, 0.66, -0.56
          bezier = smoothIn, 0.25, 1, 0.5, 1

          animation = windows, 1, 4, easeOutQuint
          animation = windowsOut, 1, 3, smoothOut, popin 80%
          animation = workspaces, 1, 3, default, slide
      }

      dwindle {
          pseudotile = true
          preserve_split = true
      }

      # Правила для плавающих окон
      windowrulev2 = float, class:^(pavucontrol)$
      windowrulev2 = float, class:^(blueman-manager)$
      windowrulev2 = float, class:^(clash-verge)$
      windowrulev2 = float, class:^(org.kde.dolphin)$,title:^(Progress Dialog.*)$

      \$mainMod = SUPER

      # Основные хоткеи
      bind = \$mainMod, RETURN, exec, kitty
      bind = \$mainMod, Q, killactive,
      bind = \$mainMod, E, exec, dolphin
      bind = \$mainMod, SPACE, exec, fuzzel
      bind = \$mainMod, F, togglefloating,
      bind = \$mainMod, M, fullscreen, 1
      bind = \$mainMod SHIFT, M, fullscreen, 0
      bind = \$mainMod, N, exec, swaync-client -t -sw

      # Скриншоты
      bind = , PRINT, exec, grim -g "\$(slurp)" - | wl-copy

      # Мультимедиа и яркость
      binde = , XF86AudioRaiseVolume, exec, pamixer -i 5
      binde = , XF86AudioLowerVolume, exec, pamixer -d 5
      bind = , XF86AudioMute, exec, pamixer -t
      binde = , XF86MonBrightnessUp, exec, brightnessctl set +5%
      binde = , XF86MonBrightnessDown, exec, brightnessctl set 5%-

      # Навигация по окнам (Vim-style)
      bind = \$mainMod, h, movefocus, l
      bind = \$mainMod, l, movefocus, r
      bind = \$mainMod, k, movefocus, u
      bind = \$mainMod, j, movefocus, d

      # Переключение воркспейсов
      bind = \$mainMod, 1, workspace, 1
      bind = \$mainMod, 2, workspace, 2
      bind = \$mainMod, 3, workspace, 3
      bind = \$mainMod, 4, workspace, 4
      bind = \$mainMod, 5, workspace, 5
      bind = \$mainMod, 6, workspace, 6
      bind = \$mainMod, 7, workspace, 7

      # Перемещение окон на воркспейсы
      bind = \$mainMod SHIFT, 1, movetoworkspace, 1
      bind = \$mainMod SHIFT, 2, movetoworkspace, 2
      bind = \$mainMod SHIFT, 3, movetoworkspace, 3
      bind = \$mainMod SHIFT, 4, movetoworkspace, 4
      bind = \$mainMod SHIFT, 5, movetoworkspace, 5

      # Изменение размеров и перемещение мышью
      bindm = \$mainMod, mouse:272, movewindow
      bindm = \$mainMod, mouse:273, resizewindow
    '';
  };
}
EOF

# ==============================================================================
# 10. Конфигурация Waybar
# ==============================================================================
echo "📊 [10/13] Генерация home/waybar.nix..."
cat <<EOF > "$TARGET_DIR/home/waybar.nix"
{ pkgs, ... }:

{
  programs.waybar = {
    enable = true;
    settings = [{
      layer = "top";
      position = "top";
      height = 34;
      margin-top = 6;
      margin-left = 10;
      margin-right = 10;

      modules-left = [ "hyprland/workspaces" "hyprland/window" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "cpu" "memory" "temperature" "network" "battery" "tray" ];

      "hyprland/workspaces" = {
        disable-scroll = true;
        all-outputs = true;
        format = "{name}";
      };

      "hyprland/window" = {
        format = "👉 {title}";
        max-length = 30;
        separate-outputs = true;
      };

      "clock" = {
        format = " {:%H:%M  %d-%m-%Y}";
        tooltip-format = "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>";
      };

      "cpu" = {
        format = " {usage}%";
        interval = 2;
      };

      "memory" = {
        format = " {percentage}%";
        interval = 2;
      };

      "temperature" = {
        critical-threshold = 80;
        format = " {temperatureC}°C";
      };

      "network" = {
        format-wifi = " {signalStrength}%";
        format-ethernet = "🌐 Wired";
        format-disconnected = "⚠️ Off";
        tooltip-format = "{ifname} via {gwaddr}";
      };

      "pulseaudio" = {
        format = "{icon} {volume}%";
        format-muted = "🔇 Muted";
        format-icons = {
          default = [ "" "" "" ];
        };
        on-click = "pavucontrol";
      };

      "battery" = {
        format = "{icon} {capacity}%";
        format-icons = [ "" "" "" "" "" ];
      };

      "tray" = {
        icon-size = 16;
        spacing = 8;
      };
    }];

    style = ''
      * {
        border: none;
        border-radius: 0;
        font-family: "JetBrainsMono Nerd Font", Roboto, sans-serif;
        font-size: 13px;
        min-height: 0;
      }

      window#waybar {
        background-color: transparent;
        color: #cdd6f4;
      }

      #workspaces {
        background-color: #1e1e2e;
        border-radius: 10px;
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

      #window {
        background-color: #1e1e2e;
        padding: 4px 12px;
        border-radius: 10px;
        margin-left: 8px;
        border: 1px solid #313244;
        color: #b4befe;
      }

      #clock, #cpu, #memory, #temperature, #network, #pulseaudio, #battery, #tray {
        background-color: #1e1e2e;
        padding: 4px 12px;
        border-radius: 10px;
        margin-left: 6px;
        border: 1px solid #313244;
      }

      #clock { color: #89b4fa; }
      #cpu { color: #f38ba8; }
      #memory { color: #fab387; }
      #temperature { color: #f9e2af; }
      #network { color: #a6e3a1; }
      #pulseaudio { color: #f5c2e7; }
      #battery { color: #94e2d5; }
      #tray { padding: 0 10px; }
    '';
  };
}
EOF

# ==============================================================================
# 11. Home Manager (Основные приложения пользователя + Актуальный синтаксис)
# ==============================================================================
echo "🏠 [11/13] Генерация home/home.nix..."
cat <<EOF > "$TARGET_DIR/home/home.nix"
{ pkgs, ... }:

{
  imports = [
    ./hyprland.nix
    ./waybar.nix
    ./kitty.nix
    ./fuzzel.nix
    ./swaync.nix
  ];

  home.username = "$REAL_USER";
  home.homeDirectory = "/home/$REAL_USER";

  home.packages = with pkgs; [
    # Терминал и системные утилиты
    kitty
    fuzzel
    swaynotificationcenter
    fastfetch
    git
    htop
    grim
    slurp
    wl-clipboard
    
    # Приложения
    vscode
    firefox
    clash-verge-rev
    kdePackages.dolphin
    
    # Железо и доп утилиты
    ryzenadj
    appimage-run
    papirus-icon-theme
  ];

  # Темы GTK (Заглушен варнинг gtk4)
  gtk = {
    enable = true;
    gtk4.theme = null;
    theme = {
      name = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;
    shellAliases = {
      ll = "ls -la";
      rebuild = "sudo nixos-rebuild switch --flake $TARGET_DIR#mechrevo";
    };
  };

  # Обновленный синтаксис настроек Git (без варнингов)
  programs.git = {
    enable = true;
    settings = {
      user = {
        name = "$REAL_USER";
        email = "$REAL_USER@local";
      };
    };
  };

  programs.home-manager.enable = true;
  home.stateVersion = "24.11";
}
EOF

# ==============================================================================
# 12. Передача прав пользователю
# ==============================================================================
echo "🔑 [12/13] Настройка прав доступа для $REAL_USER..."
chown -R "$REAL_USER:$USER_GROUP" "$TARGET_DIR"

cd "$TARGET_DIR"

# ==============================================================================
# 13. Инициализация локального Git-репозитория и запуск сборки
# ==============================================================================
echo "📦 [13/13] Подготовка Git-репозитория и запуск nixos-rebuild..."

# Разрешаем root переходить в папку пользователя без ошибки dubious ownership
git config --global --add safe.directory "$TARGET_DIR" 2>/dev/null || true

# Создаем Git-репозиторий от имени обычного пользователя
su - "$REAL_USER" -c "cd '$TARGET_DIR' && git init 2>/dev/null || true"
su - "$REAL_USER" -c "cd '$TARGET_DIR' && git config user.name '$REAL_USER'"
su - "$REAL_USER" -c "cd '$TARGET_DIR' && git config user.email '$REAL_USER@local'"
su - "$REAL_USER" -c "cd '$TARGET_DIR' && git add -A"
su - "$REAL_USER" -c "cd '$TARGET_DIR' && git commit -m 'Automated nixos build setup' 2>/dev/null || true"

echo "🚀 Сборка системы NixOS..."
nixos-rebuild switch --flake "$TARGET_DIR#mechrevo"

echo "✅ Система успешно собрана! Выполни: sudo reboot"
