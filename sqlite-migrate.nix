# sqlite-migrate.nix — Pure Nix library for declarative SQLite schema management.
#
# Schemas are defined as a list of version snapshots (each a complete picture
# of every table at that point in time). The library diffs consecutive snapshots
# to produce migration SQL. Supported operations:
#
#   - CREATE TABLE  (new table appears in a version)
#   - DROP TABLE    (table removed from a version)
#   - ADD COLUMN    (new column in an existing table, no rebuild needed)
#   - DROP COLUMN   (column removed → full table rebuild)
#   - ALTER COLUMN  (column type changed → full table rebuild)
#
# Table definition format:
#   {
#     columns = [
#       { name = "id";   type = "INTEGER PRIMARY KEY AUTOINCREMENT"; }
#       { name = "name"; type = "TEXT NOT NULL"; }
#     ];
#   }
#
# Usage:
#   let migrate = import ./sqlite-migrate.nix { inherit lib; };
#       migrations = migrate.generateMigrations schemaHistory;
#   in ...

{ lib }:

let
  # ---------------------------------------------------------------------------
  # Column helpers
  # ---------------------------------------------------------------------------

  # { name → type } attrset for O(1) lookups
  colMap = def:
    builtins.listToAttrs (map (c: { name = c.name; value = c.type; }) def.columns);

  colNames = def: map (c: c.name) def.columns;

  # Columns present in new but absent from old
  addedColumns = oldDef: newDef:
    let om = colMap oldDef;
    in builtins.filter (c: !(om ? ${c.name})) newDef.columns;

  # Columns present in old but absent from new
  removedColumns = oldDef: newDef:
    let nm = colMap newDef;
    in builtins.filter (c: !(nm ? ${c.name})) oldDef.columns;

  # Columns present in both but with different type strings
  changedColumns = oldDef: newDef:
    let om = colMap oldDef;
    in builtins.filter (c: (om ? ${c.name}) && om.${c.name} != c.type) newDef.columns;

  # A table needs a full rebuild if columns were removed or types changed.
  # Simple additions can use ALTER TABLE ADD COLUMN.
  needsRebuild = oldDef: newDef:
    (removedColumns oldDef newDef) != [] || (changedColumns oldDef newDef) != [];

  # ---------------------------------------------------------------------------
  # SQL generation
  # ---------------------------------------------------------------------------

  createTableSQL = name: def:
    "CREATE TABLE ${name} (\n"
    + lib.concatStringsSep ",\n" (map (c: "  ${c.name} ${c.type}") def.columns)
    + "\n);";

  dropTableSQL = name: "DROP TABLE IF EXISTS ${name};";

  addColumnSQL = table: col:
    "ALTER TABLE ${table} ADD COLUMN ${col.name} ${col.type};";

  # Full table rebuild: create new table with desired schema, copy shared
  # columns from the old table, drop old, rename new.
  rebuildTableSQL = name: oldDef: newDef:
    let
      shared = builtins.filter
        (n: builtins.elem n (colNames oldDef))
        (colNames newDef);
      colList = lib.concatStringsSep ", " shared;
      tmpName = "_migrate_${name}";
    in lib.concatStringsSep "\n" (
      [ (createTableSQL tmpName newDef) ]
      ++ lib.optional (shared != [])
        "INSERT INTO ${tmpName} (${colList}) SELECT ${colList} FROM ${name};"
      ++ [
        (dropTableSQL name)
        "ALTER TABLE ${tmpName} RENAME TO ${name};"
      ]
    );

  # ---------------------------------------------------------------------------
  # Schema diffing
  # ---------------------------------------------------------------------------

  diffSchemas = old: new:
    let
      oldNames = builtins.attrNames old;
      newNames = builtins.attrNames new;

      created = builtins.filter (t: !(builtins.elem t oldNames)) newNames;
      dropped = builtins.filter (t: !(builtins.elem t newNames)) oldNames;
      common  = builtins.filter (t:  builtins.elem t oldNames)  newNames;
    in lib.concatStringsSep "\n" (
      (map dropTableSQL dropped)
      ++ (map (t: createTableSQL t new.${t}) created)
      ++ (lib.concatMap (t:
        if needsRebuild old.${t} new.${t}
        then [ (rebuildTableSQL t old.${t} new.${t}) ]
        else map (c: addColumnSQL t c) (addedColumns old.${t} new.${t})
      ) common)
    );

  # ---------------------------------------------------------------------------
  # Migration generation
  # ---------------------------------------------------------------------------

  # Takes a list of schema snapshots (version history) and produces a list of
  # { version : int, sql : string } migration records.
  generateMigrations = schemaHistory:
    lib.genList (i:
      if i == 0 then {
        version = 1;
        sql = lib.concatStringsSep "\n"
          (lib.mapAttrsToList createTableSQL (builtins.elemAt schemaHistory 0));
      } else {
        version = i + 1;
        sql = diffSchemas
          (builtins.elemAt schemaHistory (i - 1))
          (builtins.elemAt schemaHistory i);
      }
    ) (builtins.length schemaHistory);

in {
  inherit generateMigrations createTableSQL diffSchemas;
  inherit addedColumns removedColumns changedColumns needsRebuild;
}
