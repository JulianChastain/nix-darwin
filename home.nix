{ pkgs, lib, secrets, ... }:

{
  imports = [ ./db.nix ];
  home.username = secrets.username;
  home.homeDirectory = secrets.homeDirectory;
  home.stateVersion = "24.11";

  home.packages = with pkgs; [
    git
    nodejs
    typescript
    eza
    nerd-fonts.jetbrains-mono
  ];

  programs.zsh = {
    enable = true;
    enableCompletion = true;

    oh-my-zsh = {
      enable = true;
      theme = "";
      plugins = [ "git" "yarn" "eza" ];
    };

    envExtra = ''
      export PATH="$HOME/bin:$PATH"
      export PATH="$HOME/.local/bin:$PATH"
      export PATH="$HOME/.qlot/bin:$PATH"
      export PATH="$HOME/.antigravity/antigravity/bin:$PATH"
      export EDITOR=nvim
      export BUN_INSTALL="$HOME/.bun"
      export PATH="$BUN_INSTALL/bin:$PATH"
    '';

    shellAliases = {
      rebuild = "sudo darwin-rebuild switch --impure --flake ${secrets.flakeDirectory}";
    };

    initContent = ''
      eval "$(zoxide init zsh)"

      # bun completions
      [ -s "$HOME/.bun/_bun" ] && source "$HOME/.bun/_bun"

      # Secrets from macOS Keychain
      export YARN_NPM_AUTH_TOKEN="$(security find-generic-password -a '${secrets.username}' -s 'YARN_NPM_AUTH_TOKEN' -w 2>/dev/null)"
    '';
  };

  home.file.".config/wezterm/wezterm.lua".text = ''
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

  home.file."bin/az-dashboard" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail

      bold="\033[1m"
      reset="\033[0m"
      ORG="${secrets.azure.org}"
      PROJECT="${secrets.azure.project}"
      WI_BASE="''${ORG}/''${PROJECT}/_workitems/edit"

      osc_link() {
        # Usage: osc_link <url> <text> <width>
        local url="$1" text="$2" width="$3"
        local padded
        padded=$(printf "%-''${width}s" "$text")
        printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$url" "$padded"
      }

      # ── Active Work Items ────────────────────────────────────────────────
      echo -e "\n''${bold}Work Items (assigned to me, active)''${reset}\n"

      wiql="SELECT [System.Id], [System.WorkItemType], [System.Title], [System.State], [System.AssignedTo] \
      FROM WorkItems \
      WHERE [System.AssignedTo] = @Me \
        AND [System.State] <> 'Closed' \
        AND [System.State] <> 'Removed' \
        AND [System.State] <> 'Done' \
      ORDER BY [System.WorkItemType] ASC, [System.State] ASC, [System.ChangedDate] DESC"

      story_json=$(az boards query --wiql "$wiql" -o json 2>&1)

      echo "$story_json" | python3 -c "
      import json, sys
      wi_base = ${"'"}''${WI_BASE}${"'"}
      rows = json.load(sys.stdin)
      if not rows:
          print('  No active work items.')
          sys.exit(0)

      hdr = f\"{'ID':<10}{'Type':<15}{'State':<15}{'Title'}\"
      print(hdr)
      print('─' * len(hdr))
      for r in rows:
          f = r['fields']
          wid   = f['System.Id']
          wtype = f['System.WorkItemType']
          state = f['System.State']
          title = f['System.Title'][:60]
          link  = f'{wi_base}/{wid}'
          padded_id = str(wid).ljust(10)
          linked_id = f'\033]8;;{link}\033\\\\{padded_id}\033]8;;\033\\\\'
          print(f'{linked_id}{wtype:<15}{state:<15}{title}')
      "

      # ── Active Pull Requests ─────────────────────────────────────────────
      echo -e "\n''${bold}Pull Requests (created by me or assigned to review)''${reset}\n"

      pr_json=$(python3 -c "
      import json, subprocess, sys

      def get_prs(flag):
          result = subprocess.run(
              ['az', 'repos', 'pr', 'list', '--status', 'active', flag, 'me', '-o', 'json'],
              capture_output=True, text=True
          )
          return json.loads(result.stdout) if result.returncode == 0 else []

      def get_linked_stories(pr_id):
          result = subprocess.run(
              ['az', 'repos', 'pr', 'work-item', 'list', '--id', str(pr_id), '-o', 'json'],
              capture_output=True, text=True
          )
          if result.returncode != 0:
              return []
          items = json.loads(result.stdout)
          return [
              str(wi['id']) for wi in items
              if wi.get('fields', {}).get('System.WorkItemType') == 'User Story'
          ]

      created = get_prs('--creator')
      reviewing = get_prs('--reviewer')

      created_ids = {pr['pullRequestId'] for pr in created}
      all_prs = created + [pr for pr in reviewing if pr['pullRequestId'] not in created_ids]

      rows = []
      for pr in all_prs:
          stories = get_linked_stories(pr['pullRequestId'])
          rows.append({
              'id':      pr['pullRequestId'],
              'role':    'Author' if pr['pullRequestId'] in created_ids else 'Reviewer',
              'title':   pr['title'][:55],
              'repo':    pr['repository']['name'],
              'creator': pr['createdBy']['displayName'],
              'date':    pr['creationDate'][:10],
              'link':    f\"{pr['repository']['url'].split('/_apis/')[0]}/_git/{pr['repository']['name']}/pullrequest/{pr['pullRequestId']}\",
              'stories': stories,
          })

      rows.sort(key=lambda r: r['date'], reverse=True)
      print(json.dumps(rows))
      ")

      if [ "$(echo "$pr_json" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -eq 0 ]; then
          echo "  No active pull requests."
      else
          echo "$pr_json" | python3 -c "
      import json, sys
      wi_base = ${"'"}''${WI_BASE}${"'"}
      rows = json.load(sys.stdin)
      hdr = f\"{'ID':<8}{'Role':<11}{'Created':<13}{'Creator':<25}{'Repository':<20}{'Story':<10}{'Title'}\"
      print(hdr)
      print('─' * len(hdr))
      for r in rows:
          padded_id = str(r['id']).ljust(8)
          link_id = f'\033]8;;{r[\"link\"]}\033\\\\{padded_id}\033]8;;\033\\\\'
          if r['stories']:
              story_ids = []
              for sid in r['stories']:
                  padded_sid = sid.ljust(10) if len(r['stories']) == 1 else sid
                  story_ids.append(f'\033]8;;{wi_base}/{sid}\033\\\\{padded_sid}\033]8;;\033\\\\')
              story_col = ', '.join(story_ids)
          else:
              story_col = '—'.ljust(10)
          print(f\"{link_id}{r['role']:<11}{r['date']:<13}{r['creator']:<25}{r['repo']:<20}{story_col}{r['title']}\")
      "
      fi

      echo ""
    '';
  };

  home.file."bin/starship-workitem" = {
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

  home.file.".config/karabiner/karabiner.json".text = builtins.toJSON {
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
          when = "test $(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 )) -ge 2";
          command = "echo ↻$(( ($(date +%s) - $(stat -f %m /nix/var/nix/profiles/system)) / 86400 ))d";
          format = " [$output](red)";
        };
        rebuild_age_yellow = {
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
