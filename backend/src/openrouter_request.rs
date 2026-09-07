//! Adapt optional formatting to current catalog capabilities without removing spending bounds.
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Capabilities {
    #[serde(default)]
    pub supported_parameters: Option<Vec<String>>,
    #[serde(default)]
    pub architecture: Option<Architecture>,
    #[serde(default)]
    pub top_provider: Option<ProviderLimits>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct Architecture {
    #[serde(default)]
    input_modalities: Vec<String>,
    #[serde(default)]
    output_modalities: Vec<String>,
}
#[derive(Clone, Serialize, Deserialize)]
pub struct ProviderLimits {
    max_completion_tokens: Option<u64>,
}
impl Capabilities {
    pub fn adapt(&self, request: &Value) -> Result<Value, &'static str> {
        let parameters = self
            .supported_parameters
            .as_ref()
            .ok_or("model_capabilities_unavailable")?;
        let supports = |parameter: &str| parameters.iter().any(|p| p == parameter);
        if self.architecture.as_ref().is_some_and(|a| {
            !a.input_modalities.iter().any(|m| m == "text")
                || !a.output_modalities.iter().any(|m| m == "text")
        }) {
            return Err("model_text_research_unsupported");
        }
        let limit_key = if supports("max_tokens") {
            "max_tokens"
        } else if supports("max_completion_tokens") {
            "max_completion_tokens"
        } else {
            return Err("model_output_limit_unsupported");
        };
        let mut result = request.clone();
        let fields = result.as_object_mut().ok_or("invalid_model_request")?;
        let limit = fields
            .get("max_tokens")
            .or_else(|| fields.get("max_completion_tokens"))
            .and_then(Value::as_u64)
            .filter(|n| *n > 0)
            .ok_or("invalid_output_limit")?;
        let maximum = self
            .top_provider
            .as_ref()
            .and_then(|p| p.max_completion_tokens)
            .filter(|n| *n > 0);
        fields.remove("max_tokens");
        fields.remove("max_completion_tokens");
        fields.insert(
            limit_key.into(),
            Value::from(maximum.map_or(limit, |n| n.min(limit))),
        );
        if !supports("response_format") {
            fields.remove("response_format");
        }
        Ok(result)
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    fn request() -> Value {
        crate::incubator::payload("vendor/model:free", "Return JSON.")
    }
    fn capabilities(parameters: Value) -> Capabilities {
        serde_json::from_value(json!({"supported_parameters":parameters,"architecture":{"input_modalities":["text"],"output_modalities":["text"]}})).unwrap()
    }
    #[test]
    fn optional_json_mode_is_omitted_without_changing_authority_or_cost_bounds() {
        let original = request();
        let adapted = capabilities(json!(["max_tokens"]))
            .adapt(&original)
            .unwrap();
        assert!(adapted.get("response_format").is_none());
        for field in ["model", "messages", "stream", "provider", "max_tokens"] {
            assert_eq!(adapted[field], original[field]);
        }
        assert_eq!(
            adapted["provider"]["max_price"],
            json!({"prompt":0,"completion":0})
        );
        assert_eq!(adapted["provider"]["require_parameters"], true);
        assert!(original.get("response_format").is_some());
    }
    #[test]
    fn native_json_and_alternative_token_limits_are_preserved() {
        let c = capabilities(json!(["max_completion_tokens", "response_format"]));
        let adapted = c.adapt(&request()).unwrap();
        assert!(adapted.get("max_tokens").is_none());
        assert_eq!(adapted["max_completion_tokens"], 2048);
        assert_eq!(adapted["response_format"], request()["response_format"]);
        assert_eq!(c.adapt(&adapted).unwrap(), adapted);
    }
    #[test]
    fn output_bounds_are_never_silently_removed_or_increased() {
        assert_eq!(
            capabilities(json!([])).adapt(&request()),
            Err("model_output_limit_unsupported")
        );
        assert_eq!(
            Capabilities::default().adapt(&request()),
            Err("model_capabilities_unavailable")
        );
        let mut c = capabilities(json!(["max_tokens"]));
        c.top_provider = Some(ProviderLimits {
            max_completion_tokens: Some(512),
        });
        assert_eq!(c.adapt(&request()).unwrap()["max_tokens"], 512);
        c.architecture.as_mut().unwrap().output_modalities = vec!["image".into()];
        assert_eq!(c.adapt(&request()), Err("model_text_research_unsupported"));
    }
    #[test]
    fn streaming_and_manual_spend_settings_survive_adaptation() {
        let mut r = request();
        r["stream"] = json!(true);
        r["stream_options"] = json!({"include_usage":true});
        r["provider"].as_object_mut().unwrap().remove("max_price");
        let c = capabilities(json!(["max_tokens"]));
        let adapted = c.adapt(&r).unwrap();
        assert_eq!(adapted["provider"], r["provider"]);
        assert_eq!(adapted["stream_options"], r["stream_options"]);
        assert_eq!(adapted["stream"], true);
    }
    #[test]
    #[ignore = "requires a downloaded current OpenRouter catalog"]
    fn current_catalog_request_compatibility() {
        let path = std::env::var("OPENROUTER_CATALOG_PROBE_PATH").unwrap();
        let catalog: Value = serde_json::from_slice(&std::fs::read(path).unwrap()).unwrap();
        let mut compatible = 0;
        let mut without_json = 0;
        let mut alternative_limits = 0;
        let mut unsupported = Vec::new();
        for model in catalog["data"].as_array().unwrap() {
            let id = model["id"].as_str().unwrap();
            if id.starts_with("openrouter/") {
                continue;
            }
            let c: Capabilities = serde_json::from_value(model.clone()).unwrap();
            let mut request = request();
            request["model"] = json!(id);
            match c.adapt(&request) {
                Ok(adapted) => {
                    compatible += 1;
                    without_json += usize::from(adapted.get("response_format").is_none());
                    alternative_limits +=
                        usize::from(adapted.get("max_completion_tokens").is_some());
                    assert_eq!(adapted["provider"], request["provider"]);
                    assert_eq!(adapted["model"], request["model"]);
                }
                Err(reason) => {
                    assert_eq!(reason, "model_output_limit_unsupported");
                    unsupported.push(json!({"model":id,"reason":reason}));
                }
            }
        }
        assert!(compatible > 0);
        println!(
            "{}",
            json!({"compatible":compatible,"without_native_json":without_json,"alternative_token_limit":alternative_limits,"unsupported":unsupported})
        );
    }
}
