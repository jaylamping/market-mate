//! PR1 research contracts and artifact verification (wayfinder map #171,
//! decision #172).
//!
//! Pure, deterministic checks mirroring
//! `db/migrations/0096_research_contract.sql`: minimal assignment pins,
//! full-chain artifact provenance, and three narrow verification gates that
//! assert no edge or profit (contract validity, reproducibility,
//! methodological readiness).
//!
//! This module performs no dispatch, admits no model or cost authority,
//! records no outcomes, and changes no route, tier, or execution policy. It
//! reuses [`crate::momentum::Spec::valid`] for the momentum ranges and
//! [`crate::momentum::evaluate`] determinism for replay checks.
//!
//! Digest note: each runtime recomputes digests in its own canonical JSON
//! form (SQL uses `jsonb::text`, Rust uses `serde_json::to_string` with
//! sorted keys), so a replay must use the same canonicalizer that recorded
//! the digest. Within one canonicalizer, pinned-version replay reproduces
//! byte-identical digests.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::momentum::{Dataset, Spec};

/// Domain separator for pinned momentum spec digests.
pub const SPEC_DIGEST_DOMAIN: &str = "market-mate-research-spec-v1";
/// Domain separator for recorded artifact digests.
pub const ARTIFACT_DIGEST_DOMAIN: &str = "market-mate-research-artifact-v1";
/// Contract runner fixed by the assignment contract.
pub const CONTRACT_RUNNER: &str = "momentum_v1";
/// Executable quantile choices pinned by the contract (narrower than the
/// engine's 2..=10 range).
pub const QUANTILE_CHOICES: [usize; 4] = [2, 4, 5, 10];

/// Canonical Research Posture profiles. Mirrors
/// `research_posture_profile_is_canonical` in SQL.
pub const POSTURE_PROFILES: [&str; 7] = [
    "Passive Observer",
    "Conservative Verifier",
    "Balanced Investigator",
    "Aggressive Explorer",
    "Extreme Frontier",
    "Skeptical Reviewer",
    "Adversarial Red Team",
];

/// Desk roles admitted to research assignments. Mirrors
/// `incubator_desk_role_is_allowed` in SQL; posture aggressiveness never
/// confers position-risk authority, so no sizing or risk fields exist here.
pub const DESK_ROLES: [&str; 6] = [
    "market_intelligence_and_thesis",
    "quantitative_research_and_experimentation",
    "data_and_feature_research",
    "strategy_incubation",
    "portfolio_and_capital_efficiency",
    "economic_evaluation_and_challenge",
];

/// Minimal immutable assignment pins. Unknown fields are rejected so the
/// pinned set cannot silently grow sizing, risk, or authority fields.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct AssignmentPins {
    pub assignment_key: String,
    pub desk_role: String,
    pub strategy_thesis_id: String,
    pub posture_profile: String,
    pub posture_version: String,
    pub recipe_version: String,
    pub contract_runner: String,
    pub persona_id: String,
    pub persona_cosmetic: bool,
    pub expires_at: String,
    pub parent_assignment_id: Option<String>,
}

/// Full-chain artifact provenance carried on the artifact as a checkable
/// copy. The driver dispatch record stays authoritative; families are opaque
/// text and never hardcode model identities.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ArtifactManifest {
    pub artifact_key: String,
    pub assignment: AssignmentPins,
    pub run_key: String,
    pub intent_id: Option<String>,
    pub attempt_id: Option<String>,
    pub requested_route: serde_json::Value,
    pub actual_route: serde_json::Value,
    pub config_revision: i64,
    pub fallback_ancestry: Vec<String>,
    pub author_assignment_id: String,
    pub author_run_key: String,
    pub author_role: String,
    pub refiner_assignment_id: Option<String>,
    pub refiner_run_key: Option<String>,
    pub refiner_role: Option<String>,
    pub author_family: String,
    pub reviewer_assignment_id: Option<String>,
    pub reviewer_run_key: Option<String>,
    pub reviewer_role: Option<String>,
    pub reviewer_family: Option<String>,
    pub recipe_versions: serde_json::Value,
    pub lesson_versions: serde_json::Value,
    pub spec: serde_json::Value,
    pub spec_digest: String,
    pub artifact: serde_json::Value,
    pub artifact_digest: String,
    pub dissent_preserved: bool,
}

