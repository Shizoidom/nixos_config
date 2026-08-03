# NixOS / Hyprland (Mechrevo: Ryzen 9 7845HX + RTX 5070M)

Конфигурация NixOS с Hyprland для ноутбука Mechrevo (Ryzen 9 7845HX, NVIDIA RTX 5070M 8GB,
два монитора: eDP-1 2560x1600@240 + внешний).

## Установка одной командой

На свежеустановленной минимальной NixOS (подключись к сети) выполни:

```bash
curl -sSL https://raw.githubusercontent.com/Shizoidom/nixos_config/main/install.sh | sudo bash
```

Скрипт сам сделает все:

| Шаг | Что делает |
|-----|------------|
| 1-2 | Создаёт структуру, копирует/генерирует `hardware-configuration.nix` |
| 3 | Генерирует flake (nixpkgs-unstable + home-manager) |
| 4 | Настройка NVIDIA RTX 5070M (open-модули ядра — обязательны для Blackwell, latest драйвер, без PRIME — у 7845HX нет встроенной графики) |
| 5 | Создаёт swapfile размером с RAM и вычисляет параметры resume для гибернации |
| 6 | Системный конфиг: GRUB (dual boot с Windows через os-prober), гибернация при закрытии крышки, SDDM, PipeWire, Zsh, шрифты |
| 7-12 | Kitty, Fuzzel, SwayNC, Hyprland, Waybar, Home Manager |
| 13-14 | Права, git-init, `nixos-rebuild switch` |
| 15 | Проверка пароля пользователя |

Имя пользователя по умолчанию — `next`. Если нужно другое:

```bash
curl -sSL https://raw.githubusercontent.com/Shizoidom/nixos_config/main/install.sh | sudo bash -s -- my-username
```

### Что ты получаешь

- **Hyprland** + Waybar + Fuzzel + Kitty + SwayNC (Catppuccin Mocha)
- **Дуал-бут**: GRUB с os-prober — Windows и NixOS в одном меню
- **Гибернация по закрытию крышки** (и от батареи, и от сети): RAM выгружается в swapfile
  на `/var/lib/swapfile`, при открытии крышки всё восстанавливается
- **NVIDIA RTX 5070M**: open-модули ядра (Blackwell), latest драйвер, fine-grained power management
- **Локаль ru_RU.UTF-8**, часовой пояс Europe/Moscow
- Внутренний экран: воркспейсы 1-4, внешний монитор: 5-7

## Хоткеи

| Сочетание | Действие |
|-----------|----------|
| SUPER + RETURN | Открыть терминал (Kitty) |
| SUPER + SPACE | Поиск приложений (Fuzzel) |
| SUPER + Q | Закрыть активное окно |
| SUPER + E | Файловый менеджер (Dolphin) |
| SUPER + F | Плавающий режим окна |
| SUPER + H / J / K / L | Фокус по окнам (Vim-стиль) |
| PRINT | Скриншот выделенной области |

| Сочетание | Действие |
|-----------|----------|
| SUPER + 1 ... 4 | Воркспейсы 1-4 (экран ноутбука) |
| SUPER + 5 ... 7 | Воркспейсы 5-7 (внешний монитор) |

## Пересборка после изменений

```bash
sudo nixos-rebuild switch --flake ~/.config/nixos#mechrevo
```

## Структура (генерируется при установке)

```
~/.config/nixos/
├── flake.nix                     # входные точки nixpkgs + home-manager
├── system/
│   ├── hardware-configuration.nix # аппаратная конфигурация твоего ноута
│   ├── configuration.nix          # GRUB, гибернация, SDDM, звук, сеть
│   └── nvidia.nix                 # NVIDIA RTX 5070M
└── home/
    ├── home.nix                   # приложения, темы, zsh
    ├── hyprland.nix               # воркспейсы, хоткеи, анимации
    ├── waybar.nix                 # статус-бар
    ├── kitty.nix                  # терминал
    ├── fuzzel.nix                 # лаунчер
    └── swaync.nix                 # уведомления
```
