#!/usr/bin/env bash

set -e

# ==============================================================================
# NixOS one-shot installer: Hyprland + гибернация (крышка) + GRUB dual boot
# (Windows на отдельном SSD) + NVIDIA RTX 5070M (open-модули Blackwell).
#
# Запуск:  curl -sSL https://raw.githubusercontent.com/Shizoidom/nixos_config/main/install.sh | sudo bash
# Аргументы: install.sh [username]   (по умолчанию: next)
# ==============================================================================

USERNAME="${1:-next}"

# Перезапуск через sudo, если запущено от обычного пользователя
[ "$(id -u)" -eq 0 ] || exec sudo bash "$0" "$@"

# Включаем flakes для первой сборки (до пересборки системы)
export NIX_CONFIG="experimental-features = nix-command flakes"

USER_GROUP=$(id -gn "$USERNAME" 2>/dev/null || echo "users")
TARGET_DIR="/home/$USERNAME/.config/nixos"

if [ "$USERNAME" = "root" ]; then
    echo "❌ Ошибка: имя пользователя не может быть root!"
    exit 1
fi

echo "⚙️ Запуск развертывания NixOS/Hyprland для пользователя: $USERNAME ($TARGET_DIR)..."

# ==============================================================================
# 1. Подготовка каталогов и прав
# ==============================================================================
echo "📂 [1/15] Создание структуры каталогов..."
mkdir -p "$TARGET_DIR/system" "$TARGET_DIR/home"
chown -R "$USERNAME:$USER_GROUP" "$TARGET_DIR"

# ==============================================================================
# 2. Проверка и копирование hardware-configuration.nix
# ==============================================================================
echo "🖥️ [2/15] Проверка hardware-configuration.nix..."
if [ -f /etc/nixos/hardware-configuration.nix ]; then
    cp /etc/nixos/hardware-configuration.nix "$TARGET_DIR/system/hardware-configuration.nix"
else
    echo "🖥️ hardware-configuration.nix не найден - генерируем заново..."
    nixos-generate-config --root / --dir "$TARGET_DIR/system" >/dev/null 2>&1 || {
        echo "❌ Ошибка: не удалось сгенерировать hardware-configuration.nix!"
        exit 1
    }
fi

# ==============================================================================
# 3. Flake.nix
# ==============================================================================
echo "❄️ [3/15] Генерация flake.nix..."
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
          home-manager.users.$USERNAME = import ./home/home.nix;
        }
      ];
    };
  };
}
EOF

# ==============================================================================
# 4. Настройка NVIDIA RTX 5070M (Blackwell - только open-модули ядра)
# ==============================================================================
echo "🎮 [4/15] Генерация system/nvidia.nix..."
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
    open = true; # RTX 50 series (Blackwell) работает ТОЛЬКО с open-модулями
    nvidiaSettings = true;
    package = config.boot.kernelPackages.nvidiaPackages.latest;
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
# 5. Hibernation: swap (готовый раздел или swapfile) + параметры resume
# ==============================================================================
echo "💾 [5/15] Настройка гибернации (ищем swap)..."

# Убираем swapfile от прошлого запуска (активный swap нельзя удалить - сначала swapoff)
if [ -f /var/lib/swapfile ]; then
    swapoff /var/lib/swapfile 2>/dev/null || true
    rm -f /var/lib/swapfile 2>/dev/null || echo "⚠️ Не удалось удалить старый /var/lib/swapfile"
fi

# Ищем существующий swap-раздел (например, созданный при установке NixOS)
SWAP_UUID=""
SWAP_NAME=""
while read -r NAME TYPE FSTYPE UUID; do
    [ -z "$NAME" ] && continue
    case "$NAME" in
        loop*|ram*|zram*|sr*|md*|dm-*) continue ;;
    esac
    if [ "$TYPE" = "part" ] && [ "$FSTYPE" = "swap" ]; then
        SWAP_NAME="$NAME"
        SWAP_UUID="$UUID"
    fi
done < <(lsblk -n -l -o NAME,TYPE,FSTYPE,UUID 2>/dev/null || true)

