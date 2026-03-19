# db.nix — Declarative SQLite schema management for the project/task tracker.
#
# Define your schema as a list of version snapshots. Each snapshot is the
# *complete* desired state at that version — every table, every column.
# The migration library diffs consecutive versions automatically.
#
# Rules:
#   1. NEVER modify an existing snapshot — always append a new one.
#   2. Each snapshot must include ALL tables, not just changed ones.
#   3. Column order within a table is preserved in CREATE TABLE statements.

{ pkgs, lib, secrets, ... }:

let
  migrate = import ./sqlite-migrate.nix { inherit lib; };

  dbPath = "${secrets.homeDirectory}/.local/share/tracker/tracker.db";

  # ---------------------------------------------------------------------------
  # Schema history — append new versions to the end, never modify existing ones
  # ---------------------------------------------------------------------------
  schemaHistory = [

    # Version 1: Initial schema
    {
      projects = {
        columns = [
          { name = "id";         type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
          { name = "name";       type = "TEXT NOT NULL"; }
          { name = "path";       type = "TEXT NOT NULL UNIQUE"; }
          { name = "created_at"; type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
        ];
      };

      tasks = {
        columns = [
          { name = "id";         type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
          { name = "project_id"; type = "INTEGER NOT NULL REFERENCES projects(id)"; }
          { name = "title";      type = "TEXT NOT NULL"; }
          { name = "status";     type = "TEXT NOT NULL DEFAULT 'todo'"; }
          { name = "created_at"; type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
        ];
      };
    }

    # Version 2: Workspace ↔ git branch/worktree ↔ Azure work item ↔ PRs
    #
    # `projects` rows are the configured workspaces (name + filesystem path). New
    # columns cache the git branch at that path, a shared git identity for
    # worktrees (`git_common_dir` from `git rev-parse --git-common-dir`), and the
    # linked Azure Boards work item. `azure_pull_requests` stores PRs for a
    # workspace (typically where `source_branch` matches `tracked_git_branch`).
    {
      projects = {
        columns = [
          { name = "id";                     type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
          { name = "name";                   type = "TEXT NOT NULL"; }
          { name = "path";                   type = "TEXT NOT NULL UNIQUE"; }
          { name = "created_at";            type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
          { name = "tracked_git_branch";    type = "TEXT"; }
          { name = "git_common_dir";        type = "TEXT"; }
          { name = "azure_work_item_id";    type = "INTEGER"; }
          { name = "azure_work_item_state"; type = "TEXT"; }
        ];
      };

      tasks = {
        columns = [
          { name = "id";         type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
          { name = "project_id"; type = "INTEGER NOT NULL REFERENCES projects(id)"; }
          { name = "title";      type = "TEXT NOT NULL"; }
          { name = "status";     type = "TEXT NOT NULL DEFAULT 'todo'"; }
          { name = "created_at"; type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
        ];
      };

      azure_pull_requests = {
        columns = [
          { name = "id";              type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
          { name = "project_id";      type = "INTEGER NOT NULL REFERENCES projects(id)"; }
          { name = "azure_pr_id";     type = "INTEGER NOT NULL"; }
          { name = "source_branch";   type = "TEXT NOT NULL"; }
          { name = "state";           type = "TEXT NOT NULL"; }
          { name = "title";           type = "TEXT"; }
          { name = "url";             type = "TEXT"; }
          { name = "created_at";      type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
          { name = "updated_at";      type = "TEXT NOT NULL DEFAULT (datetime('now'))"; }
        ];
      };
    }

  ];

  # ---------------------------------------------------------------------------
  # Generate migrations and the runner script
  # ---------------------------------------------------------------------------
  migrations = migrate.generateMigrations schemaHistory;

  migrationScript = pkgs.writeShellScript "migrate-tracker-db" ''
    set -euo pipefail

    DB="${dbPath}"
    mkdir -p "$(dirname "$DB")"

    # Bootstrap: create the migrations tracking table
    ${pkgs.sqlite}/bin/sqlite3 "$DB" \
      "CREATE TABLE IF NOT EXISTS _schema_migrations (
         version    INTEGER PRIMARY KEY,
         applied_at TEXT NOT NULL DEFAULT (datetime('now'))
       );"

    CURRENT=$(${pkgs.sqlite}/bin/sqlite3 "$DB" \
      "SELECT COALESCE(MAX(version), 0) FROM _schema_migrations;")

    ${lib.concatStringsSep "\n" (map (m: ''
      if [ "$CURRENT" -lt ${toString m.version} ]; then
        echo "Applying migration v${toString m.version}..."
        ${pkgs.sqlite}/bin/sqlite3 "$DB" <<'MIGRATION_SQL'
    BEGIN;
    ${m.sql}
    INSERT INTO _schema_migrations (version) VALUES (${toString m.version});
    COMMIT;
    MIGRATION_SQL
        echo "  v${toString m.version} applied."
      fi
    '') migrations)}

    echo "tracker.db at v$(${pkgs.sqlite}/bin/sqlite3 "$DB" \
      "SELECT MAX(version) FROM _schema_migrations;")."
  '';

in {
  home.sessionVariables.WORK_DB = dbPath;

  home.activation.migrateTrackerDb = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${migrationScript}
  '';
}