/// Gate (a): schema plus pinned fields plus momentum scope.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Validity {
    Valid,
    Invalid { reason: String },
}

/// Gate (b): byte-identical replay plus lineage closure. Uncertain dispatch
/// outcomes stay indeterminate; they are reconciled before redispatch.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Reproducibility {
    Reproduced,
    Diverged { reason: String },
    Indeterminate { reason: String },
}

/// Gate (c): separate-assignment critique passed with dissent preserved.
/// Same-family approval never counts as critique: it holds.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum Readiness {
    Ready,
    Held { reason: String },
}

/// Combined verification result for one artifact. None of the gates asserts
/// edge or profit.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct VerificationResult {
    pub artifact_key: String,
    pub validity: Validity,
    pub reproducibility: Reproducibility,
    pub readiness: Readiness,
}

/// Dispatch outcome as seen by the reproducibility gate. `Unknown` means no
/// outcome row exists yet; it stays indeterminate, never failed.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DispatchState {
    Completed,
    Failed,
    Cancelled,
    Indeterminate,
    Unknown,
}

fn non_blank(value: &str) -> bool {
    !value.trim().is_empty()
}

/// Validate the minimal pin set: every pin present, posture in the canonical
/// set, persona marked cosmetic, runner fixed to momentum_v1.
pub fn pins_valid(pins: &AssignmentPins) -> Result<(), String> {
    if !non_blank(&pins.assignment_key) {
        return Err("pins:assignment_key_required".into());
    }
    if !DESK_ROLES.contains(&pins.desk_role.trim().to_lowercase().as_str()) {
        return Err("pins:desk_role_not_admitted".into());
    }
    if !non_blank(&pins.strategy_thesis_id) {
        return Err("pins:strategy_thesis_required".into());
    }
    if !POSTURE_PROFILES.contains(&pins.posture_profile.trim()) {
        return Err("pins:posture_not_canonical".into());
    }
    if !non_blank(&pins.posture_version) {
        return Err("pins:posture_version_required".into());
    }
    if !non_blank(&pins.recipe_version) {
        return Err("pins:recipe_version_required".into());
    }
    if pins.contract_runner.trim() != CONTRACT_RUNNER {
        return Err("pins:contract_runner_must_be_momentum_v1".into());
    }
    if !non_blank(&pins.persona_id) {
        return Err("pins:persona_required".into());
    }
    if !pins.persona_cosmetic {
        return Err("pins:persona_must_be_cosmetic_only".into());
    }
    if chrono::DateTime::parse_from_rfc3339(pins.expires_at.trim()).is_err() {
        return Err("pins:expires_at_must_be_rfc3339".into());
    }
    Ok(())
}

/// Validate the pinned momentum spec: exactly the five contract keys with
/// the engine ranges, plus the contract quantile set {2,4,5,10}.
pub fn spec_valid(spec: &serde_json::Value) -> Result<(), String> {
    let parsed: Spec = serde_json::from_value(spec.clone())
        .map_err(|_| "spec_schema:exactly_five_momentum_keys".to_string())?;
    if !parsed.valid() {
        return Err("spec_schema:momentum_range".into());
    }
    if !QUANTILE_CHOICES.contains(&parsed.quantile_count) {
        return Err("spec_schema:quantile_not_in_contract_set".into());
    }
    Ok(())
}

/// Canonical content digest: `sha256(domain | canonical_json)`.
pub fn canonical_digest(domain: &str, value: &serde_json::Value) -> String {
    let canonical = serde_json::to_string(value).expect("verification JSON serializes");
    let mut hasher = Sha256::new();
    hasher.update(domain.as_bytes());
    hasher.update(b"|");
    hasher.update(canonical.as_bytes());
    hex::encode(hasher.finalize())
}

/// Digest of the pinned spec, recomputed on replay.
pub fn spec_digest(spec: &serde_json::Value) -> String {
    canonical_digest(SPEC_DIGEST_DOMAIN, spec)
}

