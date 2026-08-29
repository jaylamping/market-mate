mod migrate;

use axum::{http::StatusCode, routing::get, Json, Router};
use migrate::{apply, bundled_migrations, connect, database_url, load_from_dir, ApplyReport};
use std::path::PathBuf;
use std::time::Duration;
use tokio::time::timeout;
use tokio_postgres::NoTls;

const DATABASE_READINESS_TIMEOUT: Duration = Duration::from_secs(2);

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

#[derive(serde::Serialize)]
struct Readiness {
    status: &'static str,
    service: &'static str,
    database: bool,
    migrations: bool,
}

async fn readyz() -> (StatusCode, Json<Readiness>) {
    let (database, migrations) = database_is_ready().await;
    let ok = database && migrations;
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
        }),
    )
}

async fn database_is_ready() -> (bool, bool) {
    let Ok(database_url) = std::env::var("DATABASE_URL") else {
        return (false, false);
    };

    let readiness = async {
        let (client, connection) = tokio_postgres::connect(&database_url, NoTls).await?;
        tokio::spawn(async move {
            if let Err(error) = connection.await {
                eprintln!("PostgreSQL readiness connection failed: {error}");
            }
        });
        client.simple_query("SELECT 1").await?;
        let migrated = client
            .query_opt("SELECT 1 FROM schema_migration WHERE version = 1", &[])
            .await?;
        Ok::<_, tokio_postgres::Error>(migrated.is_some())
    };

    match timeout(DATABASE_READINESS_TIMEOUT, readiness).await {
        Ok(Ok(migrations)) => (true, migrations),
        Ok(Err(_)) | Err(_) => (false, false),
    }
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
    apply(&mut client, &migrations).await.unwrap_or_else(|error| {
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
    let app = Router::new()
        .route("/healthz", get(healthz))
        .route("/readyz", get(readyz));
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