if [ -n "$SWAP_UUID" ]; then
    # Гибернация через swap-раздел: resume_offset не нужен, работает на любой ФС
    RESUME_DEV="/dev/disk/by-uuid/${SWAP_UUID}"
    RESUME_OFFSET_LINE=""
    echo "✅ Найден swap-раздел /dev/${SWAP_NAME} (UUID=${SWAP_UUID}) - используем его"
    if grep -qi "swap" "$TARGET_DIR/system/hardware-configuration.nix"; then
        SWAP_DEVICES_LINE="" # раздел уже описан в hardware-configuration.nix
    else
        SWAP_DEVICES_LINE="swapDevices = [ { device = \"/dev/disk/by-uuid/${SWAP_UUID}\"; } ];"
    fi
else
    # Swap-раздела нет - создаем swapfile размером с RAM
    echo "⚠️ Swap-раздел не найден - создаем swapfile размером с RAM..."
    MEM_KB=$(awk '/^MemTotal:/{print $2}' /proc/meminfo)
    SWAP_MB=$((MEM_KB / 1024))
    if ! fallocate -l "${SWAP_MB}M" /var/lib/swapfile 2>/dev/null; then
        dd if=/dev/zero of=/var/lib/swapfile bs=1M count="$SWAP_MB" status=progress
    fi
    chmod 600 /var/lib/swapfile
    mkswap /var/lib/swapfile >/dev/null
    swapon /var/lib/swapfile 2>/dev/null || true
    echo "✅ Swapfile: /var/lib/swapfile (${SWAP_MB} MB)"

    # Физическое смещение swapfile - нужно для resume после гибернации
    if command -v filefrag >/dev/null 2>&1; then
        OFFSET_BLOCK=$(filefrag -v /var/lib/swapfile | awk '/^[[:space:]]*0:/{split($3,p,".."); gsub(":","",p[1]); print p[1]; exit}')
    else
        echo "🔧 filefrag не найден - устанавливаем e2fsprogs..."
        OFFSET_BLOCK=$(nix-shell -p e2fsprogs --run "filefrag -v /var/lib/swapfile | awk '/^[[:space:]]*0:/{split(\$3,p,\"..\"); gsub(\":\",\"\",p[1]); print p[1]; exit}'")
    fi
    if [ -z "$OFFSET_BLOCK" ]; then
        echo "❌ Ошибка: не удалось определить смещение swapfile (для гибернации нужен ext4 root без снапшотов)!"
        exit 1
    fi
    RESUME_OFFSET=$((OFFSET_BLOCK * 4096))
    RESUME_DEV="/dev/disk/by-uuid/$(findmnt -no UUID /)"
    RESUME_OFFSET_LINE="boot.kernelParams = [ \"resume_offset=${RESUME_OFFSET}\" ];"
    SWAP_DEVICES_LINE="swapDevices = [ { device = \"/var/lib/swapfile\"; } ];"
    echo "✅ resume_offset=${RESUME_OFFSET}"
fi

if [ "$(findmnt -no FSTYPE /)" = "btrfs" ]; then
    echo "⚠️ Внимание: корневой раздел btrfs"
fi
echo "✅ Resume device: ${RESUME_DEV}"

# ==============================================================================
# 6. Системный конфигуратор (SDDM, Pipewire, Zsh, Fonts, Nix Optimizations,
#    GRUB dual boot, гибернация)
# ==============================================================================
echo "⚙️ [6/15] Генерация system/configuration.nix..."
cat <<EOF > "$TARGET_DIR/system/configuration.nix"
{ pkgs, ... }:

{
  # GRUB вместо systemd-boot - нужен для dual boot с Windows (os-prober)
  boot.loader.grub = {
    enable = true;
    device = "nodev"; # установка в EFI-раздел
    efiSupport = true;
    efiInstallAsRemovable = true; # нельзя вместе с canTouchEfiVariables
    useOSProber = true; # найдет Windows на втором SSD
  };

  # Гибернация: закрыл крышку -> RAM ушла в swap -> открыл -> все работает
  boot.resumeDevice = "$RESUME_DEV";
  $RESUME_OFFSET_LINE
  $SWAP_DEVICES_LINE

  # Гибернация по закрытию крышки (и от батареи, и от сети)
  services.logind = {
    lidSwitch = "hibernate";
    lidSwitchExternalPower = "hibernate";
  };

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

  # NVIDIA: фикс чёрного экрана на новых драйверах (Blackwell)
  boot.kernelParams = [ "nvidia_drm.fbdev=1" ];

  # SDDM Display Manager (X11 greeter: wayland-kwin + NVIDIA вешает экран после входа)
  services.xserver.enable = true; # X11 нужен для SDDM greeter (Hyprland останется Wayland-сессией)
  services.displayManager.sddm = {
    enable = true;
  };
  services.displayManager.defaultSession = "hyprland";

  # Русская раскладка (переключение RU/EN: Alt+Shift) - для X11/SDDM приложений
  services.xserver.xkb.layout = "us,ru";
  services.xserver.xkb.options = "grp:alt_shift_toggle";

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

  # Всегда производительный режим: CPU governor + турбо-профиль при загрузке
  powerManagement.cpuFreqGovernor = "performance";
  environment.systemPackages = with pkgs; [ ryzenadj ];

  # Профили питания (через ryzenadj TDP + nvidia-smi power limit):
  #   eco     - CPU 40W, GPU 30W
  #   balance - CPU 50W, GPU 80W
  #   turbo   - CPU 65W, GPU 115W
  # Переключение из waybar без пароля (NOPASSWD только для этих двух команд)
  security.sudo.extraRules = [
    {
      users = [ "$USERNAME" ];
      commands = [
        { command = "/run/current-system/sw/bin/ryzenadj"; options = [ "NOPASSWD" ]; }
        { command = "/run/current-system/sw/bin/nvidia-smi"; options = [ "NOPASSWD" ]; }
      ];
    }
  ];

  # Применяем турбо-профиль при каждой загрузке
  systemd.services.turbo-profile = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = [
        "${pkgs.ryzenadj}/bin/ryzenadj --stapm-limit=65000 --fast-limit=70000 --slow-limit=60000"
        "/run/current-system/sw/bin/nvidia-smi -pl 115"
      ];
    };
  };

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

  users.users.$USERNAME = {
    isNormalUser = true;
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" ];
    shell = pkgs.zsh;
  };

  system.stateVersion = "24.11";
}
EOF

# ==============================================================================
# 7. Конфигурация Kitty Terminal
# ==============================================================================
echo "💻 [7/15] Генерация home/kitty.nix..."
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
# 8. Конфигурация Fuzzel (App Launcher)
# ==============================================================================
echo "🔍 [8/15] Генерация home/fuzzel.nix..."
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
# 9. Конфигурация SwayNC (Центр уведомлений)
# ==============================================================================
echo "🔔 [9/15] Генерация home/swaync.nix..."
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
# 10. Настройки Hyprland
# ==============================================================================
echo "🖼️ [10/15] Генерация home/hyprland.nix..."
cat <<EOF > "$TARGET_DIR/home/hyprland.nix"
{ pkgs, ... }:

{
  wayland.windowManager.hyprland = {
    enable = true;
    configType = "hyprlang"; # legacy-формат конфига (иначе сломается extraConfig)
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
      exec-once = hyprpaper
      exec-once = nm-applet
      exec-once = blueman-applet
      exec-once = clash-verge-rev

      env = XCURSOR_SIZE,24
      env = HYPRCURSOR_SIZE,24

      # NVIDIA: обязательные env для Wayland-рендера
      env = LIBVA_DRIVER_NAME,nvidia
      env = GBM_BACKEND,nvidia-drm
      env = __GLX_VENDOR_LIBRARY_NAME,nvidia
      env = WLR_NO_HARDWARE_CURSORS,1
      env = QT_QPA_PLATFORM,wayland

      input {
          kb_layout = us,ru
          kb_options = grp:alt_shift_toggle
      }

      misc {
          disable_hyprland_logo = true
          force_default_wallpaper = 0
          background_color = 0x11111b
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
          preserve_split = true
      }

      # Плавающие окна (pavucontrol/blueman/clash) - в Hyprland 0.55+ windowrule
      # переведен на Lua (hl.window_rule), поэтому правила убраны до миграции.

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

  # Конфиг hyprpaper (обои) - сам файл обоев генерируется на шаге 12b
  home.file.".config/hypr/hyprpaper.conf" = {
    text = ''
      preload = /home/$USERNAME/Pictures/wallpaper.png
      wallpaper = , /home/$USERNAME/Pictures/wallpaper.png
    '';
  };
}
EOF

# ==============================================================================
# 11. Конфигурация Waybar
# ==============================================================================
echo "📊 [11/15] Генерация home/waybar.nix..."
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

      modules-left = [ "hyprland/workspaces" "hyprland/window" "custom/layout" "custom/caps" ];
      modules-center = [ "clock" ];
      modules-right = [ "pulseaudio" "cpu" "memory" "custom/cpu-temp" "custom/gpu-temp" "network" "battery" "tray" "custom/power-mode" "custom/power" ];

      "custom/power" = {
        format = "";
        on-click = "wlogout -b 5";
        tooltip = false;
      };

      # Индикатор текущей раскладки (клик - переключить RU/EN)
      "custom/layout" = {
        exec = "~/.local/bin/layout";
        on-click = "hyprctl switchxkblayout all next";
        interval = 2;
        tooltip = false;
      };

      # Индикатор Caps Lock
      "custom/caps" = {
        exec = "~/.local/bin/caps";
        interval = 2;
        tooltip = false;
      };

      # Режим питания (клик - меню eco/balance/turbo в fuzzel)
      "custom/power-mode" = {
        exec = "~/.local/bin/power-mode";
        on-click = "printf 'eco\nbalance\nturbo' | fuzzel --dmenu -p 'Mode: ' | xargs -r ~/.local/bin/power-mode-set";
        interval = 5;
        tooltip = false;
      };

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
        format = " {used:1}G / {total:0}G";
        interval = 2;
      };

      "custom/cpu-temp" = {
        exec = "~/.local/bin/cpu-temp";
        interval = 3;
        tooltip = false;
      };

      "custom/gpu-temp" = {
        exec = "~/.local/bin/gpu-temp";
        interval = 3;
        tooltip = false;
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

      #clock, #cpu, #memory, #custom-cpu-temp, #custom-gpu-temp, #network, #pulseaudio, #battery, #tray, #custom-power, #custom-layout, #custom-power-mode, #custom-caps {
        background-color: #1e1e2e;
        padding: 4px 12px;
        border-radius: 10px;
        margin-left: 6px;
        border: 1px solid #313244;
      }

      #clock { color: #89b4fa; }
      #cpu { color: #f38ba8; }
      #memory { color: #fab387; }
      #custom-cpu-temp { color: #f9e2af; }
      #custom-gpu-temp { color: #a6e3a1; }
      #network { color: #a6e3a1; }
      #pulseaudio { color: #f5c2e7; }
      #battery { color: #94e2d5; }
      #tray { padding: 0 10px; }
      #custom-power { color: #cba6f7; }
      #custom-layout { color: #b4befe; }
      #custom-power-mode { color: #a6e3a1; }
      #custom-caps { color: #f38ba8; }
    '';
  };

  # Скрипты для waybar: раскладка, режим питания
  home.file.".local/bin/layout" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      layout=\$(hyprctl devices -j | jq -r '.keyboards[] | select(.main == true) | .active_keymap' | head -n1)
      case \"\$layout\" in
        *Russian*) echo RU ;;
        *) echo EN ;;
      esac
    '';
  };

  # Индикатор Caps Lock
  home.file.".local/bin/caps" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      state=\$(hyprctl devices -j | jq -r '.keyboards[] | select(.main == true) | .capsLockState' 2>/dev/null | head -n1)
      [ \"\$state\" = \"true\" ] && echo \"\" || echo \"\"
    '';
  };

  # Текущий режим питания (определяем по фактическому лимиту GPU)
  home.file.".local/bin/power-mode" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      lim=\$(nvidia-smi --query-gpu=power.limit --format=csv,noheader 2>/dev/null | head -n1)
      lim=\${lim%%.*}
      case \"\$lim\" in
        115) echo \"\" ;;
        80) echo \"\" ;;
        30) echo \"\" ;;
        *) echo \"\" ;;
      esac
    '';
  };

  # Переключение режима питания: eco (40W/30W), balance (50W/80W), turbo (65W/115W)
  home.file.".local/bin/power-mode-set" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      case \"\$1\" in
        eco)
          sudo ryzenadj --stapm-limit=40000 --fast-limit=40000 --slow-limit=35000
          sudo nvidia-smi -pl 30
          ;;
        balance)
          sudo ryzenadj --stapm-limit=50000 --fast-limit=55000 --slow-limit=45000
          sudo nvidia-smi -pl 80
          ;;
        turbo)
          sudo ryzenadj --stapm-limit=65000 --fast-limit=70000 --slow-limit=60000
          sudo nvidia-smi -pl 115
          ;;
      esac
    '';
  };

  # Температура CPU (k10temp на AMD)
  home.file.".local/bin/cpu-temp" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      for h in /sys/class/hwmon/hwmon*; do
        name=\$(cat \"\$h/name\" 2>/dev/null)
        [ \"\$name\" = \"k10temp\" ] && { t=\$(cat \"\$h/temp1_input\"); echo \" \$(t/1000))°C\"; }
      done
    '';
  };

  # Температура GPU (hwmon драйвера nvidia)
  home.file.".local/bin/gpu-temp" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      for h in /sys/class/hwmon/hwmon*; do
        name=\$(cat \"\$h/name\" 2>/dev/null)
        [ \"\$name\" = \"nvidia\" ] && { t=\$(cat \"\$h/temp1_input\"); echo \" \$(t/1000))°C\"; }
      done
    '';
  };
}
EOF

# ==============================================================================
# 12. Home Manager (Основные приложения пользователя + Актуальный синтаксис)
# ==============================================================================
echo "🏠 [12/15] Генерация home/home.nix..."
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

  home.username = "$USERNAME";
  home.homeDirectory = "/home/$USERNAME";

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

    # Обои, системный трей (wifi/bluetooth) и шрифт с иконками
    hyprpaper
    networkmanagerapplet
    blueman
    nerd-fonts.jetbrains-mono

    # Настройки и меню питания
    pavucontrol
    wlogout
    hyprlock

    # Утилиты
    jq
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
        name = "$USERNAME";
        email = "$USERNAME@local";
      };
    };
  };

  # Меню выключения wlogout: lock / logout / reboot / shutdown / hibernate
  home.file.".config/wlogout/layout" = {
    text = ''
      {
          "label" : "lock",
          "action" : "hyprlock",
          "text" : "",
          "keybind" : "l"
      }
      {
          "label" : "logout",
          "action" : "hyprctl dispatch exit",
          "text" : "",
          "keybind" : "e"
      }
      {
          "label" : "reboot",
          "action" : "systemctl reboot",
          "text" : "",
          "keybind" : "r"
      }
      {
          "label" : "shutdown",
          "action" : "systemctl poweroff",
          "text" : "",
          "keybind" : "s"
      }
      {
          "label" : "hibernate",
          "action" : "systemctl hibernate",
          "text" : "",
          "keybind" : "h"
      }
    '';
  };

  home.file.".config/wlogout/style.css" = {
    text = ''
      * {
        font-family: "JetBrainsMono Nerd Font";
        font-size: 18px;
        color: #cdd6f4;
      }
      window {
        background-color: rgba(17, 17, 27, 0.85);
      }
      button {
        background-color: #1e1e2e;
        border: 2px solid #313244;
        border-radius: 12px;
        margin: 10px;
        padding: 20px;
      }
      button:hover {
        background-color: #313244;
        border-color: #cba6f7;
      }
      #lock { color: #89b4fa; }
      #logout { color: #f5c2e7; }
      #reboot { color: #f9e2af; }
      #shutdown { color: #f38ba8; }
      #hibernate { color: #94e2d5; }
    '';
  };

  programs.home-manager.enable = true;
  home.stateVersion = "24.11";
}
EOF