/// Digest of the recorded artifact, recomputed on replay.
pub fn artifact_digest(artifact: &serde_json::Value) -> String {
    canonical_digest(ARTIFACT_DIGEST_DOMAIN, artifact)
}

/// Gate (a): contract validity.
pub fn contract_validity(pins: &AssignmentPins, spec: &serde_json::Value) -> Validity {
    if let Err(reason) = pins_valid(pins) {
        return Validity::Invalid { reason };
    }
    if let Err(reason) = spec_valid(spec) {
        return Validity::Invalid { reason };
    }
    Validity::Valid
}

/// Gate (b): reproducibility of one recorded digest against a replayed
/// artifact under a known dispatch outcome.
pub fn reproducibility(
    recorded_digest: &str,
    artifact: &serde_json::Value,
    dispatch: DispatchState,
) -> Reproducibility {
    match dispatch {
        DispatchState::Unknown => Reproducibility::Indeterminate {
            reason: "dispatch_outcome_unknown".into(),
        },
        DispatchState::Indeterminate => Reproducibility::Indeterminate {
            reason: "dispatch_indeterminate".into(),
        },
        DispatchState::Failed => Reproducibility::Diverged {
            reason: "dispatch_failed".into(),
        },
        DispatchState::Cancelled => Reproducibility::Diverged {
            reason: "dispatch_cancelled".into(),
        },
        DispatchState::Completed => {
            if artifact_digest(artifact) == recorded_digest {
                Reproducibility::Reproduced
            } else {
                Reproducibility::Diverged {
                    reason: "digest_mismatch".into(),
                }
            }
        }
    }
}

/// Gate (c): methodological readiness. Different assignment plus different
/// run with a different role suffices for critique; same-family approval
/// holds and never counts as critique; dissent must be preserved.
pub fn methodological_readiness(manifest: &ArtifactManifest) -> Readiness {
    let reviewer_assignment = manifest.reviewer_assignment_id.as_deref().unwrap_or("");
    let reviewer_run = manifest.reviewer_run_key.as_deref().unwrap_or("");
    if !non_blank(reviewer_assignment) || !non_blank(reviewer_run) {
        return Readiness::Held {
            reason: "missing_critique".into(),
        };
    }
    if reviewer_assignment.trim() == manifest.author_assignment_id.trim()
        || reviewer_run.trim() == manifest.author_run_key.trim()
    {
        return Readiness::Held {
            reason: "same_assignment_or_run".into(),
        };
    }
    let reviewer_role = manifest.reviewer_role.as_deref().unwrap_or("");
    if reviewer_role.trim().to_lowercase() == manifest.author_role.trim().to_lowercase() {
        return Readiness::Held {
            reason: "same_role".into(),
        };
    }
    let reviewer_family = manifest.reviewer_family.as_deref().unwrap_or("");
    if reviewer_family.trim().to_lowercase() == manifest.author_family.trim().to_lowercase() {
        return Readiness::Held {
            reason: "same_family".into(),
        };
    }
    if !manifest.dissent_preserved {
        return Readiness::Held {
            reason: "dissent_not_preserved".into(),
        };
    }
    Readiness::Ready
}

/// Run all three gates for one manifest. Lineage closure against stored
/// dispatch rows is evaluated by the SQL gate; here `ancestry_closed`
/// carries that checkable copy's result into the combined verdict.
pub fn verify(
    manifest: &ArtifactManifest,
    dispatch: DispatchState,
    ancestry_closed: bool,
) -> VerificationResult {
    let validity = contract_validity(&manifest.assignment, &manifest.spec);
    let mut repro = reproducibility(&manifest.artifact_digest, &manifest.artifact, dispatch);
    if repro == Reproducibility::Reproduced {
        if manifest.spec_digest != spec_digest(&manifest.spec) {
            repro = Reproducibility::Diverged {
                reason: "spec_digest_mismatch".into(),
            };
        } else if !ancestry_closed {
            repro = Reproducibility::Diverged {
                reason: "lineage_open".into(),
            };
        }
    }
    VerificationResult {
        artifact_key: manifest.artifact_key.clone(),
        validity,
        reproducibility: repro,
        readiness: methodological_readiness(manifest),
    }
}

