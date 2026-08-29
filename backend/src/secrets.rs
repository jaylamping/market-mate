use serde::Serialize;
use std::collections::BTreeMap;

pub const PROFILE: &str = "local_research";

const ALLOWED_CONFIG_KEYS: &[&str] = &[
    "CUSTODY_URL",
    "CUSTODY_DATA_DIR",
    "CUSTODY_PORT",
    "RUST_LOG",
    "RUST_BACKTRACE",
];

const LOCAL_DATABASE_KEYS: &[&str] = &[
    "DATABASE_URL",
    "PGHOST",
    "PGPORT",
    "PGDATABASE",
    "PGUSER",
    "PGPASSWORD",
    "PGPASSFILE",
    "PGSERVICE",
    "PGSERVICEFILE",
    "PGSSLMODE",
    "PGREQUIRESSL",
    "PGSSLCERT",
    "PGSSLKEY",
    "PGSSLROOTCERT",
    "PGTARGETSESSIONATTRS",
    "PGOPTIONS",
    "PGAPPNAME",
    "PGCONNECT_TIMEOUT",
    "PGCLIENTENCODING",
    "PGDATESTYLE",
    "PGTZ",
    "PGGEQO",
    "PGLOCALEDIR",
    "PGSYSCONFDIR",
];

const LOCAL_DATABASE_PREFIXES: &[&str] = &["POSTGRES_"];

const SYSTEM_KEYS: &[&str] = &[
    "PATH",
    "HOME",
    "HOSTNAME",
    "TERM",
    "LANG",
    "LC_ALL",
    "TMPDIR",
    "PWD",
    "OLDPWD",
    "SHLVL",
    "USER",
    "SHELL",
    "LOGNAME",
    "TZ",
    "SSH_AUTH_SOCK",
    "SSH_AGENT_PID",
];

const SYSTEM_PREFIXES: &[&str] = &["LC_"];

const NAME_DETECTORS: &[(&str, &str, &str)] = &[
    (
        "password",
        "password-named-variable",
        "variable name contains password",
    ),
    (
        "passwd",
        "password-named-variable",
        "variable name contains passwd",
    ),
    (
        "secret",
        "secret-named-variable",
        "variable name contains secret",
    ),
    (
        "token",
        "token-named-variable",
        "variable name contains token",
    ),
    (
        "api_key",
        "api-key-named-variable",
        "variable name contains api_key",
    ),
    (
        "apikey",
        "api-key-named-variable",
        "variable name contains apikey",
    ),
    (
        "api-key",
        "api-key-named-variable",
        "variable name contains api-key",
    ),
    (
        "access_key",
        "access-key-named-variable",
        "variable name contains access_key",
    ),
    (
        "accesskey",
        "access-key-named-variable",
        "variable name contains accesskey",
    ),
    (
        "private_key",
        "private-key-named-variable",
        "variable name contains private_key",
    ),
    (
        "privatekey",
        "private-key-named-variable",
        "variable name contains privatekey",
    ),
    (
        "credential",
        "credential-named-variable",
        "variable name contains credential",
    ),
    (
        "signing_key",
        "signing-key-named-variable",
        "variable name contains signing_key",
    ),
    ("auth", "auth-named-variable", "variable name contains auth"),
    (
        "alpaca",
        "broker-referenced-variable",
        "variable name references broker alpaca",
    ),
    (
        "ibkr",
        "broker-referenced-variable",
        "variable name references broker ibkr",
    ),
    (
        "interactivebrokers",
        "broker-referenced-variable",
        "variable name references broker interactivebrokers",
    ),
    (
        "tws",
        "broker-referenced-variable",
        "variable name references broker tws",
    ),
    (
        "schwab",
        "broker-referenced-variable",
        "variable name references broker schwab",
    ),
    (
        "etrade",
        "broker-referenced-variable",
        "variable name references broker etrade",
    ),
    (
        "fidelity",
        "broker-referenced-variable",
        "variable name references broker fidelity",
    ),
    (
        "robinhood",
        "broker-referenced-variable",
        "variable name references broker robinhood",
    ),
    (
        "tradier",
        "broker-referenced-variable",
        "variable name references broker tradier",
    ),
    (
        "oanda",
        "broker-referenced-variable",
        "variable name references broker oanda",
    ),
    (
        "questrade",
        "broker-referenced-variable",
        "variable name references broker questrade",
    ),
    (
        "broker",
        "broker-referenced-variable",
        "variable name references broker",
    ),
];

