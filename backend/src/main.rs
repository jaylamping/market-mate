use axum::{
    extract::State,
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use backend::{
    checkpoints::{
        execute_checkpoint_flow, run_restore_verification, CustodyClient, RestoreVerification,
    },
    migrate::{
        apply, bundled_migrations, connect, database_url, load_from_dir, migrations_match_head,
        ApplyReport,
    },
};
use std::{
    path::PathBuf,
    sync::{Arc, RwLock},
    time::Duration,
};
use tokio::time::{sleep, timeout};
use tokio_postgres::NoTls;

const DATABASE_READINESS_TIMEOUT: Duration = Duration::from_secs(2);
const VERIFICATION_RETRY: Duration = Duration::from_secs(3);
const VERIFICATION_MAX_ATTEMPTS: u32 = 200;

#[derive(serde::Serialize)]
struct Health {
    status: &'static str,
    service: &'static str,
    environment: &'static str,
}

async fn healthz() -> Json<Health> {
    Json(Health {
        status: "ok",
        service: "backend",
        environment: "local-research",
    })
}

#[derive(Clone)]
struct AppState {
    custody: Arc<CustodyClient>,
    verification: Arc<RwLock<RestoreVerification>>,
}

impl AppState {
    fn verification_snapshot(&self) -> RestoreVerification {
        self.verification
            .read()
            .expect("verification state must not poison")
            .clone()
    }
}

#[derive(serde::Serialize)]
struct Readiness {
    status: &'static str,
    service: &'static str,
    database: bool,
    migrations: bool,
    checkpoints: bool,
    checkpoint_pending: bool,
    checkpoint_failure: Option<serde_json::Value>,
}

async fn readyz(State(state): State<AppState>) -> (StatusCode, Json<Readiness>) {
    let verification = state.verification_snapshot();
    let (database, migrations) = database_is_ready().await;
    let checkpoints_ok = !verification.pending && verification.valid;
    let ok = database && migrations && checkpoints_ok;
    let status = if ok { "ok" } else { "unavailable" };
    let code = if ok {
        StatusCode::OK
    } else {
        StatusCode::SERVICE_UNAVAILABLE
    };
    (
        code,
        Json(Readiness {
            status,
            service: "backend",
            database,
            migrations,
            checkpoints: checkpoints_ok,
            checkpoint_pending: verification.pending,
            checkpoint_failure: verification
                .first_failure
                .as_ref()
                .map(|failure| serde_json::to_value(failure).unwrap_or_default()),
        }),
    )
}

async fn database_is_ready() -> (bool, bool) {
    let Ok(database_url) = std::env::var("DATABASE_URL") else {
        return (false, false);
    };

    let connect = async {
        let (client, connection) = tokio_postgres::connect(&database_url, NoTls).await?;
        tokio::spawn(async move {
            if let Err(error) = connection.await {
                eprintln!("PostgreSQL readiness connection failed: {error}");
            }
        });
        client.simple_query("SELECT 1").await?;
        Ok::<_, tokio_postgres::Error>(client)
    };

    let client = match timeout(DATABASE_READINESS_TIMEOUT, connect).await {
        Ok(Ok(client)) => client,
        Ok(Err(_)) | Err(_) => return (false, false),
    };

    let Ok(bundled) = bundled_migrations() else {
        return (true, false);
    };
    let Ok(rows) = client
        .query(
            "SELECT version, name, checksum FROM schema_migration ORDER BY version",
            &[],
        )
        .await
    else {
        return (true, false);
    };
    let applied: Vec<(i64, String, String)> = rows
        .iter()
        .map(|row: &tokio_postgres::Row| (row.get(0), row.get(1), row.get(2)))
        .collect();
    (true, migrations_match_head(&applied, &bundled))
}

fn local_lineage(source: &str) -> serde_json::Value {
    serde_json::json!({
        "source": source,
        "entitlement_version": "local-v1"
    })
}

async fn append_restore_event(
    client: &tokio_postgres::Client,
    verification: &RestoreVerification,
) -> Result<i64, String> {
    let payload = serde_json::json!({
        "receipts_checked": verification.receipts_checked,
        "head_position": verification.head_position,
        "chain_checked_events": verification.chain_checked_events,
    });
    let lineage = local_lineage("backend-restore-verification");
    let row = client
        .query_one(
            "SELECT chain_position FROM append_audit_event(
                'restore-verified-' || gen_random_uuid()::text,
                'backend.restore_verified',
                now(),
                $1,
                $2,
                now(),
                'local_research'
            )",
            &[&payload, &lineage],
        )
        .await
        .map_err(|error| format!("restore.verified audit append failed: {error}"))?;
    Ok(row.get(0))
}

async fn verify_until_valid_or_exhausted(state: &AppState, database_url: &str) {
    for attempt in 1..=VERIFICATION_MAX_ATTEMPTS {
        let attempted = async {
            let (client, _connection) = connect(database_url)
                .await
                .map_err(|error| error.to_string())?;
            let report = run_restore_verification(&client, &state.custody).await;
            if !report.valid {
                return Ok(Err(report));
            }
            match append_restore_event(&client, &report).await {
                Ok(position) => Ok(Ok((report, position))),
                Err(error) => Err(error),
            }
        };
        match attempted.await {
            Ok(Ok((report, event_position))) => {
                eprintln!(
                    "restore verification passed: receipts={}, head_position={:?}, audit position {event_position}",
                    report.receipts_checked, report.head_position
                );
                let mut guard = state
                    .verification
                    .write()
                    .expect("verification state must not poison");
                *guard = report;
                return;
            }
            Ok(Err(report)) => {
                if let Some(failure) = &report.first_failure {
                    eprintln!(
                        "restore verification attempt {attempt} failed: {} ({})",
                        failure.reason, failure.detail
                    );
                } else {
                    eprintln!("restore verification attempt {attempt} failed");
                }
                let mut guard = state
                    .verification
                    .write()
                    .expect("verification state must not poison");
                *guard = report;
            }
            Err(error) => {
                eprintln!("restore verification attempt {attempt} errored: {error}");
            }
        }
        sleep(VERIFICATION_RETRY).await;
    }
    eprintln!("restore verification never became valid; refusing readiness");
}

