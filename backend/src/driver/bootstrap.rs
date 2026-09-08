//! First-start import: today's routing.json role picks and the OpenRouter capacity policy become
//! agents with tiered routes, recorded as `config_revision(source=import)`. Never re-imports.
use super::log;
use crate::model_routing::RoutingPolicy;
use serde_json::{json, Value};
use tokio_postgres::Client;

const ROUTING_PATH: &str = "/var/lib/model-policy/routing.json";

/// (agent id, display name, routing role, capacity purpose role, system prompt seed)
const AGENTS: [(&str, &str, &str, &str, &str); 7] = [
    (
        "research_scout",
        "Research Scout",
        "research",
        "research",
        "You are the Research Scout. Produce a structured research report for the assigned brief.",
    ),
    (
        "ticket_creator",
        "Ticket Creator",
        "setup",
        "default",
        "You are the Ticket Creator. Turn campaign seeds into bounded research tickets.",
    ),
    (
        "similarity",
        "Similarity Checker",
        "setup",
        "default",
        "You compare candidate briefs against existing research and report overlap.",
    ),
    (
        "evaluator",
        "Evaluator",
        "research",
        "research",
        "You evaluate completed research reports against the campaign contract.",
    ),
    (
        "refiner",
        "Refiner",
        "research",
        "research",
        "You refine research reports that failed evaluation.",
    ),
    (
        "experiment",
        "Experiment Runner",
        "experiment",
        "experiment",
        "You design and interpret bounded diagnostic experiments.",
    ),
    (
        "owner_chat",
        "Owner Chat",
        "default",
        "manual",
        "You are the owner's research assistant. Answer within the Local Research boundary.",
    ),
];

fn tier_for(model: &str) -> &'static str {
    if model.ends_with(":free") {
        "free"
    } else {
        "paid"
    }
}
fn provider_for(model: &str) -> &'static str {
    if model.ends_with(":free") {
        "openrouter-free"
    } else {
        "openrouter-paid"
    }
}
fn role_model<'a>(policy: &'a RoutingPolicy, role: &str) -> Option<&'a str> {
    match role {
        "research" => policy.research_model.as_deref(),
        "setup" => policy.setup_model.as_deref(),
        "experiment" => policy.experiment_model.as_deref(),
        _ => None,
    }
    .or(policy.default_model.as_deref())
}
fn push_route(routes: &mut Vec<Value>, model: &str) {
    if routes.iter().any(|r| r["model_id"] == model) || model.starts_with("openrouter/") {
        return;
    }
    let tier = tier_for(model);
    let ordinal = routes.iter().filter(|r| r["tier"] == tier).count();
    routes.push(json!({"tier":tier,"ordinal":ordinal,"provider_id":provider_for(model),"model_id":model,"share_pct":100}));
}
/// Build the routes for one agent: role pick first, then every other whitelisted free model, then
/// the capacity policy's paid models when paid fallback is enabled.
pub fn routes_for(
    policy: &RoutingPolicy,
    capacity: &Value,
    role: &str,
    purpose_role: &str,
) -> Vec<Value> {
    let mut routes = Vec::new();
    if let Some(model) = role_model(policy, role) {
        push_route(&mut routes, model);
    }
    if let Some(default) = policy.default_model.as_deref() {
        if default.ends_with(":free") {
            push_route(&mut routes, default);
        }
    }
    for model in &policy.models {
        if model.model_id.ends_with(":free")
            && model.routes.iter().any(|r| r.provider == "openrouter")
        {
            push_route(&mut routes, &model.model_id);
        }
    }
    if capacity["paid_enabled"] == true {
        for model in [
            capacity["paid_role_models"][purpose_role].as_str(),
            capacity["paid_role_models"]["default"].as_str(),
            capacity["paid_model"].as_str(),
        ]
        .into_iter()
        .flatten()
        .chain(
            capacity["paid_models"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str),
        ) {
            if !model.ends_with(":free") {
                push_route(&mut routes, model);
            }
        }
    }
    routes
}
pub fn agent_patch(policy: Option<&RoutingPolicy>, capacity: &Value, id: &str) -> Option<Value> {
    let (_, name, role, purpose_role, prompt) = AGENTS.iter().copied().find(|a| a.0 == id)?;
    let routes = policy.map_or_else(Vec::new, |p| routes_for(p, capacity, role, purpose_role));
    let imported_from = match policy {
        Some(p) => json!({"routing_revision":p.revision,"role":role}),
        None => {
            json!({"routing_revision":Value::Null,"role":role,"note":"no routing.json; routes configured in the UI"})
        }
    };
    Some(json!({
        "name":name,
        "spec":{"system":prompt,"response_contract":"","tags":[],"tool_allowlist":[],"max_iterations":1,"max_tool_calls":0,
            "imported_from":imported_from},
        "priority":100,"hold_at_pct":100,"enabled":true,"routes":routes
    }))
}

