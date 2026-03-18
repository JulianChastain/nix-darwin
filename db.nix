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
  home.activation.migrateTrackerDb = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
    ${migrationScript}
  '';
}
