{ config, pkgs, lib, secrets, ... }:

let
  # Repo-local script; @azureOrg@ / @azureProject@ in ./scripts/az-dashboard.sh are filled from secrets.
  az-dashboard-text =
    builtins.replaceStrings [ "@azureOrg@" "@azureProject@" ] [
      secrets.azure.org
      secrets.azure.project
    ] (builtins.readFile ./scripts/az-dashboard.sh);
in {
  imports = [ ./db.nix ];
  home.username = secrets.username;
  home.homeDirectory = secrets.homeDirectory;
  home.stateVersion = "24.11";

  xdg.enable = true;

  home.sessionPath = [
    "$HOME/.local/bin"
  ];

  home.sessionVariables = {
    EDITOR = "nvim";
    IDLEUSERDIR = "$HOME/.config/idlerc";
    AWS_CONFIG_FILE = "$HOME/.config/aws/config";
    AWS_SHARED_CREDENTIALS_FILE = "$HOME/.config/aws/credentials";
    AZURE_CONFIG_DIR = "$HOME/.config/azure";
    DOCKER_CONFIG = "$HOME/.config/docker";
    NPM_CONFIG_USERCONFIG = "$HOME/.config/npm/npmrc";
    NPM_CONFIG_CACHE = "$HOME/.cache/npm";
    LESSHISTFILE = "$HOME/.local/state/less/history";
    NODE_REPL_HISTORY = "$HOME/.local/state/node/repl_history";
    PYTHONHISTFILE = "$HOME/.local/state/python/history";
    TS_NODE_HISTORY = "$HOME/.local/state/ts-node/repl_history";
    HISTFILE = "$HOME/.local/state/zsh/history";
    ZSH_COMPDUMP = "$HOME/.cache/zsh/zcompdump-$HOST-$ZSH_VERSION";
    # Managed as plain files under ~/.config/git/ (see migrateHomeClutter). programs.git is left off so HM does not overwrite them.
    GIT_CONFIG_GLOBAL = "${config.xdg.configHome}/git/config";
  };

  home.activation.migrateHomeClutter = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    move_dir_if_absent() {
      local src="$1"
      local dst="$2"

      if [ -d "$src" ] && [ ! -e "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        mv "$src" "$dst"
      fi
    }

    move_file_if_absent() {
      local src="$1"
      local dst="$2"

      if [ -e "$src" ] && [ ! -e "$dst" ]; then
        mkdir -p "$(dirname "$dst")"
        mv "$src" "$dst"
      fi
    }

    # Merge legacy top-level dirs into XDG targets (skip names that already exist in dst), then remove src.
    merge_dir_into() {
      local src="$1"
      local dst="$2"
      [ -d "$src" ] || return 0
      mkdir -p "$dst"
      ${pkgs.rsync}/bin/rsync -a --ignore-existing "$src/" "$dst/"
      rm -rf "$src"
    }

    merge_dir_into "$HOME/.aws" "$HOME/.config/aws"
    merge_dir_into "$HOME/.azure" "$HOME/.config/azure"
    merge_dir_into "$HOME/.docker" "$HOME/.config/docker"
    merge_dir_into "$HOME/.npm" "$HOME/.cache/npm"

    move_dir_if_absent "$HOME/.idlerc" "$HOME/.config/idlerc"

    mkdir -p \
      "$HOME/.config/aws" \
      "$HOME/.config/git" \
      "$HOME/.config/npm" \
      "$HOME/.config/azure" \
      "$HOME/.config/docker" \
      "$HOME/.config/idlerc" \
      "$HOME/.cache/npm" \
      "$HOME/.cache/zsh" \
      "$HOME/.cache/oh-my-zsh" \
      "$HOME/.local/state/less" \
      "$HOME/.local/state/node" \
      "$HOME/.local/state/python" \
      "$HOME/.local/state/ts-node" \
      "$HOME/.local/state/zsh" \
      "$HOME/.local/share/bun"

    move_file_if_absent "$HOME/.aws/config" "$HOME/.config/aws/config"
    move_file_if_absent "$HOME/.aws/credentials" "$HOME/.config/aws/credentials"
    move_file_if_absent "$HOME/.npmrc" "$HOME/.config/npm/npmrc"
    move_file_if_absent "$HOME/.lesshst" "$HOME/.local/state/less/history"
    move_file_if_absent "$HOME/.node_repl_history" "$HOME/.local/state/node/repl_history"
    move_file_if_absent "$HOME/.python_history" "$HOME/.local/state/python/history"
    move_file_if_absent "$HOME/.ts_node_repl_history" "$HOME/.local/state/ts-node/repl_history"
    move_file_if_absent "$HOME/.zsh_history" "$HOME/.local/state/zsh/history"

    move_file_if_absent "$HOME/.gitconfig-ecosystem" "$HOME/.config/git/gitconfig-ecosystem"
    move_file_if_absent "$HOME/.gitconfig" "$HOME/.config/git/config"
    if [ -f "$HOME/.config/git/config" ]; then
      ${pkgs.gnused}/bin/sed -i.bak \
        's|path = ~/.gitconfig-ecosystem|path = gitconfig-ecosystem|g' \
        "$HOME/.config/git/config" 2>/dev/null || true
      rm -f "$HOME/.config/git/config.bak"
    fi

    # HM uses nixpkgs oh-my-zsh (see ~/.config/zsh/.zshenv); this tree is obsolete.
    rm -rf "$HOME/.oh-my-zsh"

    # Not auto-migrated (no reliable XDG env): ~/.azure-devops ~/.gemini ~/.varlock — remove manually if unused.

    if [ -L "$HOME/bin/begin" ]; then
      rm -f "$HOME/bin/begin"
    fi

    rm -f "$HOME"/.zcompdump*
    rmdir "$HOME/.aws" 2>/dev/null || true
    rmdir "$HOME/bin" 2>/dev/null || true
  '';

  home.packages = with pkgs; [
    git
    nodejs
    typescript
    eza
    ripgrep
    nerd-fonts.jetbrains-mono
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;
    dotDir = "${config.xdg.configHome}/zsh";

    oh-my-zsh = {
      enable = true;
      theme = "";
      plugins = [ "git" "yarn" "eza" ];
    };

    envExtra = ''
      mkdir -p "$HOME/.cache/zsh" "$HOME/.local/state/zsh"
    '';

    shellAliases = {
      rebuild = "sudo darwin-rebuild switch --impure --flake ${secrets.flakeDirectory}";
    };

    initContent = ''
      eval "$(zoxide init zsh)"

      # bun completions
      [ -s "$BUN_INSTALL/_bun" ] && source "$BUN_INSTALL/_bun"

      # Secrets from macOS Keychain
      export YARN_NPM_AUTH_TOKEN="$(security find-generic-password -a '${secrets.username}' -s 'YARN_NPM_AUTH_TOKEN' -w 2>/dev/null)"
    '';
  };

  xdg.configFile."wezterm/wezterm.lua".text = ''
    local wezterm = require 'wezterm'
    local act = wezterm.action
    local config = wezterm.config_builder()

    config.unix_domains = {
      {
        name = 'unix',
      },
    }

    config.default_gui_startup_args = { 'connect', 'unix' }

    config.font = wezterm.font('JetBrainsMono Nerd Font')

    -- Project workspaces: bound to a directory, display git info
    local project_workspaces = {
${lib.concatMapStringsSep "\n" (ws:
  "      { name = '${ws.name}', cwd = wezterm.home_dir .. '/Documents/projects/${ws.repo}' },"
) secrets.workspaces}
    }

    -- Default workspaces: no bound directory, no git info
    local default_workspaces = {
      { name = 'core-root', cwd = wezterm.home_dir .. '/Documents/projects' },
      { name = 'config' },
    }

    -- Map project workspace names to their cwd for lookups
    local project_cwd = {}
    for _, ws in ipairs(project_workspaces) do
      project_cwd[ws.name] = ws.cwd
    end

    local function git_info_fetch(cwd)
      if not cwd then return nil end

      -- Branch name
      local ok, out = wezterm.run_child_process({
        'git', '-C', cwd, 'branch', '--show-current',
      })
      if not ok then return nil end
      local branch = out:gsub('%s+$', ''')
      if branch == ''' then return nil end

      -- Status: staged, modified, untracked
      local staged, modified, untracked = false, false, false
      ok, out = wezterm.run_child_process({
        'git', '-C', cwd, 'status', '--porcelain=v1',
      })
      if ok then
        for line in out:gmatch('[^\n]+') do
          local x = line:sub(1, 1)
          local y = line:sub(2, 2)
          if x ~= ' ' and x ~= '?' then staged = true end
          if y ~= ' ' and y ~= '?' then modified = true end
          if x == '?' then untracked = true end
        end
      end

      -- Ahead/behind upstream
      local ahead, behind = 0, 0
      ok, out = wezterm.run_child_process({
        'git', '-C', cwd, 'rev-list', '--left-right', '--count', 'HEAD...@{upstream}',
      })
      if ok then
        ahead, behind = out:match('(%d+)%s+(%d+)')
        ahead = tonumber(ahead) or 0
        behind = tonumber(behind) or 0
      end

      -- Compose status symbols (matching starship config)
      local symbols = '''
      if staged then symbols = symbols .. '●' end      -- green in starship
      if modified then symbols = symbols .. '●' end     -- yellow in starship
      if untracked then symbols = symbols .. '●' end    -- red in starship
      if ahead > 0 then symbols = symbols .. '▴' .. ahead end
      if behind > 0 then symbols = symbols .. '▾' .. behind end

      if symbols ~= ''' then
        return branch .. ' ' .. symbols
      end
      return branch
    end

    -- Cache git info; populated by update-status, read by format-window-title
    local git_cache = {}
    local git_cache_ttl = 10 -- seconds
    local git_cache_last_refresh = 0

    local function refresh_git_cache()
      local now = os.time()
      if (now - git_cache_last_refresh) < git_cache_ttl then return end
      git_cache_last_refresh = now
      for _, ws in ipairs(project_workspaces) do
        local ok, result = pcall(git_info_fetch, ws.cwd)
        if ok then
          git_cache[ws.name] = result
        end
      end
    end

    -- Read-only: returns cached git info for a workspace (never shells out)
    local function workspace_label(name)
      local info = git_cache[name]
      if info then
        return name .. ' [' .. info .. ']'
      end
      if project_cwd[name] then
        return name
      end
      return name
    end

    -- Full fetch: used by the fuzzy finder where blocking is acceptable
    local function workspace_label_fresh(name)
      local cwd = project_cwd[name]
      if cwd then
        local ok, info = pcall(git_info_fetch, cwd)
        if ok and info then
          return name .. ' [' .. info .. ']'
        end
      end
      return name
    end

    -- Workspace switcher via InputSelector
    local function workspace_switcher(window, pane)
      local choices = {}
      for _, ws_name in ipairs(wezterm.mux.get_workspace_names()) do
        table.insert(choices, {
          label = workspace_label_fresh(ws_name),
          id = ws_name,
        })
      end

      window:perform_action(act.InputSelector {
        title = 'Switch Workspace',
        fuzzy = true,
        choices = choices,
        action = wezterm.action_callback(function(win, p, id, label)
          if id then
            win:perform_action(act.SwitchToWorkspace { name = id }, p)
          end
        end),
      }, pane)
    end

    wezterm.on('switch-workspace', function(window, pane)
      workspace_switcher(window, pane)
    end)

    wezterm.on('next-workspace', function(window, pane)
      local names = wezterm.mux.get_workspace_names()
      local current = wezterm.mux.get_active_workspace()
      for i, name in ipairs(names) do
        if name == current then
          local next_name = names[(i % #names) + 1]
          window:perform_action(act.SwitchToWorkspace { name = next_name }, pane)
          return
        end
      end
    end)

    wezterm.on('prev-workspace', function(window, pane)
      local names = wezterm.mux.get_workspace_names()
      local current = wezterm.mux.get_active_workspace()
      for i, name in ipairs(names) do
        if name == current then
          local prev_name = names[((i - 2) % #names) + 1]
          window:perform_action(act.SwitchToWorkspace { name = prev_name }, pane)
          return
        end
      end
    end)

    config.keys = {
      { key = 'w', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.EmitEvent 'switch-workspace' },
      { key = 'w', mods = 'CTRL|SHIFT', action = act.EmitEvent 'switch-workspace' },
      { key = 'n', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.EmitEvent 'next-workspace' },
      { key = 'p', mods = 'CTRL|SHIFT|ALT|SUPER', action = act.EmitEvent 'prev-workspace' },
    }

    wezterm.on('mux-startup', function()
      local mux = wezterm.mux
      for _, ws in ipairs(default_workspaces) do
        mux.spawn_window { workspace = ws.name, cwd = ws.cwd }
      end
      for _, ws in ipairs(project_workspaces) do
        mux.spawn_window { workspace = ws.name, cwd = ws.cwd }
      end
    end)

    wezterm.on('gui-attached', function()
      local mux = wezterm.mux
      mux.set_active_workspace('core-root')
    end)

    -- Track workspace per GUI window by hooking into workspace switch events
    local gui_window_workspace = {}

    wezterm.on('update-status', function(window, pane)
      local gui_id = window:window_id()
      local ws = window:active_workspace()
      gui_window_workspace[gui_id] = ws
      refresh_git_cache()
    end)

    wezterm.on('format-window-title', function(tab, pane, tabs, panes, cfg)
      local ok, result = pcall(function()
        local ws_name = gui_window_workspace[tab.window_id] or '''
        if ws_name == ''' then
          ws_name = wezterm.mux.get_active_workspace()
        end

        local title = tab.active_pane.title
        local label = workspace_label(ws_name)

        if #tabs > 1 then
          local index = string.format('[%d/%d]', tab.tab_index + 1, #tabs)
          return label .. ' - ' .. index .. ' - ' .. title
        else
          return label .. ' - ' .. title
        end
      end)
      if ok then
        return result
      else
        wezterm.log_error('format-window-title error: ' .. tostring(result))
        return 'error: ' .. tostring(result)
      end
    end)

    return config
  '';

  home.file.".local/bin/az-dashboard" = {
    executable = true;
    text = az-dashboard-text;
  };

  home.file.".local/bin/starship-workitem" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      branch=$(git branch --show-current 2>/dev/null) || exit 1
      id=$(echo "$branch" | sed -nE 's/^(story|bugfix|techdebt)([0-9]+)\/.*/\2/p')
      [ -z "$id" ] && exit 1
      url="${secrets.azure.org}/${secrets.azure.project}/_workitems/edit/$id"
      printf '\033]8;;%s\033\\work item linked\033]8;;\033\\' "$url"
    '';
  };

  home.file.".local/bin/begin" = {
    executable = true;
    source = "${./scripts/begin}";
  };

  home.file.".local/bin/agent-nvim" = {
    executable = true;
    source = "${./scripts/agent-nvim}";
  };

  home.file.".local/bin/nibble" = {
    executable = true;
    source = "${./scripts/agent-nvim}";
  };

  home.file.".local/bin/agent-buffer" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      editor="''${EDITOR:-nvim}"
      read -r -a editor_cmd <<<"$editor"
      editor_name="''${editor_cmd[0]##*/}"

      tmpdir="''${TMPDIR:-/tmp}"
      prompt_file="$(mktemp "$tmpdir/agent-buffer.XXXXXX.md")"
      lua_file="$(mktemp "$tmpdir/agent-buffer.XXXXXX.lua")"

      cleanup() {
        rm -f "$prompt_file" "$lua_file"
      }

      trap cleanup EXIT

      cat >"$lua_file" <<'EOF'
      local prompt_file = vim.env.AGENT_BUFFER_FILE

      vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = 0,
        once = true,
        callback = function()
          local lines = vim.fn.readfile(prompt_file)
          local text = table.concat(lines, "\n")

          vim.cmd("botright 15split")
          vim.fn.termopen({
            "agent",
            "--model",
            "auto",
            "--trust",
            "--print",
            "--yolo",
            text,
          })
          vim.cmd("startinsert")
        end,
      })
      EOF

      case "$editor_name" in
        nvim|vim|vi)
          AGENT_BUFFER_FILE="$prompt_file" AGENT_BUFFER_LUA="$lua_file" \
            "''${editor_cmd[@]}" -c "lua dofile(vim.env.AGENT_BUFFER_LUA)" "$prompt_file"
          ;;
        *)
          "''${editor_cmd[@]}" "$prompt_file"
          if [ -s "$prompt_file" ]; then
            agent --model "auto" --trust --print --yolo "$(<"$prompt_file")"
          fi
          ;;
      esac
    '';
  };

  home.file."Applications/Qalculate.app/Contents/MacOS/Qalculate" = {
    text = ''
      #!/bin/bash
      exec /opt/homebrew/bin/qalculate-qt "$@"
    '';
    executable = true;
  };

  home.file."Applications/Qalculate.app/Contents/Info.plist".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
      "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>CFBundleExecutable</key>
      <string>Qalculate</string>
      <key>CFBundleIdentifier</key>
      <string>org.qalculate.qt</string>
      <key>CFBundleName</key>
      <string>Qalculate</string>
      <key>CFBundlePackageType</key>
      <string>APPL</string>
      <key>CFBundleVersion</key>
      <string>1.0</string>
    </dict>
    </plist>
  '';

  xdg.configFile."karabiner/karabiner.json".text = builtins.toJSON {
    global = {
      ask_for_confirmation_before_quitting = true;
      check_for_updates_on_startup = false;
      show_in_menu_bar = false;
      show_profile_name_in_menu_bar = false;
      unsafe_ui = false;
    };
    profiles = [
      {
        name = "Default";
        selected = true;
        complex_modifications = {
          rules = [
            {
              description = "CapsLock → Hyper (Ctrl+Shift+Alt+Cmd)";
              manipulators = [
                {
                  type = "basic";
                  from = {
                    key_code = "caps_lock";
                    modifiers.optional = [ "any" ];
                  };
                  to = [
                    {
                      key_code = "left_shift";
                      modifiers = [ "left_command" "left_control" "left_option" ];
                    }
                  ];
                  to_if_alone = [
                    { key_code = "escape"; }
                  ];
                }
              ];
            }
          ];
        };
        virtual_hid_keyboard = {
          caps_lock_delay_milliseconds = 0;
          country_code = 0;
          keyboard_type = "ansi";
          keyboard_type_v2 = "ansi";
        };
      }
    ];
  };

  programs.starship = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      command_timeout = 2000;
      format = "$username$hostname $directory$fill\${custom.azure_workitem}$nodejs$git_branch$git_status$line_break[> ]()$character";
      right_format = "$time\${custom.rebuild_age_red}\${custom.rebuild_age_yellow}";
      add_newline = true;

      username = {
        show_always = true;
        style_user = "bold white";
        style_root = "bold red";
        format = "[$user]($style)";
      };

      hostname = {
        ssh_only = false;
        format = "[@$hostname]()";
      };

      directory = {
        style = "bold white";
        truncation_length = 0;
        truncate_to_repo = false;
      };

      fill = {
        symbol = " ";
      };

      time = {
        disabled = false;
        format = "[\\[$time\\]]()";
        time_format = "%T";
      };

      character = {
        success_symbol = "[\\$](green)";
        error_symbol = "[\\$](red)";
      };

      nodejs = {
        format = "[⬡ $version]($style) ";
      };

      git_branch = {
        format = "[\\[±](green)[$branch](bold white)";
      };

      git_status = {
        format = "[ $all_status$ahead_behind]()[\\]](white)";
        staged = "[●](bold green)";
        modified = "[●](bold yellow)";
        untracked = "[●](bold red)";
        deleted = "[●](bold yellow)";
        renamed = "";
        typechanged = "";
        ahead = "[▴](cyan)";
        behind = "[▾](magenta)";
        diverged = "[▴](cyan)[▾](magenta)";
        stashed = "[(✹)](bold blue)";
        conflicted = "[✖](red)";
      };

      custom = {
        rebuild_age_red = {
          shell = [ "${pkgs.bash}/bin/bash" "--noprofile" "--norc" "-c" ];
          when = "test $(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 )) -ge 2";
          command = "echo ↻$(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 ))d";
          format = " [$output](red)";
        };
        rebuild_age_yellow = {
          shell = [ "${pkgs.bash}/bin/bash" "--noprofile" "--norc" "-c" ];
          when = "test $(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 )) -eq 1";
          command = "echo ↻$(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 ))d";
          format = " [$output](yellow)";
        };
        azure_workitem = {
          detect_files = [ ".git" ];
          command = "starship-workitem";
          format = " $output";
        };
      };
    };
  };

  programs.home-manager.enable = true;
}