# ==============================================================================
# 12b. Генерация обоев Catppuccin (если файла еще нет)
# ==============================================================================
echo "🎨 [12b/15] Генерация обоев Catppuccin..."
mkdir -p /home/$USERNAME/Pictures
if [ ! -f /home/$USERNAME/Pictures/wallpaper.png ]; then
  nix-shell -p imagemagick --run "
    convert -size 3840x2160 xc:'#11111b' \
      -fill '#1e1e2e' -draw 'circle 3500,200 3500,2600' -blur 0x140 \
      -fill '#313244' -draw 'circle 400,1900 400,3600' -blur 0x180 \
      -fill '#1e1e2e' -draw 'circle 1900,1100 1900,3000' -blur 0x220 \
      -fill '#45475a' -draw 'circle 2900,1800 2900,2400' -blur 0x120 \
      -fill '#11111b' -draw 'circle 1500,300 1500,1600' -blur 0x100 \
      -blur 0x30 /home/$USERNAME/Pictures/wallpaper.png
  "
fi
chown "$USERNAME:$USER_GROUP" /home/$USERNAME/Pictures/wallpaper.png 2>/dev/null || true

# ==============================================================================
# 13. Передача прав пользователю
# ==============================================================================
echo "🔑 [13/15] Настройка прав доступа для $USERNAME..."
chown -R "$USERNAME:$USER_GROUP" "$TARGET_DIR"

