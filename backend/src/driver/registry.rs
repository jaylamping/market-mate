//! Provider registry rows, credentials, and catalogs. Credentials never leave this module as text.
use reqwest::header::HeaderValue;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Provider {
    pub id: String,
    pub display_name: String,
    pub kind: String,
    pub protocol: String,
    pub base_url: String,
    pub credential_path: String,
    pub catalog_source: String,
    #[serde(default)]
    pub catalog_url: Option<String>,
    #[serde(default)]
    pub static_models: Vec<Value>,
    #[serde(default)]
    pub usage_url: Option<String>,
    #[serde(default)]
    pub status_url: Option<String>,
    #[serde(default)]
    pub settings: Value,
    pub enabled: bool,
    pub revision: i64,
    #[serde(default)]
    pub windows: Vec<Value>,
    #[serde(default)]
    pub state: Value,
}
impl Provider {
    pub fn is_openrouter(&self) -> bool {
        self.settings["admission"] == "openrouter_capacity"
    }
    pub fn protocol_for(&self, model: &str) -> &str {
        self.settings["model_protocols"][model]
            .as_str()
            .unwrap_or(self.protocol.as_str())
    }
    pub fn credential_state(&self) -> &'static str {
        match std::fs::metadata(&self.credential_path) {
            Ok(m) if m.len() > 0 && m.len() <= 1024 => "configured",
            _ => "not_configured",
        }
    }
    pub fn to_json(&self) -> Value {
        let mut value = serde_json::to_value(self).unwrap_or(Value::Null);
        value["credential_state"] = json!(self.credential_state());
        value
    }
}
pub fn parse_providers(value: &Value) -> Vec<Provider> {
    value
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|row| serde_json::from_value(row.clone()).ok())
        .collect()
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Credentials {
    api_key: String,
}
/// Bearer header for a stored key. Z.ai plan keys contain a dot, so the alphabet is wider than OpenRouter's.
pub fn authorization(key: &str) -> Result<HeaderValue, &'static str> {
    if key.is_empty()
        || key.len() > 512
        || !key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"_-.".contains(&b))
    {
        return Err("invalid_credentials");
    }
    let mut value =
        HeaderValue::from_str(&format!("Bearer {key}")).map_err(|_| "invalid_credentials")?;
    value.set_sensitive(true);
    Ok(value)
}
pub fn read_credentials(path: &Path) -> Result<(HeaderValue, String), &'static str> {
    let bytes = std::fs::read(path).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            "not_configured"
        } else {
            "invalid_credentials"
        }
    })?;
    if bytes.len() > 1024 {
        return Err("invalid_credentials");
    }
    let credentials: Credentials =
        serde_json::from_slice(&bytes).map_err(|_| "invalid_credentials")?;
    Ok((authorization(&credentials.api_key)?, credentials.api_key))
}
pub fn credential_path(provider: &Provider) -> PathBuf {
    PathBuf::from(&provider.credential_path)
}

