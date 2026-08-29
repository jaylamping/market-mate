use sha2::{Digest, Sha256};
use std::fmt::Write as _;
use std::fs;
use std::path::Path;
use tokio::task::JoinHandle;
use tokio_postgres::{Client, NoTls};

const MIGRATION_LOCK_KEY: i64 = 8702;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Migration {
    pub version: i64,
    pub name: String,
    pub sql: String,
}

impl Migration {
    pub fn checksum(&self) -> String {
        checksum(&self.sql)
    }
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct ApplyReport {
    pub applied_versions: Vec<i64>,
    pub already_applied_versions: Vec<i64>,
    pub head_version: Option<i64>,
    pub noop: bool,
}

#[derive(Debug)]
pub enum MigrateError {
    Sequence(String),
    Checksum {
        version: i64,
        expected: String,
        actual: String,
    },
    Io(std::io::Error),
    Sql(tokio_postgres::Error),
    DatabaseUrl,
}

impl std::fmt::Display for MigrateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Sequence(message) => write!(f, "migration sequence failed closed: {message}"),
            Self::Checksum {
                version,
                expected,
                actual,
            } => write!(
                f,
                "migration sequence failed closed: checksum mismatch for version {version} (applied {expected}, file {actual})"
            ),
            Self::Io(error) => write!(f, "migration I/O failed closed: {error}"),
            Self::Sql(error) => match error.as_db_error() {
                Some(db) => write!(f, "migration SQL failed closed: {}", db.message()),
                None => write!(f, "migration SQL failed closed: {error}"),
            },
            Self::DatabaseUrl => write!(f, "DATABASE_URL is required"),
        }
    }
}

impl std::error::Error for MigrateError {}

impl From<tokio_postgres::Error> for MigrateError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::Sql(error)
    }
}

impl From<std::io::Error> for MigrateError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

include!(concat!(env!("OUT_DIR"), "/bundled.rs"));

pub fn load_from_dir(path: &Path) -> Result<Vec<Migration>, MigrateError> {
    let mut files = Vec::new();
    let mut entries: Vec<_> = fs::read_dir(path)?.collect();
    entries.sort_by_key(|entry| {
        entry
            .as_ref()
            .map(|dir| dir.file_name())
            .unwrap_or_default()
    });
    for entry in entries {
        let entry = entry?;
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.ends_with(".sql") {
            continue;
        }
        let sql = fs::read_to_string(entry.path())?;
        files.push((name.into_owned(), sql));
    }
    let refs: Vec<(&str, &str)> = files
        .iter()
        .map(|(name, sql)| (name.as_str(), sql.as_str()))
        .collect();
    parse_migration_files(&refs)
}

pub fn parse_migration_files(files: &[(&str, &str)]) -> Result<Vec<Migration>, MigrateError> {
    let mut migrations = Vec::new();
    for (filename, sql) in files {
        let (version, name) = parse_filename(filename)?;
        migrations.push(Migration {
            version,
            name,
            sql: (*sql).to_string(),
        });
    }
    migrations.sort_by_key(|migration| migration.version);
    validate_sequence(&migrations)?;
    Ok(migrations)
}

pub fn parse_filename(filename: &str) -> Result<(i64, String), MigrateError> {
    let (version_part, rest) = filename
        .strip_suffix(".sql")
        .and_then(|stem| stem.split_once('_'))
        .ok_or_else(|| {
            MigrateError::Sequence(format!(
                "migration filename {filename} must match {{version}}_{{slug}}.sql"
            ))
        })?;
    let version: i64 = version_part.parse().map_err(|_| {
        MigrateError::Sequence(format!(
            "migration filename {filename} has a non-integer version"
        ))
    })?;
    if version < 1 {
        return Err(MigrateError::Sequence(format!(
            "migration version must be >= 1, got {version}"
        )));
    }
    if rest.is_empty() || !rest.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        return Err(MigrateError::Sequence(format!(
            "migration filename {filename} has an invalid slug"
        )));
    }
    Ok((version, rest.to_string()))
}