/// (prefix, minimum body length) for platform token shapes. Single source of
/// truth consumed by both the startup scanner and the log redactor.
pub const PLATFORM_TOKEN_PREFIXES: &[(&str, usize)] = &[
    ("xox", 20),
    ("ghp_", 8),
    ("gho_", 8),
    ("ghu_", 8),
    ("ghs_", 8),
    ("ghr_", 8),
    ("github_pat_", 20),
    ("sk-", 20),
];

pub const MIN_SECRET_HEX_RUN: usize = 32;

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Violation {
    pub variable: String,
    pub detector: String,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct ScanReport {
    pub profile: &'static str,
    pub surface: String,
    pub scanned_at: String,
    pub variables_scanned: usize,
    pub allowed_config: Vec<String>,
    pub local_database_config: Vec<String>,
    pub system_variables: Vec<String>,
    pub unrecognized_variables: Vec<String>,
    pub violations: Vec<Violation>,
    pub result: &'static str,
}

impl ScanReport {
    pub fn blocked(&self) -> bool {
        !self.violations.is_empty()
    }
}

pub fn current_environment() -> BTreeMap<String, String> {
    std::env::vars_os()
        .map(|(name, value)| {
            (
                name.to_string_lossy().into_owned(),
                value.to_string_lossy().into_owned(),
            )
        })
        .collect()
}

pub fn scan_current_environment() -> ScanReport {
    scan_environment("environment", &current_environment())
}

fn is_local_database_name(name: &str) -> bool {
    LOCAL_DATABASE_KEYS.contains(&name)
        || LOCAL_DATABASE_PREFIXES.iter().any(|p| name.starts_with(p))
}

fn is_system_name(name: &str) -> bool {
    SYSTEM_KEYS.contains(&name) || SYSTEM_PREFIXES.iter().any(|p| name.starts_with(p))
}

/// Classification is for reporting only. Every variable — allowlisted or not —
/// passes through the credential detectors; classification only decides which
/// *name* detectors are skipped (libpq variables legitimately carry
/// password-shaped names, and the local profile's own DATABASE_URL legitimately
/// carries a URL password).
pub fn scan_environment(surface: &str, vars: &BTreeMap<String, String>) -> ScanReport {
    let mut allowed_config = Vec::new();
    let mut local_database_config = Vec::new();
    let mut system_variables = Vec::new();
    let mut unrecognized_variables = Vec::new();
    let mut violations = Vec::new();

    for (name, value) in vars {
        let (bucket, skip_name_detectors) = if ALLOWED_CONFIG_KEYS.contains(&name.as_str()) {
            (0, false)
        } else if is_local_database_name(name) {
            (1, true)
        } else if is_system_name(name) {
            (2, true)
        } else {
            (3, false)
        };

        let mut variable_violations: Option<Violation> = None;
        if !skip_name_detectors {
            if let Some((detector, reason)) = credential_shaped_name(name) {
                variable_violations = Some(Violation {
                    variable: name.clone(),
                    detector: detector.to_string(),
                    reason: reason.to_string(),
                });
            }
        }
        if variable_violations.is_none() {
            if let Some((detector, reason)) = credential_shaped_value(name, value) {
                variable_violations = Some(Violation {
                    variable: name.clone(),
                    detector: detector.to_string(),
                    reason: reason.to_string(),
                });
            }
        }

        match bucket {
            0 => allowed_config.push(name.clone()),
            1 => local_database_config.push(name.clone()),
            2 => system_variables.push(name.clone()),
            _ => unrecognized_variables.push(name.clone()),
        }

        if let Some(violation) = variable_violations {
            violations.push(violation);
        }
    }

    allowed_config.sort();
    local_database_config.sort();
    system_variables.sort();
    unrecognized_variables.sort();

    let blocked = !violations.is_empty();
    ScanReport {
        profile: PROFILE,
        surface: surface.to_string(),
        scanned_at: crate::receipt::utc_checkpoint_time_now(),
        variables_scanned: vars.len(),
        allowed_config,
        local_database_config,
        system_variables,
        unrecognized_variables,
        violations,
        result: if blocked { "blocked" } else { "pass" },
    }
}

pub fn credential_shaped_name(name: &str) -> Option<(&'static str, &'static str)> {
    let lower = name.to_ascii_lowercase();
    NAME_DETECTORS
        .iter()
        .find(|(needle, _, _)| lower.contains(needle))
        .map(|(_, detector, reason)| (*detector, *reason))
}

/// Full-value credential detection. `name` scopes the one narrow allowance:
/// a URL password is legitimate only in local-database connection strings.
pub fn credential_shaped_value(name: &str, value: &str) -> Option<(&'static str, &'static str)> {
    if value.contains("-----BEGIN") && value.contains("PRIVATE KEY") {
        return Some(("pem-private-key", "value embeds a PEM private key block"));
    }
    if is_jwt(value) {
        return Some(("jwt-credential", "value is a JWT credential"));
    }
    if is_aws_access_key(value) {
        return Some(("aws-access-key", "value is an AWS access key id"));
    }
    if is_platform_token(value) {
        return Some((
            "platform-token",
            "value matches a known platform token shape",
        ));
    }
    let url_password_allowed =
        is_local_database_name(name) && url_scheme(value).is_some_and(is_postgres_scheme);
    if !url_password_allowed && is_url_with_password(value) {
        return Some((
            "url-with-embedded-password",
            "value is a URL carrying embedded password credentials",
        ));
    }
    if is_long_hex(value) {
        return Some((
            "high-entropy-hex",
            "value is a high-entropy hex secret of 32 or more characters",
        ));
    }
    None
}

fn url_scheme(value: &str) -> Option<&str> {
    let scheme_end = value.find("://")?;
    Some(&value[..scheme_end])
}

fn is_postgres_scheme(scheme: &str) -> bool {
    scheme.eq_ignore_ascii_case("postgres") || scheme.eq_ignore_ascii_case("postgresql")
}

pub fn is_jwt(value: &str) -> bool {
    if !value.starts_with("eyJ") {
        return false;
    }
    let mut segments = value.split('.');
    let header = segments.next().unwrap_or_default();
    let claims = segments.next().unwrap_or_default();
    let signature = segments.next().unwrap_or_default();
    if segments.next().is_some() {
        return false;
    }
    !header.is_empty()
        && !claims.is_empty()
        && header.chars().all(is_base64url_char)
        && claims.chars().all(is_base64url_char)
        && signature.chars().all(is_base64url_char)
}

fn is_aws_access_key(value: &str) -> bool {
    (value.starts_with("AKIA") || value.starts_with("ASIA"))
        && value.len() == 20
        && value
            .chars()
            .all(|char| char.is_ascii_uppercase() || char.is_ascii_digit())
}

fn is_platform_token(value: &str) -> bool {
    for (prefix, minimum) in PLATFORM_TOKEN_PREFIXES {
        if let Some(rest) = value.strip_prefix(prefix) {
            if rest.len() >= *minimum && rest.chars().all(is_token_char) {
                return true;
            }
        }
    }
    false
}

/// Splits `rest` (the text after `://`) into its authority span, treating `/`
/// and `?` as authority terminators. Shared by the scanner and the log
/// redactor so both agree on where credentials can hide.
pub fn url_authority_span(rest: &str) -> usize {
    rest.find('/')
        .or_else(|| rest.find('?'))
        .unwrap_or(rest.len())
}

/// Returns the byte index of `:` inside the userinfo of an authority span
/// whose userinfo ends with `@`, if present.
pub fn url_userinfo_password_index(authority: &str) -> Option<usize> {
    let at_index = authority.rfind('@')?;
    let userinfo = &authority[..at_index];
    userinfo.find(':')
}

fn is_url_with_password(value: &str) -> bool {
    let Some(scheme_end) = value.find("://") else {
        return false;
    };
    let rest = &value[scheme_end + 3..];
    let authority = &rest[..url_authority_span(rest)];
    url_userinfo_password_index(authority).is_some()
}

fn is_long_hex(value: &str) -> bool {
    value.len() >= MIN_SECRET_HEX_RUN && value.chars().all(is_hex_char)
}

pub fn is_token_char(char: char) -> bool {
    char.is_ascii_alphanumeric() || char == '-' || char == '_'
}

pub fn is_base64url_char(char: char) -> bool {
    char.is_ascii_alphanumeric() || char == '-' || char == '_'
}

pub fn is_hex_char(char: char) -> bool {
    char.is_ascii_hexdigit()
}

/// Scans a character slice for a credential-shaped run (JWT, AWS key, platform
/// token, or long hex) and returns its length. Single grammar shared by the
/// startup scanner (whole-value match) and the log redactor (substring scan).
pub fn secret_run_length(chars: &[char]) -> Option<usize> {
    jwt_run_length(chars)
        .or_else(|| aws_key_run_length(chars))
        .or_else(|| platform_token_run_length(chars))
        .or_else(|| hex_run_length(chars))
}

fn jwt_run_length(chars: &[char]) -> Option<usize> {
    if chars.len() < 6 || chars[..3] != ['e', 'y', 'J'] {
        return None;
    }
    let mut index = 3;
    while index < chars.len() && is_base64url_char(chars[index]) {
        index += 1;
    }
    if index == 3 || index >= chars.len() || chars[index] != '.' {
        return None;
    }
    index += 1;
    let claims_start = index;
    while index < chars.len() && is_base64url_char(chars[index]) {
        index += 1;
    }
    if index == claims_start || index >= chars.len() || chars[index] != '.' {
        return None;
    }
    index += 1;
    while index < chars.len() && is_base64url_char(chars[index]) {
        index += 1;
    }
    Some(index)
}

fn aws_key_run_length(chars: &[char]) -> Option<usize> {
    if chars.len() < 20
        || !(chars[..4] == ['A', 'K', 'I', 'A'] || chars[..4] == ['A', 'S', 'I', 'A'])
    {
        return None;
    }
    if !chars[4..20]
        .iter()
        .all(|char| char.is_ascii_uppercase() || char.is_ascii_digit())
    {
        return None;
    }
    Some(20)
}

fn platform_token_run_length(chars: &[char]) -> Option<usize> {
    for (prefix, minimum) in PLATFORM_TOKEN_PREFIXES {
        let prefix_chars: Vec<char> = prefix.chars().collect();
        if chars.len() >= prefix_chars.len() + minimum
            && chars[..prefix_chars.len()] == prefix_chars[..]
        {
            let mut index = prefix_chars.len();
            while index < chars.len() && is_token_char(chars[index]) {
                index += 1;
            }
            if index - prefix_chars.len() >= *minimum {
                return Some(index);
            }
        }
    }
    None
}

fn hex_run_length(chars: &[char]) -> Option<usize> {
    let mut index = 0;
    while index < chars.len() && is_hex_char(chars[index]) {
        index += 1;
    }
    (index >= MIN_SECRET_HEX_RUN).then_some(index)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn vars(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(key, value)| (key.to_string(), value.to_string()))
            .collect()
    }

    fn violation_variables(report: &ScanReport) -> Vec<String> {
        report
            .violations
            .iter()
            .map(|violation| violation.variable.clone())
            .collect()
    }

    #[test]
    fn local_profile_passes_on_known_operational_config() {
        let report = scan_environment(
            "test",
            &vars(&[
                (
                    "DATABASE_URL",
                    "postgres://mm:local-only@postgres:5432/market_mate",
                ),
                ("CUSTODY_URL", "http://custody:8081"),
                ("PATH", "/usr/local/bin:/usr/bin"),
                ("HOSTNAME", "abc123def456"),
                ("POSTGRES_PASSWORD", "local-only"),
                ("PGPASSWORD", "local-only"),
                ("UNKNOWN_FEATURE_FLAG", "enabled"),
            ]),
        );
        assert!(!report.blocked(), "{report:?}");
        assert_eq!(report.result, "pass");
        assert!(report.allowed_config.contains(&"CUSTODY_URL".to_string()));
        assert!(report
            .local_database_config
            .contains(&"DATABASE_URL".to_string()));
        assert!(report.system_variables.contains(&"PATH".to_string()));
        assert!(report
            .unrecognized_variables
            .contains(&"UNKNOWN_FEATURE_FLAG".to_string()));
    }

    #[test]
    fn broker_credential_names_are_blocked() {
        for name in [
            "ALPACA_API_KEY",
            "ALPACA_SECRET",
            "IBKR_CLIENT_TOKEN",
            "BROKER_PASSWORD",
            "SCHWAB_ACCESS_KEY",
            "TRADING_APIKEY",
            "MY_PRIVATE_KEY",
            "GITHUB_TOKEN",
            "OAUTH_CLIENT_SECRET",
        ] {
            let report = scan_environment("test", &vars(&[(name, "some-value")]));
            assert!(report.blocked(), "{name} should be blocked");
            assert_eq!(violation_variables(&report), vec![name.to_string()]);
        }
    }

    #[test]
    fn credential_shaped_values_are_blocked_regardless_of_name() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----";
        let jwt =
            "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjMifQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJVadQssw5c";
        let aws = "AKIAIOSFODNN7EXAMPLE";
        let long_hex = "a".repeat(64);

        for (name, value) in [
            ("CERT_BLOB", pem),
            ("SESSION_COOKIE", jwt),
            ("LEGACY_ID", aws),
            ("WORKER_ID", long_hex.as_str()),
        ] {
            let report = scan_environment("test", &vars(&[(name, value)]));
            assert!(report.blocked(), "{name} value should be blocked");
            assert_eq!(violation_variables(&report), vec![name.to_string()]);
        }
    }

    #[test]
    fn allowlisted_names_still_get_value_checked() {
        let secret_url = "http://key:supersecretvalue123@api.example.com";
        let report = scan_environment("test", &vars(&[("CUSTODY_URL", secret_url)]));
        assert!(
            report.blocked(),
            "URL password under CUSTODY_URL must block"
        );
        assert_eq!(report.violations[0].detector, "url-with-embedded-password");

        let pg_broker_token = "a".repeat(64);
        let report = scan_environment(
            "test",
            &vars(&[("PG_BROKER_TOKEN", pg_broker_token.as_str())]),
        );
        assert!(report.blocked(), "PG-prefixed credential name must block");
        assert_eq!(
            violation_variables(&report),
            vec!["PG_BROKER_TOKEN".to_string()]
        );
    }

    #[test]
    fn non_postgres_url_password_under_database_name_is_blocked() {
        let report = scan_environment(
            "test",
            &vars(&[("DATABASE_URL", "https://user:hunter2@db.internal/proxy")]),
        );
        assert!(
            report.blocked(),
            "non-postgres scheme must not get the URL-password allowance"
        );
    }

    #[test]
    fn postgres_url_password_stays_allowed_under_local_database_names() {
        for name in ["DATABASE_URL", "POSTGRES_BACKUP_URL"] {
            let report = scan_environment(
                "test",
                &vars(&[(name, "postgres://mm:local-only@postgres:5432/market_mate")]),
            );
            assert!(
                is_local_database_name(name),
                "{name} should be local-database class"
            );
            assert!(!report.blocked(), "{name} postgres URL must stay allowed");
        }
    }

    #[test]
    fn pg_like_names_outside_the_libpq_list_get_full_detection() {
        let long_hex = "a".repeat(64);
        let report = scan_environment("test", &vars(&[("PGHOST_URL", long_hex.as_str())]));
        assert!(
            report.blocked(),
            "PG-prefixed non-libpq name must be value-checked: {report:?}"
        );
    }

    #[test]
    fn system_names_skip_name_detectors_but_not_value_detectors() {
        let report = scan_environment(
            "test",
            &vars(&[
                ("SSH_AUTH_SOCK", "/tmp/agent.sock"),
                ("POSTGRES_PASSWORD", "a".repeat(64).as_str()),
            ]),
        );
        assert!(
            report.blocked(),
            "64-hex under POSTGRES_PASSWORD must block"
        );
        assert_eq!(report.violations[0].detector, "high-entropy-hex");

        let report = scan_environment("test", &vars(&[("SSH_AUTH_SOCK", "/tmp/agent.sock")]));
        assert!(!report.blocked(), "{report:?}");
    }

    #[test]
    fn benign_values_do_not_trip_value_detectors() {
        for value in [
            "local-only",
            "http://custody:8081",
            "abc123",
            "postgres",
            "/var/lib/custody",
            "2026-08-29T00:00:00.000000Z",
        ] {
            assert!(
                credential_shaped_value("SOME_NAME", value).is_none(),
                "{value} should not be credential-shaped"
            );
        }
    }

    #[test]
    fn report_never_contains_values() {
        let secret_value = "supersecretbrokercredentialvalue";
        let report = scan_environment("test", &vars(&[("ALPACA_API_KEY", secret_value)]));
        let serialized = serde_json::to_string(&report).unwrap();
        assert!(!serialized.contains(secret_value), "{serialized}");
        assert!(serialized.contains("ALPACA_API_KEY"));
    }

    #[test]
    fn database_url_is_classified_as_local_database_not_violation() {
        assert_eq!(
            credential_shaped_name("DATABASE_URL"),
            None,
            "DATABASE_URL must not trip the name detectors"
        );
    }

    #[test]
    fn jwt_requires_exactly_three_segments() {
        assert!(is_jwt("eyJhbGciOiJIUzI1NiJ9.eyJhIjoiYiJ9.c2ln"));
        assert!(!is_jwt("eyJhbGciOiJIUzI1NiJ9.eyJhIjoiYiJ9.c2ln.extra"));
        assert!(!is_jwt("eyJshort"));
    }

    #[test]
    fn url_terminators_agree_between_scanner_and_redactor() {
        let value = "https://user:pass@example.com/path?q=secret";
        assert!(is_url_with_password(value));
        let rest = &value["https://".len()..];
        let authority = &rest[..url_authority_span(rest)];
        assert_eq!(authority, "user:pass@example.com");
        assert_eq!(url_userinfo_password_index(authority), Some(4));
    }
}