/// Import when the agent table is empty. Missing routing.json is not an error: the UI creates agents.
pub async fn import_if_empty(db: &Client) -> Result<usize, &'static str> {
    let existing: Value = db
        .query_one("SELECT read_agents()", &[])
        .await
        .map_err(|_| "agents_unavailable")?
        .get(0);
    if existing.as_array().is_some_and(|a| !a.is_empty()) {
        log::debug(
            "bootstrap.skipped",
            json!({"agents":existing.as_array().map(Vec::len)}),
        );
        return Ok(0);
    }
    // No routing.json means a fresh install: seed the agent set with empty routes so the UI has
    // something to configure and workers get `route_unavailable` instead of an unknown agent.
    let policy = match crate::model_routing::stored(std::path::Path::new(ROUTING_PATH)) {
        Ok(Some(policy)) => Some(policy),
        Ok(None) => {
            log::info("bootstrap.no_routing_policy", json!({"path":ROUTING_PATH}));
            None
        }
        Err(reason) => {
            log::warn(
                "bootstrap.routing_unreadable",
                json!({"path":ROUTING_PATH,"reason":reason}),
            );
            return Err(reason);
        }
    };
    let capacity = crate::openrouter_capacity::read(db)
        .await
        .map(|status| status["policy"].clone())
        .unwrap_or(Value::Null);
    let mut imported = 0;
    for (id, ..) in AGENTS {
        let Some(patch) = agent_patch(policy.as_ref(), &capacity, id) else {
            continue;
        };
        match db
            .query_one(
                "SELECT save_agent($1,$2,$3,$4)",
                &[&id, &0_i64, &patch, &"import"],
            )
            .await
        {
            Ok(row) => {
                let result: Value = row.get(0);
                imported += 1;
                log::info(
                    "bootstrap.agent_imported",
                    json!({"agent":id,"status":result["status"],"routes":patch["routes"].as_array().map(Vec::len),"routing_revision":policy.as_ref().map(|p| p.revision)}),
                );
            }
            Err(e) => log::error(
                "bootstrap.agent_import_failed",
                json!({"agent":id,"error":super::dispatch::sql_reason(&e,"save_failed")}),
            ),
        }
    }
    Ok(imported)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model_routing::{Preference, Route};
    fn policy() -> RoutingPolicy {
        RoutingPolicy {
            revision: 7,
            legacy_revisions: [0, 0],
            default_model: Some("vendor/default:free".into()),
            research_model: Some("vendor/research:free".into()),
            setup_model: Some("vendor/paid-setup".into()),
            experiment_model: None,
            models: vec![
                Preference {
                    model_id: "vendor/default:free".into(),
                    routes: vec![Route {
                        provider: "openrouter".into(),
                        model_id: "vendor/default:free".into(),
                    }],
                },
                Preference {
                    model_id: "vendor/research:free".into(),
                    routes: vec![Route {
                        provider: "openrouter".into(),
                        model_id: "vendor/research:free".into(),
                    }],
                },
                Preference {
                    model_id: "vendor/paid-setup".into(),
                    routes: vec![Route {
                        provider: "openrouter".into(),
                        model_id: "vendor/paid-setup".into(),
                    }],
                },
                Preference {
                    model_id: "cursor/x".into(),
                    routes: vec![Route {
                        provider: "cursor".into(),
                        model_id: "x".into(),
                    }],
                },
            ],
        }
    }
    #[test]
    fn role_pick_leads_free_tier_and_paid_models_follow_policy() {
        let capacity = json!({"paid_enabled":true,"paid_models":["vendor/paid-a","vendor/paid-b"],"paid_role_models":{"research":"vendor/paid-b"}});
        let routes = routes_for(&policy(), &capacity, "research", "research");
        let ids: Vec<_> = routes
            .iter()
            .map(|r| {
                (
                    r["tier"].as_str().unwrap(),
                    r["model_id"].as_str().unwrap(),
                    r["ordinal"].as_u64().unwrap(),
                )
            })
            .collect();
        assert_eq!(
            ids,
            [
                ("free", "vendor/research:free", 0),
                ("free", "vendor/default:free", 1),
                ("paid", "vendor/paid-b", 0),
                ("paid", "vendor/paid-a", 1)
            ]
        );
        assert!(routes.iter().all(|r| r["provider_id"]
            .as_str()
            .unwrap()
            .starts_with("openrouter-")));
        let no_paid = routes_for(
            &policy(),
            &json!({"paid_enabled":false,"paid_models":["vendor/paid-a"]}),
            "research",
            "research",
        );
        assert!(no_paid.iter().all(|r| r["tier"] == "free"));
    }
    #[test]
    fn setup_role_with_a_paid_pick_keeps_it_as_a_paid_route() {
        let routes = routes_for(&policy(), &json!({}), "setup", "default");
        assert_eq!(routes[0]["tier"], "paid");
        assert_eq!(routes[0]["provider_id"], "openrouter-paid");
        assert_eq!(routes[0]["model_id"], "vendor/paid-setup");
        let patch = agent_patch(Some(&policy()), &json!({}), "ticket_creator").unwrap();
        assert_eq!(patch["name"], "Ticket Creator");
        assert_eq!(patch["spec"]["imported_from"]["routing_revision"], 7);
        assert!(agent_patch(Some(&policy()), &json!({}), "nope").is_none());
        let fresh = agent_patch(None, &json!({}), "research_scout").unwrap();
        assert_eq!(fresh["routes"].as_array().map(Vec::len), Some(0));
        assert!(fresh["spec"]["imported_from"]["routing_revision"].is_null());
    }
}