pub fn validate_sequence(migrations: &[Migration]) -> Result<(), MigrateError> {
    if migrations.is_empty() {
        return Err(MigrateError::Sequence(
            "no versioned migration files were provided".into(),
        ));
    }
    let mut seen_versions = std::collections::BTreeSet::new();
    let mut seen_names = std::collections::BTreeSet::new();
    for (index, migration) in migrations.iter().enumerate() {
        let expected = index as i64 + 1;
        if migration.version != expected {
            return Err(MigrateError::Sequence(format!(
                "versions must be contiguous from 1; expected {expected}, found {}",
                migration.version
            )));
        }
        if !seen_versions.insert(migration.version) {
            return Err(MigrateError::Sequence(format!(
                "duplicate migration version {}",
                migration.version
            )));
        }
        if !seen_names.insert(&migration.name) {
            return Err(MigrateError::Sequence(format!(
                "duplicate migration name {}",
                migration.name
            )));
        }
    }
    Ok(())
}

pub async fn connect(database_url: &str) -> Result<(Client, JoinHandle<()>), MigrateError> {
    let (client, connection) = tokio_postgres::connect(database_url, NoTls).await?;
    let handle = tokio::spawn(async move {
        if let Err(error) = connection.await {
            eprintln!("PostgreSQL connection failed: {error}");
        }
    });
    Ok((client, handle))
}

pub fn migrations_match_head(applied: &[(i64, String, String)], bundled: &[Migration]) -> bool {
    applied.len() == bundled.len()
        && applied.iter().zip(bundled.iter()).all(|(row, file)| {
            row.0 == file.version && row.1 == file.name && row.2 == file.checksum()
        })
}

async fn assert_schema_migration_shape(client: &Client) -> Result<(), MigrateError> {
    let rows = client
        .query(
            "SELECT a.attname, t.typname, a.attnotnull
             FROM pg_attribute a
             JOIN pg_class c ON c.oid = a.attrelid
             JOIN pg_namespace n ON n.oid = c.relnamespace
             JOIN pg_type t ON t.oid = a.atttypid
             WHERE n.nspname = 'public'
               AND c.relname = 'schema_migration'
               AND a.attnum > 0
               AND NOT a.attisdropped
             ORDER BY a.attnum",
            &[],
        )
        .await?;
    let expected = [
        ("version", "int8", true),
        ("name", "text", true),
        ("checksum", "text", true),
        ("applied_at", "timestamptz", true),
    ];
    if rows.len() != expected.len() {
        return Err(MigrateError::Sequence(format!(
            "schema_migration shape mismatch: expected {} columns, found {}",
            expected.len(),
            rows.len()
        )));
    }
    for (row, (name, type_name, not_null)) in rows.iter().zip(expected) {
        let found_name: String = row.get(0);
        let found_type: String = row.get(1);
        let found_not_null: bool = row.get(2);
        if found_name != name || found_type != type_name || found_not_null != not_null {
            return Err(MigrateError::Sequence(format!(
                "schema_migration shape mismatch: expected {name} {type_name} notnull={not_null}, found {found_name} {found_type} notnull={found_not_null}"
            )));
        }
    }
    Ok(())
}

pub async fn apply(
    client: &mut Client,
    migrations: &[Migration],
) -> Result<ApplyReport, MigrateError> {
    validate_sequence(migrations)?;
    client
        .query_one("SELECT pg_advisory_lock($1)", &[&MIGRATION_LOCK_KEY])
        .await?;
    let result = apply_locked(client, migrations).await;
    let unlock = client
        .query_one("SELECT pg_advisory_unlock($1)", &[&MIGRATION_LOCK_KEY])
        .await;
    match (result, unlock) {
        (Ok(report), Ok(_)) => Ok(report),
        (Err(error), _) => Err(error),
        (Ok(_), Err(error)) => Err(error.into()),
    }
}

