use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let migrations_dir = manifest_dir.join("../db/migrations");
    let migrations_dir = fs::canonicalize(&migrations_dir).unwrap_or(migrations_dir);
    println!("cargo:rerun-if-changed={}", migrations_dir.display());

    let mut files: Vec<PathBuf> = fs::read_dir(&migrations_dir)
        .unwrap_or_else(|error| {
            panic!(
                "db/migrations is unreadable at {}: {error}",
                migrations_dir.display()
            )
        })
        .map(|entry| entry.expect("migration directory entry").path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("sql"))
        .collect();
    files.sort();
    if files.is_empty() {
        panic!("db/migrations contains no .sql files");
    }

    let mut entries = String::new();
    for path in files {
        let name = path
            .file_name()
            .and_then(|name| name.to_str())
            .expect("migration filename must be utf-8");
        println!("cargo:rerun-if-changed={}", path.display());
        let escaped = path
            .display()
            .to_string()
            .replace('\\', "\\\\")
            .replace('"', "\\\"");
        entries.push_str(&format!(
            "        (\"{name}\", include_str!(\"{escaped}\")),\n"
        ));
    }

    let generated = format!(
        "pub fn bundled_migrations() -> Result<Vec<Migration>, MigrateError> {{\n    parse_migration_files(&[\n{entries}    ])\n}}\n"
    );
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    fs::write(out_dir.join("bundled.rs"), generated).expect("write bundled.rs");
}
