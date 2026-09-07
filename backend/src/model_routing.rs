//! One atomic approval and ordered-provider policy for the model catalog.
use serde::{Deserialize, Serialize};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::Path,
};

#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Route {
    pub provider: String,
    pub model_id: String,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Preference {
    pub model_id: String,
    pub routes: Vec<Route>,
}
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RoutingPolicy {
    pub revision: u64,
    pub legacy_revisions: [u64; 2],
    pub models: Vec<Preference>,
    #[serde(default)]
    pub default_model: Option<String>,
    #[serde(default)]
    pub research_model: Option<String>,
    #[serde(default)]
    pub setup_model: Option<String>,
    #[serde(default)]
    pub experiment_model: Option<String>,
}

pub fn canonical(_provider: &str, id: &str) -> String {
    id.rsplit('/').next().unwrap_or(id).to_string()
}
pub fn stored(path: &Path) -> Result<Option<RoutingPolicy>, &'static str> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|_| "routing_policy_unavailable"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(_) => Err("routing_policy_unavailable"),
    }
}
pub fn read(path: &Path, openrouter: &Path, cursor: &Path) -> Result<RoutingPolicy, &'static str> {
    if let Some(policy) = stored(path)? {
        return Ok(policy);
    }
    let policies = [
        crate::openrouter::read_policy(openrouter)?,
        crate::openrouter::read_policy(cursor)?,
    ];
    let mut groups: BTreeMap<String, Vec<Route>> = BTreeMap::new();
    for (provider, policy) in ["openrouter", "cursor"].iter().zip(&policies) {
        for id in &policy.allowed_models {
            groups
                .entry(canonical(provider, id))
                .or_default()
                .push(Route {
                    provider: (*provider).into(),
                    model_id: id.clone(),
                });
        }
    }
    Ok(RoutingPolicy {
        revision: 0,
        default_model: None,
        research_model: None,
        setup_model: None,
        experiment_model: None,
        legacy_revisions: [policies[0].revision, policies[1].revision],
        models: groups
            .into_iter()
            .map(|(model_id, routes)| Preference { model_id, routes })
            .collect(),
    })
}
pub(crate) fn provider_policy(policy: &RoutingPolicy, provider: &str) -> crate::openrouter::Policy {
    crate::openrouter::Policy {
        revision: policy.revision,
        allowed_models: policy
            .models
            .iter()
            .flat_map(|m| &m.routes)
            .filter(|r| r.provider == provider)
            .map(|r| r.model_id.clone())
            .collect(),
    }
}
pub fn validate(
    current: &RoutingPolicy,
    mut next: RoutingPolicy,
    available: &[Route],
) -> Result<RoutingPolicy, &'static str> {
    if next.revision != current.revision || next.legacy_revisions != current.legacy_revisions {
        return Err("routing_policy_conflict");
    }
    for (selected, reason) in [
        (&next.default_model, "default_model_not_selected"),
        (&next.research_model, "research_model_not_selected"),
        (&next.setup_model, "setup_model_not_selected"),
        (&next.experiment_model, "experiment_model_not_selected"),
    ] {
        if selected
            .as_ref()
            .is_some_and(|id| !next.models.iter().any(|m| &m.model_id == id))
        {
            return Err(reason);
        }
    }
    if next.models.len() > 200 {
        return Err("invalid_model_selection");
    }
    let mut groups = BTreeSet::new();
    let mut routes = BTreeSet::new();
    let mut counts = [0, 0];
    for model in &next.models {
        if !groups.insert(&model.model_id) || model.routes.is_empty() || model.routes.len() > 2 {
            return Err("invalid_model_selection");
        }
        let mut providers = BTreeSet::new();
        for route in &model.routes {
            let index = match route.provider.as_str() {
                "openrouter" => 0,
                "cursor" => 1,
                _ => return Err("invalid_model_selection"),
            };
            if !providers.insert(&route.provider)
                || canonical(&route.provider, &route.model_id) != model.model_id
                || !routes.insert((route.provider.clone(), route.model_id.clone()))
            {
                return Err("invalid_model_selection");
            }
            let retained = current
                .models
                .iter()
                .flat_map(|m| &m.routes)
                .any(|r| r == route);
            if !retained && !available.contains(route) {
                return Err("model_unavailable");
            }
            counts[index] += 1;
        }
    }
    if counts.iter().any(|n| *n > 100) {
        return Err("invalid_model_selection");
    }
    next.models.sort_by(|a, b| a.model_id.cmp(&b.model_id));
    next.revision = current
        .revision
        .checked_add(1)
        .ok_or("routing_policy_conflict")?;
    Ok(next)
}
pub fn write(path: &Path, policy: &RoutingPolicy) -> Result<(), &'static str> {
    use std::io::Write;
    let temp = path.with_extension("json.new");
    let mut file = std::fs::File::create(&temp).map_err(|_| "routing_policy_save_failed")?;
    file.write_all(&serde_json::to_vec(policy).map_err(|_| "routing_policy_save_failed")?)
        .and_then(|_| file.sync_all())
        .map_err(|_| "routing_policy_save_failed")?;
    std::fs::rename(&temp, path).map_err(|_| "routing_policy_save_failed")
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn legacy_approvals_migrate_once_and_atomic_save_preserves_priority() {
        let directory = std::env::temp_dir().join(format!(
            "routing-policy-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        std::fs::create_dir(&directory).unwrap();
        let or = directory.join("or.json");
        let cursor = directory.join("cursor.json");
        let path = directory.join("routing.json");
        std::fs::write(
            &or,
            r#"{"revision":3,"allowed_models":["openai/gpt-5.6-luna"]}"#,
        )
        .unwrap();
        std::fs::write(
            &cursor,
            r#"{"revision":2,"allowed_models":["gpt-5.6-luna"]}"#,
        )
        .unwrap();
        let current = read(&path, &or, &cursor).unwrap();
        assert_eq!(current.models.len(), 1);
        assert_eq!(current.legacy_revisions, [3, 2]);
        let mut next = current.clone();
        next.models[0].routes.reverse();
        let next = validate(&current, next, &[]).unwrap();
        write(&path, &next).unwrap();
        assert_eq!(read(&path, &or, &cursor).unwrap(), next);
        std::fs::write(&or, r#"{"revision":4,"allowed_models":[]}"#).unwrap();
        assert_eq!(read(&path, &or, &cursor).unwrap(), next);
        assert_eq!(
            provider_policy(&next, "cursor").allowed_models,
            vec!["gpt-5.6-luna"]
        );
        std::fs::write(&path, "broken").unwrap();
        assert!(read(&path, &or, &cursor).is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn role_preferences_are_optional_validated_and_resolve_before_default() {
        let old = r#"{"revision":0,"legacy_revisions":[0,0],"models":[],"default_model":null}"#;
        let mut policy: RoutingPolicy = serde_json::from_str(old).unwrap();
        assert_eq!(policy.research_model, None);
        for name in [
            "basic:free",
            "research:free",
            "setup:free",
            "experiment:free",
        ] {
            policy.models.push(Preference {
                model_id: name.into(),
                routes: vec![Route {
                    provider: "openrouter".into(),
                    model_id: format!("vendor/{name}"),
                }],
            });
        }
        policy.default_model = Some("basic:free".into());
        assert_eq!(
            crate::incubator::role_route(&policy, "research")
                .unwrap()
                .model_id,
            "vendor/basic:free"
        );
        policy.setup_model = Some("setup:free".into());
        policy.research_model = Some("research:free".into());
        policy.experiment_model = Some("experiment:free".into());
        assert_eq!(
            crate::incubator::role_route(&policy, "research")
                .unwrap()
                .model_id,
            "vendor/research:free"
        );
        assert_eq!(
            crate::incubator::role_route(&policy, "experiment")
                .unwrap()
                .model_id,
            "vendor/experiment:free"
        );
        assert_eq!(
            crate::incubator::role_route(&policy, "setup")
                .unwrap()
                .model_id,
            "vendor/setup:free"
        );
        let mut invalid = policy.clone();
        invalid.setup_model = Some("missing".into());
        assert_eq!(
            validate(&policy, invalid, &[]).unwrap_err(),
            "setup_model_not_selected"
        );
        let mut next = policy.clone();
        next.models.retain(|p| p.model_id != "research:free");
        assert_eq!(
            validate(&policy, next, &[]).unwrap_err(),
            "research_model_not_selected"
        );
    }
    #[test]
    fn identity_keeps_variants_and_unknown_models_separate() {
        assert_eq!(
            canonical("cursor", "gpt-5.6-luna"),
            canonical("openrouter", "openai/gpt-5.6-luna")
        );
        assert_ne!(
            canonical("cursor", "gpt-5.6-luna"),
            canonical("openrouter", "openai/gpt-5.6-luna-pro")
        );
        assert_ne!(
            canonical("cursor", "gpt-5.6-luna"),
            canonical("openrouter", "openai/gpt-5.6-luna:batch")
        );
        assert_eq!(canonical("cursor", "unknown"), "unknown");
    }
    #[test]
    fn ordered_routes_are_validated_and_revisions_are_enforced() {
        let or = Route {
            provider: "openrouter".into(),
            model_id: "openai/gpt-5.6-luna".into(),
        };
        let cursor = Route {
            provider: "cursor".into(),
            model_id: "gpt-5.6-luna".into(),
        };
        let current = RoutingPolicy {
            revision: 0,
            default_model: None,
            research_model: None,
            setup_model: None,
            experiment_model: None,
            legacy_revisions: [3, 0],
            models: vec![],
        };
        let mut next = current.clone();
        next.models.push(Preference {
            model_id: canonical("openrouter", &or.model_id),
            routes: vec![cursor.clone(), or.clone()],
        });
        let saved = validate(&current, next.clone(), &[or.clone(), cursor]).unwrap();
        assert_eq!(saved.models[0].routes[0].provider, "cursor");
        assert_eq!(
            validate(&saved, next.clone(), &[]).unwrap_err(),
            "routing_policy_conflict"
        );
        next.models[0].routes.push(or);
        assert!(validate(&current, next, &[]).is_err());
        let mut unchanged = saved.clone();
        unchanged.models[0].routes.reverse();
        assert!(validate(&saved, unchanged, &[]).is_ok());
    }
}