#[derive(Clone, Serialize, Deserialize)]
pub struct Model {
    pub id: String,
    pub name: String,
    pub context_length: u64,
    pub pricing: BTreeMap<String, Value>,
    #[serde(default)]
    pub protocol: Option<String>,
    #[serde(default, flatten)]
    pub capabilities: crate::openrouter_request::Capabilities,
}
fn zero_pricing() -> BTreeMap<String, Value> {
    BTreeMap::from([
        ("prompt".to_string(), json!("0")),
        ("completion".to_string(), json!("0")),
    ])
}
/// Normalize catalog rows from OpenAI-style `{data:[{id,...}]}`, Cursor's `{items:[{id,displayName}]}`,
/// or the registry's static list.
pub fn catalog_models(provider: &Provider, value: &Value) -> Vec<Model> {
    let rows = value
        .get("data")
        .and_then(Value::as_array)
        .or_else(|| value.get("items").and_then(Value::as_array))
        .or_else(|| value.get("models").and_then(Value::as_array))
        .or_else(|| value.as_array());
    let filter = provider.settings["model_filter"].as_str();
    let mut models = Vec::new();
    for row in rows.into_iter().flatten() {
        let id = match row["id"].as_str() {
            Some(id) if !id.is_empty() && id.len() <= 256 && !id.starts_with("openrouter/") => id,
            _ => continue,
        };
        let pricing: BTreeMap<String, Value> = row
            .get("pricing")
            .and_then(|p| serde_json::from_value(p.clone()).ok())
            .unwrap_or_else(zero_pricing);
        let free = pricing
            .get("prompt")
            .and_then(Value::as_str)
            .is_some_and(|p| p.parse::<f64>().is_ok_and(|n| n == 0.0))
            && pricing
                .get("completion")
                .and_then(Value::as_str)
                .is_some_and(|p| p.parse::<f64>().is_ok_and(|n| n == 0.0));
        match filter {
            Some(":free") if !id.ends_with(":free") || !free => continue,
            Some("paid") if id.ends_with(":free") => continue,
            _ => (),
        }
        let capabilities = serde_json::from_value(row.clone()).unwrap_or_default();
        models.push(Model {
            id: id.to_string(),
            name: row["name"]
                .as_str()
                .or_else(|| row["displayName"].as_str())
                .map(str::to_string)
                .unwrap_or_else(|| id.to_string()),
            context_length: row["context_length"]
                .as_u64()
                .or_else(|| row["limit"]["context"].as_u64())
                .unwrap_or(0),
            pricing,
            protocol: Some(provider.protocol_for(id).to_string()),
            capabilities,
        });
    }
    models.sort_by(|a, b| a.id.cmp(&b.id));
    models.dedup_by(|a, b| a.id == b.id);
    models
}
pub fn static_models(provider: &Provider) -> Vec<Model> {
    catalog_models(provider, &Value::Array(provider.static_models.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn provider(settings: Value) -> Provider {
        Provider {
            id: "p".into(),
            display_name: "P".into(),
            kind: "subscription".into(),
            protocol: "openai_chat".into(),
            base_url: "https://example.test/v1".into(),
            credential_path: "/nonexistent/credentials.json".into(),
            catalog_source: "live".into(),
            catalog_url: None,
            static_models: vec![json!({"id":"glm-5.3-flash","name":"Flash","context_length":1000})],
            usage_url: None,
            status_url: None,
            settings,
            enabled: true,
            revision: 0,
            windows: vec![],
            state: Value::Null,
        }
    }
    #[test]
    fn model_protocol_overrides_and_static_catalog_default_to_zero_pricing() {
        let p =
            provider(json!({"model_protocols":{"muse-spark-1.3-contributor":"openai_responses"}}));
        assert_eq!(p.protocol_for("glm-5.3-flash"), "openai_chat");
        assert_eq!(
            p.protocol_for("muse-spark-1.3-contributor"),
            "openai_responses"
        );
        let models = static_models(&p);
        assert_eq!(models.len(), 1);
        assert_eq!(models[0].pricing["prompt"], "0");
        assert_eq!(p.credential_state(), "not_configured");
        assert_eq!(p.to_json()["credential_state"], "not_configured");
    }
    #[test]
    fn cursor_items_catalog_is_readable_as_catalog_only_rows() {
        let catalog = json!({"items":[{"id":"composer-2","displayName":"Composer 2","aliases":["composer"]},{"id":"auto","displayName":"Auto"}]});
        let models = catalog_models(&provider(json!({})), &catalog);
        assert_eq!(
            models
                .iter()
                .map(|m| (m.id.as_str(), m.name.as_str()))
                .collect::<Vec<_>>(),
            [("auto", "Auto"), ("composer-2", "Composer 2")]
        );
        assert_eq!(models[0].pricing["prompt"], "0");
    }
    #[test]
    fn openrouter_catalog_is_split_between_free_and_paid_registrations() {
        let catalog = json!({"data":[
            {"id":"vendor/free:free","name":"Free","context_length":1000,"pricing":{"prompt":"0","completion":"0"}},
            {"id":"vendor/paid","name":"Paid","context_length":1000,"pricing":{"prompt":"0.01","completion":"0.02"}},
            {"id":"vendor/fake:free","name":"Charges","context_length":1000,"pricing":{"prompt":"0.01","completion":"0"}},
            {"id":"openrouter/auto","name":"Router","context_length":1000,"pricing":{"prompt":"0","completion":"0"}}
        ]});
        let free = catalog_models(&provider(json!({"model_filter":":free"})), &catalog);
        assert_eq!(
            free.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["vendor/free:free"]
        );
        let paid = catalog_models(&provider(json!({"model_filter":"paid"})), &catalog);
        assert_eq!(
            paid.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(),
            ["vendor/paid"]
        );
    }
    #[test]
    fn credentials_accept_dotted_plan_keys_and_reject_header_injection() {
        assert!(authorization("abc.def-123_x").unwrap().is_sensitive());
        assert!(authorization("bad\r\nheader").is_err());
        assert!(authorization("").is_err());
        assert_eq!(
            read_credentials(Path::new("/nonexistent-driver/credentials.json")).unwrap_err(),
            "not_configured"
        );
    }
}