async fn apply_locked(
    client: &mut Client,
    migrations: &[Migration],
) -> Result<ApplyReport, MigrateError> {
    client
        .batch_execute(
            "CREATE TABLE IF NOT EXISTS schema_migration (
                version bigint PRIMARY KEY,
                name text NOT NULL,
                checksum text NOT NULL,
                applied_at timestamptz NOT NULL
            )",
        )
        .await?;
    assert_schema_migration_shape(client).await?;

    let applied_rows = client
        .query(
            "SELECT version, name, checksum FROM schema_migration ORDER BY version",
            &[],
        )
        .await?;
    let mut already_applied_versions = Vec::new();
    for (index, row) in applied_rows.iter().enumerate() {
        let version: i64 = row.get(0);
        let name: String = row.get(1);
        let checksum: String = row.get(2);
        let expected_version = index as i64 + 1;
        if version != expected_version {
            return Err(MigrateError::Sequence(format!(
                "applied versions have a gap: expected {expected_version}, found {version}"
            )));
        }
        let file = migrations.get(index).ok_or_else(|| {
            MigrateError::Sequence(format!(
                "applied version {version} has no matching migration file"
            ))
        })?;
        if file.version != version || file.name != name {
            return Err(MigrateError::Sequence(format!(
                "applied version {version} ({name}) does not match file {}_{}",
                file.version, file.name
            )));
        }
        let file_checksum = file.checksum();
        if file_checksum != checksum {
            return Err(MigrateError::Checksum {
                version,
                expected: checksum,
                actual: file_checksum,
            });
        }
        already_applied_versions.push(version);
    }

    if applied_rows.len() > migrations.len() {
        return Err(MigrateError::Sequence(
            "database has more applied migrations than files".into(),
        ));
    }

    let pending = &migrations[applied_rows.len()..];
    let mut applied_versions = Vec::new();
    for migration in pending {
        let checksum = migration.checksum();
        let transaction = client.transaction().await?;
        transaction.batch_execute(&migration.sql).await?;
        transaction
            .execute(
                "INSERT INTO schema_migration (version, name, checksum, applied_at)
                 VALUES ($1, $2, $3, now())",
                &[&migration.version, &migration.name, &checksum],
            )
            .await?;
        transaction
            .batch_execute("SELECT assert_all_evidence_table_conventions()")
            .await?;
        transaction.commit().await?;
        applied_versions.push(migration.version);
    }

    client
        .batch_execute("SELECT assert_all_evidence_table_conventions()")
        .await?;

    let head_version = migrations.last().map(|migration| migration.version);
    Ok(ApplyReport {
        noop: applied_versions.is_empty(),
        applied_versions,
        already_applied_versions,
        head_version,
    })
}

pub fn checksum(sql: &str) -> String {
    let digest = Sha256::digest(sql.as_bytes());
    let mut encoded = String::with_capacity(digest.len() * 2);
    for byte in digest {
        write!(&mut encoded, "{byte:02x}").expect("writing to a String cannot fail");
    }
    encoded
}

pub fn database_url() -> Result<String, MigrateError> {
    std::env::var("DATABASE_URL").map_err(|_| MigrateError::DatabaseUrl)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn migration(version: i64, name: &str) -> Migration {
        Migration {
            version,
            name: name.into(),
            sql: format!("SELECT {version};"),
        }
    }

    #[test]
    fn parse_valid_filename() {
        assert_eq!(
            parse_filename("0001_schema_conventions.sql").unwrap(),
            (1, "schema_conventions".into())
        );
    }

    #[test]
    fn reject_non_matching_filename() {
        assert!(parse_filename("schema.sql").is_err());
        assert!(parse_filename("0001.sql").is_err());
        assert!(parse_filename("1_Has-Dash.sql").is_err());
    }

    #[test]
    fn reject_version_gap() {
        let error = validate_sequence(&[migration(1, "a"), migration(3, "b")]).unwrap_err();
        match error {
            MigrateError::Sequence(message) => {
                assert!(message.contains("contiguous"), "{message}");
            }
            other => panic!("expected sequence error, got {other}"),
        }
    }

    #[test]
    fn reject_duplicate_version_via_files() {
        let error =
            parse_migration_files(&[("0001_a.sql", "SELECT 1;"), ("0001_b.sql", "SELECT 2;")])
                .unwrap_err();
        match error {
            MigrateError::Sequence(message) => {
                assert!(message.contains("expected 2"), "{message}");
            }
            other => panic!("expected sequence error, got {other}"),
        }
    }

    #[test]
    fn bundled_migrations_match_the_directory() {
        let dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../db/migrations");
        let bundled = bundled_migrations().unwrap();
        let from_dir = load_from_dir(&dir).unwrap();
        assert_eq!(bundled, from_dir);
        assert!(bundled.len() >= 2);
        assert_eq!(bundled[0].name, "schema_conventions");
        assert_eq!(bundled[1].name, "convention_enforcement");
    }

    #[test]
    fn head_match_requires_exact_applied_prefix() {
        let bundled = bundled_migrations().unwrap();
        let head: Vec<(i64, String, String)> = bundled
            .iter()
            .map(|migration| {
                (
                    migration.version,
                    migration.name.clone(),
                    migration.checksum(),
                )
            })
            .collect();
        assert!(migrations_match_head(&head, &bundled));
        assert!(!migrations_match_head(&head[..1], &bundled));
    }
}