async fn create_checkpoint(State(state): State<AppState>) -> (StatusCode, Json<serde_json::Value>) {
    let verification = state.verification_snapshot();
    if verification.pending || !verification.valid {
        return (
            StatusCode::SERVICE_UNAVAILABLE,
            Json(serde_json::json!({
                "error": "restore verification has not passed; checkpoints are unavailable"
            })),
        );
    }

    let database_url = match database_url() {
        Ok(url) => url,
        Err(error) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "error": error.to_string() })),
            );
        }
    };
    let (client, _connection) = match connect(&database_url).await {
        Ok(pair) => pair,
        Err(error) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "error": format!("database connect failed: {error}") })),
            );
        }
    };

    match execute_checkpoint_flow(&client, &state.custody).await {
        Ok((receipt, audit_position)) => (
            StatusCode::CREATED,
            Json(serde_json::json!({
                "receipt": receipt,
                "audit_chain_position": audit_position,
            })),
        ),
        Err((code, message)) => (code, Json(serde_json::json!({ "error": message }))),
    }
}

async fn restore_verification(
    State(state): State<AppState>,
) -> (StatusCode, Json<serde_json::Value>) {
    let database_url = match database_url() {
        Ok(url) => url,
        Err(error) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "error": error.to_string() })),
            );
        }
    };
    let (client, _connection) = match connect(&database_url).await {
        Ok(pair) => pair,
        Err(error) => {
            return (
                StatusCode::SERVICE_UNAVAILABLE,
                Json(serde_json::json!({ "error": format!("database connect failed: {error}") })),
            );
        }
    };
    let report = run_restore_verification(&client, &state.custody).await;
    let code = if report.valid {
        StatusCode::OK
    } else {
        StatusCode::CONFLICT
    };
    (
        code,
        Json(serde_json::to_value(&report).unwrap_or_default()),
    )
}

struct Cli {
    migrate_only: bool,
    from_dir: Option<PathBuf>,
}

fn parse_cli(args: &[String]) -> Result<Cli, String> {
    if args.len() <= 1 {
        return Ok(Cli {
            migrate_only: false,
            from_dir: None,
        });
    }
    match args[1].as_str() {
        "serve" => Ok(Cli {
            migrate_only: false,
            from_dir: None,
        }),
        "migrate" => {
            let mut from_dir = None;
            let mut index = 2;
            while index < args.len() {
                match args[index].as_str() {
                    "--from-dir" => {
                        let dir = args.get(index + 1).ok_or("--from-dir requires a path")?;
                        from_dir = Some(PathBuf::from(dir));
                        index += 2;
                    }
                    other => return Err(format!("unknown migrate argument: {other}")),
                }
            }
            Ok(Cli {
                migrate_only: true,
                from_dir,
            })
        }
        other => Err(format!("unknown command: {other}")),
    }
}

async fn run_migrations(from_dir: Option<PathBuf>) -> ApplyReport {
    let database_url = database_url().unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(1);
    });
    let migrations = match from_dir {
        Some(path) => load_from_dir(&path),
        None => bundled_migrations(),
    };
    let migrations = migrations.unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(1);
    });
    let (mut client, _connection) = connect(&database_url).await.unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(1);
    });
    apply(&mut client, &migrations)
        .await
        .unwrap_or_else(|error| {
            eprintln!("{error}");
            std::process::exit(1);
        })
}

async fn serve() {
    let report = run_migrations(None).await;
    if !report.noop {
        eprintln!(
            "applied migrations {:?}; head {:?}",
            report.applied_versions, report.head_version
        );
    }
    let custody_url =
        std::env::var("CUSTODY_URL").unwrap_or_else(|_| "http://custody:8081".to_string());
    let state = AppState {
        custody: Arc::new(CustodyClient::new(custody_url)),
        verification: Arc::new(RwLock::new(RestoreVerification::pending())),
    };
    let database_url = database_url().expect("DATABASE_URL is required to serve");
    let verification_state = state.clone();
    tokio::spawn(async move {
        verify_until_valid_or_exhausted(&verification_state, &database_url).await;
    });

    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz))
        .route("/checkpoints", post(create_checkpoint))
        .route("/restore-verification", post(restore_verification))
        .with_state(state);
    let listener = tokio::net::TcpListener::bind("0.0.0.0:8080")
        .await
        .expect("backend listener must bind");
    axum::serve(listener, app)
        .await
        .expect("backend server must run");
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let cli = parse_cli(&args).unwrap_or_else(|error| {
        eprintln!("{error}");
        std::process::exit(2);
    });
    if cli.migrate_only {
        let report = run_migrations(cli.from_dir).await;
        println!(
            "{}",
            serde_json::to_string(&report).expect("apply report must serialize")
        );
        return;
    }
    serve().await;
}
