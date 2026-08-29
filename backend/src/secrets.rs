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

const LOCAL_DATABASE_KEYS: &[&str] = &["DATABASE_URL"];

const LOCAL_DATABASE_PREFIXES: &[&str] = &["POSTGRES_", "PG"];

const SYSTEM_KEYS: &[&str] = &[
    "PATH", "HOME", "HOSTNAME", "TERM", "LANG", "LC_ALL", "TMPDIR", "PWD", "OLDPWD", "SHLVL",
    "USER", "SHELL", "LOGNAME", "TZ",
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
    std::env::vars().collect()
}

pub fn scan_current_environment() -> ScanReport {
    scan_environment("environment", &current_environment())
}

pub fn scan_environment(surface: &str, vars: &BTreeMap<String, String>) -> ScanReport {
    let mut allowed_config = Vec::new();
    let mut local_database_config = Vec::new();
    let mut system_variables = Vec::new();
    let mut unrecognized_variables = Vec::new();
    let mut violations = Vec::new();

    for (name, value) in vars {
        if ALLOWED_CONFIG_KEYS.contains(&name.as_str()) {
            allowed_config.push(name.clone());
        } else if LOCAL_DATABASE_KEYS.contains(&name.as_str())
            || LOCAL_DATABASE_PREFIXES.iter().any(|p| name.starts_with(p))
        {
            local_database_config.push(name.clone());
        } else if SYSTEM_KEYS.contains(&name.as_str())
            || SYSTEM_PREFIXES.iter().any(|p| name.starts_with(p))
        {
            system_variables.push(name.clone());
        } else if let Some((detector, reason)) = credential_shaped_name(name) {
            violations.push(Violation {
                variable: name.clone(),
                detector: detector.to_string(),
                reason: reason.to_string(),
            });
        } else if let Some((detector, reason)) = credential_shaped_value(value) {
            violations.push(Violation {
                variable: name.clone(),
                detector: detector.to_string(),
                reason: reason.to_string(),
            });
        } else {
            unrecognized_variables.push(name.clone());
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

pub fn credential_shaped_value(value: &str) -> Option<(&'static str, &'static str)> {
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
    if is_url_with_password(value) {
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

fn is_token_char(char: char) -> bool {
    char.is_ascii_alphanumeric() || char == '-' || char == '_'
}

fn is_base64url_char(char: char) -> bool {
    char.is_ascii_alphanumeric() || char == '-' || char == '_'
}

fn is_hex_char(char: char) -> bool {
    char.is_ascii_hexdigit()
}

fn is_jwt(value: &str) -> bool {
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
    for prefix in [
        "xox",
        "ghp_",
        "gho_",
        "ghu_",
        "ghs_",
        "ghr_",
        "github_pat_",
        "sk-",
    ] {
        if let Some(rest) = value.strip_prefix(prefix) {
            let minimum = if prefix.starts_with("xox") || prefix.starts_with("sk") {
                20
            } else {
                8
            };
            if rest.len() >= minimum && rest.chars().all(is_token_char) {
                return true;
            }
        }
    }
    false
}

fn is_url_with_password(value: &str) -> bool {
    let Some(scheme_end) = value.find("://") else {
        return false;
    };
    let authority_start = scheme_end + 3;
    let authority_end = value[authority_start..]
        .find('/')
        .map(|index| authority_start + index)
        .unwrap_or(value.len());
    let authority = &value[authority_start..authority_end];
    let Some(at_index) = authority.rfind('@') else {
        return false;
    };
    let userinfo = &authority[..at_index];
    userinfo.contains(':')
}

fn is_long_hex(value: &str) -> bool {
    value.len() >= 32 && value.chars().all(is_hex_char)
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
                credential_shaped_value(value).is_none(),
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
}
