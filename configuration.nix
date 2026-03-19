{ pkgs, secrets, ... }:

{
  homebrew = {
    enable = true;

    onActivation = {
      cleanup = "zap";
      autoUpdate = true;
      upgrade = true;
    };

    taps = [
      "snyk/tap"
    ];

    brews = [
      "azure-cli"
      "awscli"
      "gh"
      "git-gui"
      "lazygit"
      "libvterm"
      "neovim"
      "pnpm"
      "python-launcher"
      "qalculate-qt"
      "snyk/tap/snyk"
      "sqlcmd"
      "tree-sitter"
      "zoxide"
      "zsh"
    ];

    casks = [
      "anki"
      "bitwarden"
      "copilot-cli"
      "cursor"
      "docker-desktop"
      "flycut"
      "gitkraken"
      "google-chrome"
      "karabiner-elements"
      "logseq"
      "obsidian"
      "powershell"
      "visual-studio-code"
      "wezterm"
    ];
  };

  users.users.${secrets.username} = {
    name = secrets.username;
    home = secrets.homeDirectory;
  };

  programs.zsh.enable = true;

  nix.enable = false;

  launchd.daemons.nix-darwin-rebuild = {
    script = ''
      export PATH=/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin
      export HOME=/var/root

      FLAKE=${secrets.flakeDirectory}

      # Allow root to access the user's git repo (use --replace-all to avoid duplicate entries)
      git config --global --replace-all safe.directory "$FLAKE"

      echo "=== nix-darwin-rebuild started at $(date) ==="

      # Update flake inputs daily
      nix flake update --flake "$FLAKE" 2>&1
      chown -R ${secrets.username}:staff "$FLAKE"
      echo "=== flake update finished at $(date) ==="

      # Run rebuild in a way that survives the daemon being reloaded mid-switch
      # Note: if successful, the daemon reloads itself and kills this script,
      # so the "finished" line below only appears on failure.
      nohup darwin-rebuild switch --impure --flake "$FLAKE" 2>&1 &
      REBUILD_PID=$!
      wait $REBUILD_PID
      echo "=== nix-darwin-rebuild failed (exit code: $?) at $(date) ==="
    '';
    serviceConfig = {
      StartCalendarInterval = [{ Hour = 9; Minute = 0; }];
      StandardOutPath = "/var/log/darwin-rebuild.log";
      StandardErrorPath = "/var/log/darwin-rebuild.log";
    };
  };

  launchd.user.agents.flycut = {
    script = ''
      open -a /Applications/Flycut.app
    '';
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };

  launchd.user.agents.docker-desktop = {
    script = ''
      open -a /Applications/Docker.app
    '';
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };

  launchd.user.agents.wezterm-mux = {
    script = ''
      /opt/homebrew/bin/wezterm-mux-server --daemonize
    '';
    serviceConfig = {
      RunAtLoad = true;
      KeepAlive = false;
    };
  };

  # Remove Google auto-updater launch agents on each activation.
  system.activationScripts.postActivation.text = ''
    echo "Removing Google updater launch agents..."
    rm -f ~/Library/LaunchAgents/com.google.keystone.agent.plist
    rm -f ~/Library/LaunchAgents/com.google.keystone.xpcservice.plist
    rm -f ~/Library/LaunchAgents/com.google.GoogleUpdater.wake.plist
  '';

  system.primaryUser = secrets.username;

  system.stateVersion = 5;

  nixpkgs.hostPlatform = "aarch64-darwin";
}
