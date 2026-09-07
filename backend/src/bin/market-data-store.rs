use serde_json::{json, Value};
use std::{io::Read, path::Path};

async fn run() -> Result<Value, &'static str> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.as_slice() == ["--help"] {
        return Ok(
            json!({"usage":["market-data-store configure SOURCE_VERSION_UUID ENTITLEMENT_VERSION_UUID","market-data-store import SOURCE_UUID DOWNLOAD.json","market-data-store list","market-data-store cleanup","market-data-store remove-source SOURCE_UUID"],"database":"MARKET_DATA_DATABASE_URL","note":"Uses pre-existing source/entitlement records. remove-source irreversibly removes this source's active stored inputs/results, including referenced experiments; external files and backups are not removed."}),
        );
    }
    let (sql, first, second): (&str, Option<&str>, Option<Value>) =
        match args.first().map(String::as_str) {
            Some("configure") if args.len() == 3 => ("", None, None),
            Some("import") if args.len() == 3 => {
                let mut bytes = Vec::new();
                std::fs::File::open(Path::new(&args[2]))
                    .map_err(|_| "download_unreadable")?
                    .take(2_000_001)
                    .read_to_end(&mut bytes)
                    .map_err(|_| "download_unreadable")?;
                let bundle = backend::market_data::validate_download(&bytes)
                    .map_err(|_| "invalid_download")?;
                (
                    "SELECT to_jsonb(register_market_data_download($1::text::uuid,$2))",
                    Some(&args[1]),
                    Some(bundle),
                )
            }
            Some("list") if args.len() == 1 => ("SELECT read_market_data_catalog()", None, None),
            Some("cleanup") if args.len() == 1 => {
                ("SELECT to_jsonb(cleanup_market_data_cache())", None, None)
            }
            Some("remove-source") if args.len() == 2 => (
                "SELECT remove_market_data_source($1::text::uuid)",
                Some(&args[1]),
                None,
            ),
            _ => return Err("invalid_arguments; use --help"),
        };
    let url = std::env::var("MARKET_DATA_DATABASE_URL").map_err(|_| "database_not_configured")?;
    let (client, connection) = tokio_postgres::connect(&url, tokio_postgres::NoTls)
        .await
        .map_err(|_| "database_unavailable")?;
    tokio::spawn(async move {
        let _ = connection.await;
    });
    let row = if args[0] == "configure" {
        client
            .query_one(
                "SELECT to_jsonb(configure_market_data_source($1::text::uuid,$2::text::uuid))",
                &[&args[1], &args[2]],
            )
            .await
    } else {
        match (first, second) {
            (Some(first), Some(second)) => client.query_one(sql, &[&first, &second]).await,
            (Some(first), None) => client.query_one(sql, &[&first]).await,
            _ => client.query_one(sql, &[]).await,
        }
    }
    .map_err(|_| {
        "storage_operation_rejected; inspect request, source status and database permissions"
    })?;
    Ok(row.get(0))
}
#[tokio::main]
async fn main() {
    match run().await {
        Ok(value) => println!("{value}"),
        Err(error) => {
            eprintln!("market_data_store_failed: {error}");
            std::process::exit(1);
        }
    }
}