# ==============================================================================
# 13b. Бэкап старых конфигов (чтобы home-manager не ругался на существующие файлы)
# ==============================================================================
echo "🗂 [13b/15] Резервное копирование существующих конфигов..."
for f in \
  /home/$USERNAME/.config/hypr/hyprpaper.conf \
  /home/$USERNAME/.config/hypr/hyprland.conf \
  /home/$USERNAME/.config/waybar/config \
  /home/$USERNAME/.config/gtk-3.0/settings.ini \
  /home/$USERNAME/.config/gtk-4.0/settings.ini \
  /home/$USERNAME/.gtkrc-2.0; do
  [ -f "$f" ] && mv "$f" "$f.bak" 2>/dev/null && echo "   backup: $f"
done
chown -R "$USERNAME:$USER_GROUP" /home/$USERNAME/.config 2>/dev/null || true

cd "$TARGET_DIR"

# ==============================================================================
# 14. Инициализация локального Git-репозитория и запуск сборки
# ==============================================================================
echo "📦 [14/15] Подготовка Git-репозитория и запуск nixos-rebuild..."

# Запускаем git через nix-shell -p git, чтобы не требовать заранее установленного git в системе
nix-shell -p git --run "
  git config --global --add safe.directory '$TARGET_DIR' 2>/dev/null || true
  sudo -u '$USERNAME' git -C '$TARGET_DIR' init 2>/dev/null || true
  sudo -u '$USERNAME' git -C '$TARGET_DIR' config user.name '$USERNAME'
  sudo -u '$USERNAME' git -C '$TARGET_DIR' config user.email '$USERNAME@local'
  sudo -u '$USERNAME' git -C '$TARGET_DIR' add -A
  sudo -u '$USERNAME' git -C '$TARGET_DIR' commit -m 'Automated nixos build setup' 2>/dev/null || true
"

echo "🚀 Сборка системы NixOS..."
nixos-rebuild switch --flake "$TARGET_DIR#mechrevo"

# ==============================================================================
# 15. Пароль пользователя (если его еще нет)
# ==============================================================================
echo "🔐 [15/15] Проверка пароля пользователя..."
if getent passwd "$USERNAME" >/dev/null; then
    PW_HASH=$(getent shadow "$USERNAME" | cut -d: -f2)
    case "$PW_HASH" in
        "" | "!"* | "*"*)
            echo "⚠️ У пользователя $USERNAME нет пароля - задай его сейчас:"
            passwd "$USERNAME" ;;
    esac
fi

echo "✅ Готово! Система собрана."
echo "   Выполни: sudo reboot"
echo "   - GRUB покажет NixOS и Windows (dual boot)"
echo "   - Закрытие крышки = гибернация"
echo "   - Пересборка: sudo nixos-rebuild switch --flake ~/.config/nixos#mechrevo"