/// Parse helper used by workers: unknown fields are rejected.
pub fn parse_manifest(value: &serde_json::Value) -> Result<ArtifactManifest, String> {
    serde_json::from_value(value.clone()).map_err(|err| format!("invalid_artifact:{err}"))
}

#[allow(dead_code)]
fn dataset_support_present() -> bool {
    // Compile-time proof that the momentum dataset type stays reachable for
    // replay harnesses without granting this module any new authority.
    fn _uses_dataset(_: &Dataset) {}
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn good_pins() -> AssignmentPins {
        AssignmentPins {
            assignment_key: "probe-assignment-1".into(),
            desk_role: "quantitative_research_and_experimentation".into(),
            strategy_thesis_id: "thesis-probe-1".into(),
            posture_profile: "Balanced Investigator".into(),
            posture_version: "posture-v3".into(),
            recipe_version: "recipe-v2".into(),
            contract_runner: "momentum_v1".into(),
            persona_id: "persona-scout-7".into(),
            persona_cosmetic: true,
            expires_at: "2030-06-01T00:00:00Z".into(),
            parent_assignment_id: None,
        }
    }

    fn good_spec() -> serde_json::Value {
        json!({
            "runner": "momentum_v1",
            "lookback_sessions": 2,
            "quantile_count": 4,
            "one_way_cost_bps": 10,
            "borrow_bps_per_session": 2
        })
    }

    fn good_artifact() -> serde_json::Value {
        json!({"engine": "momentum_v1", "outcome": "diagnostic_only", "mean_net_bps": 12})
    }

    fn good_manifest() -> ArtifactManifest {
        let artifact = good_artifact();
        let spec = good_spec();
        ArtifactManifest {
            artifact_key: "probe-artifact-ready".into(),
            assignment: good_pins(),
            run_key: "run-author-1".into(),
            intent_id: Some("intent-1".into()),
            attempt_id: Some("attempt-1".into()),
            requested_route: json!({"tier": "free"}),
            actual_route: json!({"tier": "free"}),
            config_revision: 3,
            fallback_ancestry: vec!["parent-attempt-1".into()],
            author_assignment_id: "assignment-author".into(),
            author_run_key: "run-author-1".into(),
            author_role: "strategy_incubation".into(),
            refiner_assignment_id: None,
            refiner_run_key: None,
            refiner_role: None,
            author_family: "family-alpha".into(),
            reviewer_assignment_id: Some("assignment-reviewer".into()),
            reviewer_run_key: Some("run-reviewer-1".into()),
            reviewer_role: Some("economic_evaluation_and_challenge".into()),
            reviewer_family: Some("family-beta".into()),
            recipe_versions: json!({"recipe": "recipe-v2"}),
            lesson_versions: json!({}),
            spec: spec.clone(),
            spec_digest: spec_digest(&spec),
            artifact: artifact.clone(),
            artifact_digest: artifact_digest(&artifact),
            dissent_preserved: true,
        }
    }

    #[test]
    fn pins_accept_minimal_valid_set() {
        assert_eq!(pins_valid(&good_pins()), Ok(()));
    }

    #[test]
    fn pins_reject_unknown_fields() {
        let raw = json!({
            "assignment_key": "k",
            "desk_role": "strategy_incubation",
            "strategy_thesis_id": "t",
            "posture_profile": "Balanced Investigator",
            "posture_version": "v1",
            "recipe_version": "r1",
            "contract_runner": "momentum_v1",
            "persona_id": "p",
            "persona_cosmetic": true,
            "expires_at": "2030-01-01T00:00:00Z",
            "sizing": {"risk": "high"}
        });
        assert!(serde_json::from_value::<AssignmentPins>(raw).is_err());
    }

    #[test]
    fn pins_reject_bad_profile_cosmetic_role_runner_and_expiry() {
        let mut pins = good_pins();
        pins.posture_profile = "Reckless Gambler".into();
        assert!(pins_valid(&pins).is_err());
        let mut pins = good_pins();
        pins.persona_cosmetic = false;
        assert_eq!(
            pins_valid(&pins),
            Err("pins:persona_must_be_cosmetic_only".to_string())
        );
        let mut pins = good_pins();
        pins.desk_role = "risk".into();
        assert!(pins_valid(&pins).is_err());
        let mut pins = good_pins();
        pins.contract_runner = "alpha_v9".into();
        assert!(pins_valid(&pins).is_err());
        let mut pins = good_pins();
        pins.expires_at = "soon".into();
        assert!(pins_valid(&pins).is_err());
        let mut pins = good_pins();
        pins.strategy_thesis_id = "  ".into();
        assert!(pins_valid(&pins).is_err());
    }

    #[test]
    fn spec_accepts_exact_five_contract_keys() {
        assert_eq!(spec_valid(&good_spec()), Ok(()));
    }

    #[test]
    fn spec_rejects_out_of_contract_shapes() {
        let mut spec = good_spec();
        spec["quantile_count"] = json!(3);
        assert!(spec_valid(&spec).is_err());
        let mut spec = good_spec();
        spec["tuning"] = json!({"grid": true});
        assert!(spec_valid(&spec).is_err());
        let mut spec = good_spec();
        spec["runner"] = json!("alpha_v9");
        assert!(spec_valid(&spec).is_err());
        let mut spec = good_spec();
        spec["lookback_sessions"] = json!(0);
        assert!(spec_valid(&spec).is_err());
        let mut spec = good_spec();
        spec["one_way_cost_bps"] = json!(101);
        assert!(spec_valid(&spec).is_err());
    }

    #[test]
    fn invalid_artifacts_rejected() {
        let raw = json!({
            "artifact_key": "k",
            "assignment": good_pins(),
            "unknown_provenance": true
        });
        assert!(parse_manifest(&raw).is_err());
        let manifest = good_manifest();
        let mut bad_spec = manifest.clone();
        bad_spec.spec = json!({"runner": "momentum_v1"});
        assert!(matches!(
            contract_validity(&bad_spec.assignment, &bad_spec.spec),
            Validity::Invalid { .. }
        ));
        let mut bad_pins = manifest.clone();
        bad_pins.assignment.persona_cosmetic = false;
        assert!(matches!(
            contract_validity(&bad_pins.assignment, &bad_pins.spec),
            Validity::Invalid { .. }
        ));
    }

    #[test]
    fn missing_critique_holds_readiness() {
        let mut manifest = good_manifest();
        manifest.reviewer_assignment_id = None;
        manifest.reviewer_run_key = None;
        manifest.reviewer_role = None;
        manifest.reviewer_family = None;
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "missing_critique".into()
            }
        );
    }

    #[test]
    fn same_assignment_run_and_role_hold_readiness() {
        let mut manifest = good_manifest();
        manifest.reviewer_assignment_id = Some(manifest.author_assignment_id.clone());
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "same_assignment_or_run".into()
            }
        );
        let mut manifest = good_manifest();
        manifest.reviewer_run_key = Some(manifest.author_run_key.clone());
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "same_assignment_or_run".into()
            }
        );
        let mut manifest = good_manifest();
        manifest.reviewer_role = Some(manifest.author_role.clone());
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "same_role".into()
            }
        );
    }

    #[test]
    fn same_family_review_holds_and_never_counts_as_critique() {
        let mut manifest = good_manifest();
        manifest.reviewer_family = Some(manifest.author_family.clone());
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "same_family".into()
            }
        );
        let mut manifest = good_manifest();
        manifest.reviewer_family = Some("  FAMILY-ALPHA ".into());
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "same_family".into()
            }
        );
    }

    #[test]
    fn missing_dissent_holds_readiness() {
        let mut manifest = good_manifest();
        manifest.dissent_preserved = false;
        assert_eq!(
            methodological_readiness(&manifest),
            Readiness::Held {
                reason: "dissent_not_preserved".into()
            }
        );
    }

    #[test]
    fn pinned_version_replay_reproduces_byte_identical_digest() {
        let artifact = good_artifact();
        let recorded = artifact_digest(&artifact);
        let replayed: serde_json::Value =
            serde_json::from_str(&serde_json::to_string(&artifact).unwrap()).unwrap();
        assert_eq!(artifact_digest(&replayed), recorded);
        assert_eq!(
            reproducibility(&recorded, &replayed, DispatchState::Completed),
            Reproducibility::Reproduced
        );
    }

    #[test]
    fn diverged_replay_detected() {
        let artifact = good_artifact();
        let recorded = artifact_digest(&artifact);
        let mut diverged = artifact.clone();
        diverged["mean_net_bps"] = json!(13);
        assert_ne!(artifact_digest(&diverged), recorded);
        assert_eq!(
            reproducibility(&recorded, &diverged, DispatchState::Completed),
            Reproducibility::Diverged {
                reason: "digest_mismatch".into()
            }
        );
        assert_eq!(
            reproducibility(&recorded, &artifact, DispatchState::Failed),
            Reproducibility::Diverged {
                reason: "dispatch_failed".into()
            }
        );
    }

    #[test]
    fn indeterminate_dispatch_outcomes_stay_indeterminate() {
        let artifact = good_artifact();
        let recorded = artifact_digest(&artifact);
        assert_eq!(
            reproducibility(&recorded, &artifact, DispatchState::Indeterminate),
            Reproducibility::Indeterminate {
                reason: "dispatch_indeterminate".into()
            }
        );
        assert_eq!(
            reproducibility(&recorded, &artifact, DispatchState::Unknown),
            Reproducibility::Indeterminate {
                reason: "dispatch_outcome_unknown".into()
            }
        );
    }

    #[test]
    fn momentum_replay_stays_deterministic_and_costed() {
        let sessions = ["2026-01-05", "2026-01-06", "2026-01-07", "2026-01-08"];
        let symbols = ["A", "B", "C", "D"];
        let dataset_value = json!({
            "dataset_class": "fixture",
            "symbols": symbols,
            "sessions": sessions,
            "series": symbols.iter().enumerate().map(|(i, s)| json!({
                "symbol": s,
                "bars": sessions.iter().enumerate().map(|(t, d)| json!({
                    "session": d,
                    "open_cents": 10000 + (i as i64 - 1) * t as i64 * 100,
                    "close_cents": 10000 + (i as i64 - 1) * t as i64 * 200
                })).collect::<Vec<_>>()
            })).collect::<Vec<_>>(),
            "benchmark": sessions.iter().map(|d| json!({
                "session": d, "open_cents": 10000, "close_cents": 10010
            })).collect::<Vec<_>>(),
            "cash_bps": [0, 0, 0, 0]
        });
        let dataset = Dataset::parse(&dataset_value).unwrap();
        let spec: Spec = serde_json::from_value(good_spec()).unwrap();
        assert!(spec.valid());
        let first = crate::momentum::evaluate(&spec, &dataset).unwrap();
        assert_eq!(first, crate::momentum::evaluate(&spec, &dataset).unwrap());
        assert_eq!(first["outcome"], "diagnostic_only");
    }

    #[test]
    fn verify_combines_all_three_gates() {
        let manifest = good_manifest();
        let result = verify(&manifest, DispatchState::Completed, true);
        assert_eq!(result.validity, Validity::Valid);
        assert_eq!(result.reproducibility, Reproducibility::Reproduced);
        assert_eq!(result.readiness, Readiness::Ready);
        let open_lineage = verify(&manifest, DispatchState::Completed, false);
        assert_eq!(
            open_lineage.reproducibility,
            Reproducibility::Diverged {
                reason: "lineage_open".into()
            }
        );
    }

    #[test]
    fn cost_controls_untouched_by_this_module() {
        let source = include_str!("research_contract.rs");
        let capacity_guard = concat!("openrouter", "_capacity");
        let tier_guard = concat!("allow", "_paid");
        let policy_guard = concat!("spend", "ing");
        assert!(
            !source.contains(capacity_guard),
            "research contracts must not reference provider cost admission"
        );
        assert!(
            !source.contains(tier_guard),
            "research contracts must not reference cost-bearing tiers"
        );
        assert!(
            !source.to_lowercase().contains(policy_guard),
            "research contracts must not touch cost policy"
        );
    }
}
