#!/usr/bin/env bash

set -e

REAL_USER=$(logname 2>/dev/null || echo $USER)
TARGET_DIR="/home/$REAL_USER/.config/nixos"

echo "⚙️ Разворачиваем полный, автономный NixOS/Hyprland сетап из коробки..."

# 1. Подготовка каталогов и прав
sudo mkdir -p "$TARGET_DIR/system" "$TARGET_DIR/home"
sudo chown -R $REAL_USER:users "$TARGET_DIR"

# 2. Проверка и копирование hardware-configuration.nix
if [ -f /etc/nixos/hardware-configuration.nix ]; then
    cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/system/hardware-configuration.nix"
else
    echo "❌ Ошибка: /etc/nixos/hardware-configuration.nix не найден в /etc/nixos!"
    exit 1
fi

# 3. Flake.nix
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

# 4. Настройка Nvidia RTX 5070M + AMD PRIME
# 5. Системный конфигуратор (SDDM, Pipewire, Zsh, Fonts, Nix Optimizations)
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

  # Шрифты
  fonts.packages = with pkgs; [
    nerd-fonts.jetbrains-mono
    nerd-fonts.fira-code
    font-awesome
    noto-fonts
    noto-fonts-emoji
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

# 6. Конфигурация Kitty Terminal
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

# 7. Конфигурация Fuzzel (App Launcher)
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

# 8. Конфигурация SwayNC (Центр уведомлений)
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

# 9. Настройки Hyprland (Полные бинды, правила окон, горячие клавиши)
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

# 10. Конфигурация Waybar
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

# 11. Home Manager (Основные приложения пользователя + ИСПРАВЛЕН KDEPACKAGES.DOLPHIN)
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
    kdePackages.dolphin # Исправленный путь к Dolphin в nixpkgs-unstable
    
    # Железо и доп утилиты
    ryzenadj
    appimage-run
    papirus-icon-theme
  ];

  # Темы GTK и курсора
  gtk = {
    enable = true;
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

  programs.git = {
    enable = true;
    userName = "$REAL_USER";
    userEmail = "$REAL_USER@local";
  };

  programs.home-manager.enable = true;
  home.stateVersion = "24.11";
}
EOF

# 12. Передача прав
sudo chown -R $REAL_USER:users "$TARGET_DIR"

cd "$TARGET_DIR"

# 13. Инициализация локального Git-репозитория и сборка
echo "📦 Индексация всех конфигов в Git..."
nix-shell -p git --run "git init && git config user.name '$REAL_USER' && git config user.email '$REAL_USER@local' && git add -A"

echo "🚀 Запуск локальной сборки NixOS из коробки..."
sudo nix-shell -p git --run "NIX_CONFIG='experimental-features = nix-command flakes' nixos-rebuild switch --flake .#mechrevo"

echo "✅ Все собранное окружение готово без ошибок! Выполни: sudo reboot"
