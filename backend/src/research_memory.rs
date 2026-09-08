//! PR2 Institutional Memory admission + containment (wayfinder map #171,
//! decision #173, rollout #176).
//!
//! Pure, deterministic checks mirroring
//! `db/migrations/0097_memory_admission.sql`: full-lineage lessons,
//! lineage-disjoint support, typed scope + expiry, versioned dissent,
//! duplicate linkage to a canonical lesson, and sticky containment (suspend
//! / supersede / expire / contaminate). Memory admits methods guidance only:
//! any recipe, acceptance-check, or authority semantics in guidance is
//! rejected at the boundary.
//!
//! This module performs no dispatch, admits no model or cost authority,
//! records no outcomes, and changes no route, tier, or execution policy. It
//! reuses the canonical desk-role and posture sets from
//! [`crate::research_contract`] so scope validation cannot drift from the
//! assignment contract. Model identities stay opaque text throughout; no
//! concrete model is named here.
//!
//! Digest note (PR1 B1 carryover): canonicalization is caller-owned. Digests
//! travel as PRECOMPUTED strings (`recorded_*` as stored, `recomputed_*` as
//! recomputed by the caller's canonicalizer) and are compared with string
//! equality only; this module never serializes a `serde_json::Value` itself.
//! The SQL admission functions remain authoritative for stored content.
//! `now` is always a caller-supplied RFC3339 instant (pure, no clock reads).

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::research_contract::{
    AssignmentPins, AUTHORITY_KEYS, CONTRACT_RUNNER, DESK_ROLES, POSTURE_PROFILES,
};

/// Domain separator for lesson content digests computed with this runtime.
pub const LESSON_DIGEST_DOMAIN: &str = "market-mate-research-lesson-v1";

/// Closed scope-type set. Mirrors the `research_lesson_scope_is_valid`
/// branches in SQL.
pub const LESSON_SCOPE_TYPES: [&str; 3] = ["global", "role_posture", "method_data"];

/// Closed status set. Mirrors the `research_lesson` status CHECK in SQL.
pub const LESSON_STATUSES: [&str; 6] = [
    "proposed",
    "admitted",
    "suspended",
    "superseded",
    "expired",
    "contaminated",
];

/// Gate-change deny list: the text analogue of the authority-key scan in
/// `research_contract` (same eleven keys, same meaning) plus the
/// recipe/acceptance keywords that mark the memory-admission boundary.
/// Guidance carrying any of these words is methods-inadmissible; recipe and
/// acceptance-check changes require a reviewed PR and can never be promoted
/// through memory admission. B3: built from AUTHORITY_KEYS (no duplication);
/// the first eleven entries are AUTHORITY_KEYS verbatim (cross-checked by
/// test), plus recipe/acceptance.
pub const GATE_CHANGE_KEYS: [&str; 13] = [
    AUTHORITY_KEYS[0],
    AUTHORITY_KEYS[1],
    AUTHORITY_KEYS[2],
    AUTHORITY_KEYS[3],
    AUTHORITY_KEYS[4],
    AUTHORITY_KEYS[5],
    AUTHORITY_KEYS[6],
    AUTHORITY_KEYS[7],
    AUTHORITY_KEYS[8],
    AUTHORITY_KEYS[9],
    AUTHORITY_KEYS[10],
    "recipe",
    "acceptance",
];

/// Typed scope plus its scope key. Unknown fields are rejected so the scope
/// set cannot silently grow new coordinates.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LessonScope {
    pub scope_type: String,
    pub scope_key: serde_json::Value,
}

/// Lesson lifecycle status. Containment is sticky: there is no edge back to
/// admitted, and recovery is a new lesson.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum LessonStatus {
    Proposed,
    Admitted,
    Suspended,
    Superseded,
    Expired,
    Contaminated,
}

/// Full lineage for one lesson: proposing + critiquing assignment/run, the
/// actual provider session and model (opaque, never a hardcoded identity) +
/// critiquing session/model + config revision, recipe/contract versions,
/// canonical source artifact IDs, and declared shared dependencies. Unknown
/// fields are rejected. S2: critiquing session/model are required so support
/// disjointness checks all four coordinates against BOTH lineages.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LessonProvenance {
    pub proposing_assignment_id: String,
    pub proposing_run_key: String,
    pub critiquing_assignment_id: String,
    pub critiquing_run_key: String,
    pub provider_id: String,
    pub provider_session: String,
    pub model_id: String,
    pub critiquing_provider_session: String,
    pub critiquing_model_id: String,
    pub config_revision: i64,
    pub recipe_version: String,
    pub contract_runner: String,
    pub source_artifact_ids: Vec<String>,
    pub shared_dependencies: Vec<String>,
}

/// One lineage-disjoint support attestation. Unknown fields are rejected.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LessonSupport {
    pub assignment_id: String,
    pub run_key: String,
    pub provider_session: String,
    pub model_id: String,
}

/// One versioned dissent entry. Dissent is preserved on the lesson, never
/// dropped by admission.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct DissentEntry {
    pub assignment_id: String,
    pub run_key: String,
    pub note: String,
}

/// Versioned dissent container. Unknown fields are rejected.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct LessonDissent {
    pub version: i64,
    pub entries: Vec<DissentEntry>,
}

/// One institutional memory lesson. `guidance_digest` is a caller-supplied
/// PRECOMPUTED digest of the guidance text (see the module digest note);
/// `expires_at` is RFC3339 and is always evaluated against a caller-supplied
/// `now`. Unknown fields are rejected.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct Lesson {
    pub lesson_key: String,
    pub scope: LessonScope,
    pub guidance: String,
    pub guidance_digest: String,
    pub provenance: LessonProvenance,
    pub support: Vec<LessonSupport>,
    pub dissent: LessonDissent,
    pub status: LessonStatus,
    pub successor_lesson_key: Option<String>,
    pub canonical_lesson_key: Option<String>,
    pub expires_at: String,
}

/// Retrieval effect of one lesson row: directly retrievable, blocked with a
/// static reason, or resolved to another exact key (successor on supersede,
/// canonical on duplicates).
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum Containment {
    Retrievable,
    Blocked { reason: String },
    ResolvesTo { lesson_key: String },
    CanonicalLink { lesson_key: String },
}

fn non_blank(value: &str) -> bool {
    !value.trim().is_empty()
}

/// UUID shape check without new dependencies: `8-4-4-4-12` hex with dashes,
/// matching what Postgres `::uuid` accepts for canonical ids.
fn is_valid_uuid_text(value: &str) -> bool {
    let trimmed = value.trim();
    if trimmed.len() != 36 {
        return false;
    }
    let bytes = trimmed.as_bytes();
    if bytes[8] != b'-' || bytes[13] != b'-' || bytes[18] != b'-' || bytes[23] != b'-' {
        return false;
    }
    for (i, b) in bytes.iter().enumerate() {
        if [8, 13, 18, 23].contains(&i) {
            continue;
        }
        if !b.is_ascii_hexdigit() {
            return false;
        }
    }
    true
}

/// Canonical content digest for callers that canonicalize with this runtime:
/// `sha256(domain | guidance_text)`. Gates below never call it implicitly;
/// digests travel precomputed (module digest note).
pub fn lesson_digest(guidance: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(LESSON_DIGEST_DOMAIN.as_bytes());
    hasher.update(b"|");
    hasher.update(guidance.as_bytes());
    hex::encode(hasher.finalize())
}

/// Compare PRECOMPUTED digests by string equality only. Never serializes.
pub fn content_matches(recorded_digest: &str, recomputed_digest: &str) -> bool {
    recorded_digest == recomputed_digest
}

/// Decision #173.1: every lineage coordinate present and wellformed.
/// Proposing and critiquing lineages must differ (separate critique), at
/// least one canonical source artifact must be named, and the contract
/// runner stays pinned to the existing workflow.
pub fn lineage_complete(lesson: &Lesson) -> Result<(), String> {
    let provenance = &lesson.provenance;
    if !non_blank(&lesson.lesson_key) {
        return Err("lineage:lesson_key_required".into());
    }
    if !is_valid_uuid_text(&provenance.proposing_assignment_id) {
        return Err("lineage:proposing_assignment_required".into());
    }
    if !non_blank(&provenance.proposing_run_key) {
        return Err("lineage:proposing_run_required".into());
    }
    if !is_valid_uuid_text(&provenance.critiquing_assignment_id) {
        return Err("lineage:critiquing_assignment_required".into());
    }
    if !non_blank(&provenance.critiquing_run_key) {
        return Err("lineage:critiquing_run_required".into());
    }
    if provenance.proposing_assignment_id.trim().to_lowercase()
        == provenance.critiquing_assignment_id.trim().to_lowercase()
    {
        return Err("lineage:critique_must_be_separate_assignment".into());
    }
    if provenance.proposing_run_key.trim() == provenance.critiquing_run_key.trim() {
        return Err("lineage:critique_must_be_separate_run".into());
    }
    if !non_blank(&provenance.provider_id) {
        return Err("lineage:provider_required".into());
    }
    if !non_blank(&provenance.provider_session) {
        return Err("lineage:provider_session_required".into());
    }
    if !non_blank(&provenance.model_id) {
        return Err("lineage:model_required".into());
    }
    // S2: critiquing session/model required; support must differ from both.
    if !non_blank(&provenance.critiquing_provider_session) {
        return Err("lineage:critiquing_provider_session_required".into());
    }
    if !non_blank(&provenance.critiquing_model_id) {
        return Err("lineage:critiquing_model_required".into());
    }
    if provenance.config_revision < 0 {
        return Err("lineage:config_revision_must_be_nonnegative".into());
    }
    if !non_blank(&provenance.recipe_version) {
        return Err("lineage:recipe_version_required".into());
    }
    if provenance.contract_runner.trim() != CONTRACT_RUNNER {
        return Err("lineage:contract_runner_must_be_momentum_v1".into());
    }
    if provenance.source_artifact_ids.is_empty() {
        return Err("lineage:source_artifact_required".into());
    }
    if provenance
        .source_artifact_ids
        .iter()
        .any(|id| !is_valid_uuid_text(id))
    {
        return Err("lineage:source_artifact_must_be_uuid".into());
    }
    if provenance
        .shared_dependencies
        .iter()
        .any(|dep| !non_blank(dep))
    {
        return Err("lineage:shared_dependency_must_be_nonblank".into());
    }
    if lesson.support.is_empty() {
        return Err("lineage:support_required".into());
    }
    for attestation in &lesson.support {
        if !is_valid_uuid_text(&attestation.assignment_id) {
            return Err("lineage:support_assignment_must_be_uuid".into());
        }
        if !non_blank(&attestation.run_key)
            || !non_blank(&attestation.provider_session)
            || !non_blank(&attestation.model_id)
        {
            return Err("lineage:support_attestation_incomplete".into());
        }
    }
    if lesson.dissent.version < 1 {
        return Err("lineage:dissent_version_must_be_positive".into());
    }
    for entry in &lesson.dissent.entries {
        if !is_valid_uuid_text(&entry.assignment_id) {
            return Err("lineage:dissent_assignment_must_be_uuid".into());
        }
        if !non_blank(&entry.run_key) || !non_blank(&entry.note) {
            return Err("lineage:dissent_entry_incomplete".into());
        }
    }
    if chrono::DateTime::parse_from_rfc3339(lesson.expires_at.trim()).is_err() {
        return Err("lineage:expires_at_must_be_rfc3339".into());
    }
    match lesson.successor_lesson_key.as_deref() {
        Some(key) if !non_blank(key) => {
            return Err("lineage:successor_must_be_nonblank".into());
        }
        Some(_) if lesson.status != LessonStatus::Superseded => {
            return Err("lineage:successor_only_on_superseded".into());
        }
        None if lesson.status == LessonStatus::Superseded => {
            return Err("lineage:superseded_requires_successor".into());
        }
        _ => {}
    }
    if let Some(canonical) = lesson.canonical_lesson_key.as_deref() {
        if !non_blank(canonical) {
            return Err("lineage:canonical_must_be_nonblank".into());
        }
        if canonical.trim() == lesson.lesson_key.trim() {
            return Err("lineage:canonical_must_differ".into());
        }
    }
    Ok(())
}

/// Decision #173.2: support counts only with disjoint lineages. Each
/// attestation must differ from the proposing and critiquing coordinates on
/// all four axes (assignment, run, provider session, model), and every pair
/// must differ on all four. Model agreement, repeats, and self-review fail
/// here and never corroborate.
pub fn support_disjoint(lesson: &Lesson) -> Result<(), String> {
    let provenance = &lesson.provenance;
    let proposing_assignment = provenance.proposing_assignment_id.trim().to_lowercase();
    let critiquing_assignment = provenance.critiquing_assignment_id.trim().to_lowercase();
    let proposing_run = provenance.proposing_run_key.trim();
    let critiquing_run = provenance.critiquing_run_key.trim();
    let proposing_session = provenance.provider_session.trim();
    let proposing_model = provenance.model_id.trim();
    // S2: critiquing session/model; each attestation must differ from BOTH.
    let critiquing_session = provenance.critiquing_provider_session.trim();
    let critiquing_model = provenance.critiquing_model_id.trim();
    for attestation in &lesson.support {
        let assignment = attestation.assignment_id.trim().to_lowercase();
        if assignment == proposing_assignment || assignment == critiquing_assignment {
            return Err("support:self_review".into());
        }
        let run = attestation.run_key.trim();
        if run == proposing_run || run == critiquing_run {
            return Err("support:repeated_run".into());
        }
        let session = attestation.provider_session.trim();
        if session == proposing_session || session == critiquing_session {
            return Err("support:shared_session".into());
        }
        let model = attestation.model_id.trim();
        if model == proposing_model || model == critiquing_model {
            return Err("support:shared_model".into());
        }
    }
    for (first_index, first) in lesson.support.iter().enumerate() {
        for second in lesson.support.iter().skip(first_index + 1) {
            if first.assignment_id.trim().to_lowercase()
                == second.assignment_id.trim().to_lowercase()
            {
                return Err("support:repeated_assignment".into());
            }
            if first.run_key.trim() == second.run_key.trim() {
                return Err("support:repeated_run".into());
            }
            if first.provider_session.trim() == second.provider_session.trim() {
                return Err("support:shared_session".into());
            }
            if first.model_id.trim() == second.model_id.trim() {
                return Err("support:shared_model".into());
            }
        }
    }
    Ok(())
}

/// Decision #173.3: scope shape. Global carries an empty object;
/// role_posture carries exactly desk_role + posture_profile from the
/// canonical contract sets; method_data carries exactly contract_runner +
/// recipe_version. B2: LESSON_SCOPE_TYPES is the closed set (referenced
/// below so the constant cannot drift dead).
pub fn scope_wellformed(scope: &LessonScope) -> Result<(), String> {
    let scope_type = scope.scope_type.trim().to_lowercase();
    // B2: reference the closed scope-type set so dead constants fail loudly.
    if !LESSON_SCOPE_TYPES.contains(&scope_type.as_str()) {
        return Err("scope:unknown_scope_type".into());
    }
    let key = scope
        .scope_key
        .as_object()
        .ok_or_else(|| "scope:scope_key_must_be_object".to_string())?;
    match scope_type.as_str() {
        "global" => {
            if key.is_empty() {
                Ok(())
            } else {
                Err("scope:global_key_must_be_empty".into())
            }
        }
        "role_posture" => {
            if key.len() != 2
                || !key.contains_key("desk_role")
                || !key.contains_key("posture_profile")
            {
                return Err("scope:role_posture_requires_role_and_posture".into());
            }
            let role = key["desk_role"]
                .as_str()
                .unwrap_or("")
                .trim()
                .to_lowercase();
            // The admitted desk-role set excludes every charter-forbidden
            // role, so membership covers both SQL checks.
            if !DESK_ROLES.contains(&role.as_str()) {
                return Err("scope:desk_role_not_admitted".into());
            }
            let posture = key["posture_profile"].as_str().unwrap_or("").trim();
            if !POSTURE_PROFILES.contains(&posture) {
                return Err("scope:posture_not_canonical".into());
            }
            Ok(())
        }
        "method_data" => {
            if key.len() != 2
                || !key.contains_key("contract_runner")
                || !key.contains_key("recipe_version")
            {
                return Err("scope:method_data_requires_runner_and_recipe".into());
            }
            let runner = key["contract_runner"].as_str().unwrap_or("").trim();
            if runner != CONTRACT_RUNNER {
                return Err("scope:contract_runner_must_be_momentum_v1".into());
            }
            let recipe = key["recipe_version"].as_str().unwrap_or("");
            if !non_blank(recipe) {
                return Err("scope:recipe_version_required".into());
            }
            Ok(())
        }
        _ => Err("scope:unknown_scope_type".into()),
    }
}

/// Decision #173.3: scope applicability of one lesson to one pinned
/// assignment. Malformed scopes fail closed (Err); wellformed scopes report
/// whether the assignment falls inside.
pub fn scope_applies(scope: &LessonScope, pins: &AssignmentPins) -> Result<bool, String> {
    scope_wellformed(scope)?;
    let key = scope.scope_key.as_object().expect("scope is wellformed");
    match scope.scope_type.trim().to_lowercase().as_str() {
        "global" => Ok(true),
        "role_posture" => {
            let role = key["desk_role"]
                .as_str()
                .unwrap_or("")
                .trim()
                .to_lowercase();
            let posture = key["posture_profile"].as_str().unwrap_or("").trim();
            Ok(role == pins.desk_role.trim().to_lowercase()
                && posture == pins.posture_profile.trim())
        }
        "method_data" => {
            let runner = key["contract_runner"].as_str().unwrap_or("").trim();
            let recipe = key["recipe_version"].as_str().unwrap_or("").trim();
            Ok(runner == pins.contract_runner.trim() && recipe == pins.recipe_version.trim())
        }
        _ => Err("scope:unknown_scope_type".into()),
    }
}

/// Decision #173.3: freshness against a caller-supplied clock. Expiry at or
/// before `now` is expired; an unparseable caller clock fails closed.
pub fn freshness_ok(expires_at_rfc3339: &str, now_rfc3339: &str) -> Result<(), String> {
    let expires = chrono::DateTime::parse_from_rfc3339(expires_at_rfc3339.trim())
        .map_err(|_| "freshness:expires_at_must_be_rfc3339".to_string())?;
    let now = chrono::DateTime::parse_from_rfc3339(now_rfc3339.trim())
        .map_err(|_| "freshness:invalid_now".to_string())?;
    if expires <= now {
        return Err("freshness:expired".into());
    }
    Ok(())
}

/// Decision #173.6: gate-change detection over free-text guidance. Any
/// deny-list word (authority keys plus recipe/acceptance) at a word boundary
/// marks guidance that touches recipe, acceptance-check, or authority
/// semantics. S3: multi-word keys match across space/hyphen/underscore
/// separators and single-word keys match plurals (see the SQL alternates);
/// word-boundary semantics keep substrings such as "deliver" and "paperwork"
/// from tripping. Mirrors the SQL `research_lesson_guidance_is_admissible`
/// alternates: separators normalize to word splits and a trailing `s` is
/// stripped before comparing; single-word boundary behavior is preserved
/// (no substring hits).
pub fn gate_change_detected(guidance: &str) -> bool {
    // Split on any non-alphanumeric (including underscore, space, hyphen)
    // into lowercase words, strip one trailing `s` (SQL plural alternate),
    // then match single words and adjacent phrases.
    let mut words: Vec<String> = Vec::new();
    let mut cur = String::new();
    for ch in guidance.to_lowercase().chars() {
        if ch.is_ascii_alphanumeric() {
            cur.push(ch);
        } else if !cur.is_empty() {
            // Strip a single trailing `s` to mirror SQL plurals. Words of
            // length <= 2 are left alone to avoid turning "is"/"as" into
            // empty hits (harmless either way since they never match keys).
            if cur.len() > 2 && cur.ends_with('s') {
                cur.pop();
            }
            words.push(std::mem::take(&mut cur));
        }
    }
    if !cur.is_empty() {
        if cur.len() > 2 && cur.ends_with('s') {
            cur.pop();
        }
        words.push(cur);
    }
    // Single-word deny keys (after singularization, see GATE_CHANGE_KEYS).
    // Multi-word keys are checked as phrases below.
    for w in &words {
        if GATE_CHANGE_KEYS.contains(&w.as_str()) {
            return true;
        }
    }
    // Multi-word phrases (each element already singularized): lifecycle+state,
    // execution+environment, execution+authority, strategy/paper/trade
    // +eligible, acceptance+check, and the 5-word execution edge phrase.
    for pair in words.windows(2) {
        match (pair[0].as_str(), pair[1].as_str()) {
            ("lifecycle", "state")
            | ("execution", "environment")
            | ("execution", "authority")
            | ("strategy", "eligible")
            | ("paper", "eligible")
            | ("trade", "eligible")
            | ("acceptance", "check") => return true,
            _ => {}
        }
    }
    for win in words.windows(5) {
        if win[0] == "execution"
            && win[1] == "edge"
            && win[2] == "and"
            && win[3] == "paper"
            && win[4] == "trading"
        {
            return true;
        }
    }
    false
}

/// Decision #173.4: a duplicate must never count its canonical lesson's
/// supporters as separate support. No supporting assignment may be reused
/// across the duplicate and its canonical lesson.
pub fn duplicate_support_ok(
    candidate_support: &[LessonSupport],
    canonical_support: &[LessonSupport],
) -> Result<(), String> {
    let canonical_assignments: HashSet<String> = canonical_support
        .iter()
        .map(|attestation| attestation.assignment_id.trim().to_lowercase())
        .collect();
    if candidate_support.iter().any(|attestation| {
        canonical_assignments.contains(&attestation.assignment_id.trim().to_lowercase())
    }) {
        return Err("support:duplicate_reuses_canonical".into());
    }
    Ok(())
}

/// Decision #173.5: retrieval effect of one row. Duplicates always resolve to
/// their canonical key; superseded lessons resolve to their successor (a
/// missing successor blocks); only admitted lessons are retrievable. B2:
/// LESSON_STATUSES is the closed status set (referenced below so the constant
/// cannot drift dead).
pub fn containment_effect(lesson: &Lesson) -> Containment {
    // B2: reference the closed status set; unknown statuses fail closed.
    let status_str = match lesson.status {
        LessonStatus::Proposed => "proposed",
        LessonStatus::Admitted => "admitted",
        LessonStatus::Suspended => "suspended",
        LessonStatus::Superseded => "superseded",
        LessonStatus::Expired => "expired",
        LessonStatus::Contaminated => "contaminated",
    };
    debug_assert!(LESSON_STATUSES.contains(&status_str));
    if !LESSON_STATUSES.contains(&status_str) {
        return Containment::Blocked {
            reason: "unknown_status".into(),
        };
    }
    if let Some(canonical) = lesson.canonical_lesson_key.as_deref() {
        if non_blank(canonical) {
            return Containment::CanonicalLink {
                lesson_key: canonical.trim().to_string(),
            };
        }
    }
    match lesson.status {
        LessonStatus::Admitted => Containment::Retrievable,
        LessonStatus::Proposed => Containment::Blocked {
            reason: "not_admitted".into(),
        },
        LessonStatus::Suspended => Containment::Blocked {
            reason: "suspended".into(),
        },
        LessonStatus::Expired => Containment::Blocked {
            reason: "expired".into(),
        },
        LessonStatus::Contaminated => Containment::Blocked {
            reason: "contaminated".into(),
        },
        LessonStatus::Superseded => match lesson.successor_lesson_key.as_deref() {
            Some(successor) if non_blank(successor) => Containment::ResolvesTo {
                lesson_key: successor.trim().to_string(),
            },
            _ => Containment::Blocked {
                reason: "missing_successor".into(),
            },
        },
    }
}

/// Admission decision for one lesson: full lineage, disjoint support, valid
/// scope, admissible guidance, freshness, and (for duplicates) no reused
/// canonical support. Dissent passes through untouched: admission preserves
/// it, never drops it. Status edges stay with the SQL transition functions.
/// B1: empty/blank guidance is inadmissible (mirrors SQL btrim <> '').
pub fn admissible(
    lesson: &Lesson,
    canonical: Option<&Lesson>,
    now_rfc3339: &str,
) -> Result<(), String> {
    lineage_complete(lesson)?;
    support_disjoint(lesson)?;
    scope_wellformed(&lesson.scope)?;
    // B1: non-blank guidance check (SQL CHECK btrim(guidance) <> '').
    if !non_blank(&lesson.guidance) {
        return Err("admission:guidance_required".into());
    }
    if gate_change_detected(&lesson.guidance) {
        return Err("admission:gate_change".into());
    }
    freshness_ok(&lesson.expires_at, now_rfc3339)?;
    if let Some(canonical_lesson) = canonical {
        if canonical_lesson
            .canonical_lesson_key
            .as_deref()
            .is_some_and(non_blank)
        {
            return Err("admission:canonical_is_duplicate".into());
        }
        duplicate_support_ok(&lesson.support, &canonical_lesson.support)?;
    } else if lesson
        .canonical_lesson_key
        .as_deref()
        .is_some_and(non_blank)
    {
        return Err("admission:canonical_missing".into());
    }
    Ok(())
}

/// Decision #173.3 + #173.5: retrieval over a candidate set. Resolves
/// canonical links and successor chains transitively (cycle-safe, hop-capped;
/// broken links exclude the lesson), then keeps only admitted, in-scope,
/// unexpired lessons. Returns sorted exact lesson keys, deduplicated: rows
/// are pinned content, never latest-floating references. Malformed scopes,
/// failed freshness, and an unparseable caller clock all fail closed to
/// exclusion.
pub fn retrievable_keys(
    lessons: &[Lesson],
    pins: &AssignmentPins,
    now_rfc3339: &str,
) -> Vec<String> {
    if chrono::DateTime::parse_from_rfc3339(now_rfc3339.trim()).is_err() {
        return Vec::new();
    }
    let by_key: HashMap<&str, &Lesson> = lessons
        .iter()
        .map(|lesson| (lesson.lesson_key.trim(), lesson))
        .collect();
    let mut emitted: HashSet<String> = HashSet::new();
    for lesson in lessons {
        let mut current = lesson;
        let mut visited: HashSet<&str> = HashSet::new();
        let resolved = loop {
            match containment_effect(current) {
                Containment::Retrievable => break Some(current),
                Containment::Blocked { .. } => break None,
                Containment::ResolvesTo { lesson_key }
                | Containment::CanonicalLink { lesson_key } => {
                    if !visited.insert(current.lesson_key.trim()) {
                        break None;
                    }
                    // B6: hop cap mirrors SQL hop_count > 16 (read path caps
                    // at 16; min with len keeps small sets tight).
                    if visited.len() > lessons.len().min(16) {
                        break None;
                    }
                    match by_key.get(lesson_key.as_str()) {
                        Some(next) => current = next,
                        None => break None,
                    }
                }
            }
        };
        let Some(target) = resolved else {
            continue;
        };
        if freshness_ok(&target.expires_at, now_rfc3339).is_err() {
            continue;
        }
        match scope_applies(&target.scope, pins) {
            Ok(true) => {
                emitted.insert(target.lesson_key.trim().to_string());
            }
            _ => continue,
        }
    }
    let mut keys: Vec<String> = emitted.into_iter().collect();
    keys.sort();
    keys
}

/// Whether one pinned status needs explicit consumer review: everything that
/// is not admitted, never a silent re-pin.
pub fn needs_pinned_review(status: &LessonStatus) -> bool {
    *status != LessonStatus::Admitted
}

/// Decision #173.5: flag every pinned key whose status is not admitted.
/// B5: callers must treat keys absent from the DB as review (SQL
/// `research_lesson_pinned_review` flags unknown keys); this pure helper only
/// sees caller-supplied statuses, so absent keys must be flagged by the
/// caller, never silently re-pinned. No signature change.
/// B4: deduplicated via HashSet (like retrievable_keys).
pub fn pinned_review(pinned: &[(&str, LessonStatus)]) -> Vec<String> {
    let flagged_set: HashSet<String> = pinned
        .iter()
        .filter(|(_, status)| needs_pinned_review(status))
        .map(|(key, _)| key.trim().to_string())
        .collect();
    let mut flagged: Vec<String> = flagged_set.into_iter().collect();
    flagged.sort();
    flagged
}

/// Parse helper: unknown fields are rejected.
pub fn parse_lesson(value: &serde_json::Value) -> Result<Lesson, String> {
    serde_json::from_value(value.clone()).map_err(|_| "invalid_lesson_schema".to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    const TEST_NOW: &str = "2026-09-08T00:00:00Z";
    const PROPOSER: &str = "11111111-1111-4111-8111-111111111111";
    const CRITIC: &str = "22222222-2222-4222-8222-222222222222";
    const SUPPORTER_A: &str = "33333333-3333-4333-8333-333333333333";
    const SUPPORTER_B: &str = "44444444-4444-4444-8444-444444444444";
    const OUTSIDER: &str = "55555555-5555-4555-8555-555555555555";
    const SOURCE_ARTIFACT: &str = "66666666-6666-4666-8666-666666666666";

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

    fn good_provenance() -> LessonProvenance {
        LessonProvenance {
            proposing_assignment_id: PROPOSER.into(),
            proposing_run_key: "run-proposer-1".into(),
            critiquing_assignment_id: CRITIC.into(),
            critiquing_run_key: "run-critic-1".into(),
            provider_id: "probe-provider".into(),
            provider_session: "sess-proposer-1".into(),
            model_id: "probe-model-a".into(),
            // S2: critiquing session/model (must differ from support).
            critiquing_provider_session: "sess-critic-1".into(),
            critiquing_model_id: "probe-model-critic".into(),
            config_revision: 3,
            recipe_version: "recipe-v2".into(),
            contract_runner: "momentum_v1".into(),
            source_artifact_ids: vec![SOURCE_ARTIFACT.into()],
            shared_dependencies: vec!["shared-dep-1".into()],
        }
    }

    fn support(assignment: &str, run: &str, session: &str, model: &str) -> LessonSupport {
        LessonSupport {
            assignment_id: assignment.into(),
            run_key: run.into(),
            provider_session: session.into(),
            model_id: model.into(),
        }
    }

    fn good_support() -> Vec<LessonSupport> {
        vec![
            support(
                SUPPORTER_A,
                "run-support-a",
                "sess-support-a",
                "probe-model-b",
            ),
            support(
                SUPPORTER_B,
                "run-support-b",
                "sess-support-b",
                "probe-model-c",
            ),
        ]
    }

    fn good_dissent() -> LessonDissent {
        LessonDissent {
            version: 1,
            entries: vec![DissentEntry {
                assignment_id: CRITIC.into(),
                run_key: "run-critic-1".into(),
                note: "critic note preserved".into(),
            }],
        }
    }

    fn good_lesson(key: &str) -> Lesson {
        let guidance =
            "Prefer wider lookback windows when session noise is high; keep quantile counts pinned.";
        Lesson {
            lesson_key: key.into(),
            scope: LessonScope {
                scope_type: "global".into(),
                scope_key: json!({}),
            },
            guidance: guidance.into(),
            guidance_digest: lesson_digest(guidance),
            provenance: good_provenance(),
            support: good_support(),
            dissent: good_dissent(),
            status: LessonStatus::Admitted,
            successor_lesson_key: None,
            canonical_lesson_key: None,
            expires_at: "2030-06-01T00:00:00Z".into(),
        }
    }

    #[test]
    fn lineage_accepts_complete_lesson() {
        let lesson = good_lesson("lesson-complete");
        assert_eq!(lineage_complete(&lesson), Ok(()));
        assert_eq!(support_disjoint(&lesson), Ok(()));
        assert_eq!(
            admissible(&lesson, None, TEST_NOW),
            Ok(()),
            "a complete, disjoint, fresh lesson with methods guidance is admissible"
        );
    }

    #[test]
    fn lineage_rejects_missing_coordinates() {
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.proposing_assignment_id = "   ".into();
        assert!(lineage_complete(&lesson).is_err());
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.model_id = String::new();
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:model_required".to_string())
        );
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.source_artifact_ids = vec![];
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:source_artifact_required".to_string())
        );
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.source_artifact_ids = vec!["not-a-uuid".into()];
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:source_artifact_must_be_uuid".to_string())
        );
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.config_revision = -1;
        assert!(lineage_complete(&lesson).is_err());
        let mut lesson = good_lesson("lesson-missing");
        lesson.provenance.contract_runner = "alpha_v9".into();
        assert!(lineage_complete(&lesson).is_err());
        let mut lesson = good_lesson("lesson-missing");
        lesson.support = vec![];
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:support_required".to_string())
        );
    }

    #[test]
    fn lineage_rejects_shared_proposer_critic() {
        let mut lesson = good_lesson("lesson-shared");
        lesson.provenance.critiquing_assignment_id = PROPOSER.into();
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:critique_must_be_separate_assignment".to_string())
        );
        let mut lesson = good_lesson("lesson-shared");
        lesson.provenance.critiquing_run_key = "run-proposer-1".into();
        assert_eq!(
            lineage_complete(&lesson),
            Err("lineage:critique_must_be_separate_run".to_string())
        );
    }

    #[test]
    fn support_rejects_self_review() {
        // Support from the proposing assignment is the evaluator reviewing
        // its own lineage: it collapses, never corroborates.
        let mut lesson = good_lesson("lesson-self");
        lesson.support = vec![support(
            PROPOSER,
            "run-other-1",
            "sess-other-1",
            "probe-model-z",
        )];
        assert_eq!(support_disjoint(&lesson), Err("support:self_review".into()));
        let mut lesson = good_lesson("lesson-self");
        lesson.support = vec![support(
            CRITIC,
            "run-other-2",
            "sess-other-2",
            "probe-model-z",
        )];
        assert_eq!(support_disjoint(&lesson), Err("support:self_review".into()));
        // Support reusing the proposer's run key is a repeat, not support.
        let mut lesson = good_lesson("lesson-self");
        lesson.support = vec![support(
            OUTSIDER,
            "run-proposer-1",
            "sess-other-3",
            "probe-model-z",
        )];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:repeated_run".into())
        );
    }

    #[test]
    fn support_rejects_shared_session_and_model() {
        let mut lesson = good_lesson("lesson-session");
        lesson.support = vec![support(
            SUPPORTER_A,
            "run-x-1",
            "sess-proposer-1",
            "probe-model-z",
        )];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_session".into())
        );
        let mut lesson = good_lesson("lesson-session");
        lesson.support = vec![support(SUPPORTER_A, "run-x-2", "sess-x-2", "probe-model-a")];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_model".into())
        );
        // Two attestations sharing a session are one voice, not two.
        let mut lesson = good_lesson("lesson-session");
        lesson.support = vec![
            support(SUPPORTER_A, "run-x-3", "sess-shared-9", "probe-model-y"),
            support(SUPPORTER_B, "run-x-4", "sess-shared-9", "probe-model-z"),
        ];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_session".into())
        );
        // Model agreement never corroborates: same model twice collapses.
        let mut lesson = good_lesson("lesson-session");
        lesson.support = vec![
            support(SUPPORTER_A, "run-x-5", "sess-x-5", "probe-model-y"),
            support(SUPPORTER_B, "run-x-6", "sess-x-6", "probe-model-y"),
        ];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_model".into())
        );
    }

    #[test]
    fn support_rejects_repeated_assignments() {
        // The same assignment twice, even under a different run key, is a
        // repeat and collapses to one.
        let mut lesson = good_lesson("lesson-repeat");
        lesson.support = vec![
            support(SUPPORTER_A, "run-x-7", "sess-x-7", "probe-model-y"),
            support(SUPPORTER_A, "run-x-8", "sess-x-8", "probe-model-z"),
        ];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:repeated_assignment".into())
        );
        // Exact duplicate attestations share every coordinate: rejected.
        let mut lesson = good_lesson("lesson-repeat");
        lesson.support = vec![
            support(SUPPORTER_A, "run-x-9", "sess-x-9", "probe-model-y"),
            support(SUPPORTER_A, "run-x-9", "sess-x-9", "probe-model-y"),
        ];
        assert!(support_disjoint(&lesson).is_err());
    }

    #[test]
    fn scope_accepts_all_types_and_matches_pins() {
        let pins = good_pins();
        let global = LessonScope {
            scope_type: "global".into(),
            scope_key: json!({}),
        };
        assert_eq!(scope_wellformed(&global), Ok(()));
        assert_eq!(scope_applies(&global, &pins), Ok(true));
        let role_posture = LessonScope {
            scope_type: "role_posture".into(),
            scope_key: json!({
                "desk_role": "quantitative_research_and_experimentation",
                "posture_profile": "Balanced Investigator",
            }),
        };
        assert_eq!(scope_wellformed(&role_posture), Ok(()));
        assert_eq!(scope_applies(&role_posture, &pins), Ok(true));
        let method_data = LessonScope {
            scope_type: "method_data".into(),
            scope_key: json!({
                "contract_runner": "momentum_v1",
                "recipe_version": "recipe-v2",
            }),
        };
        assert_eq!(scope_wellformed(&method_data), Ok(()));
        assert_eq!(scope_applies(&method_data, &pins), Ok(true));
    }

    #[test]
    fn scope_rejects_mismatch_and_malformed() {
        let pins = good_pins();
        let other_role = LessonScope {
            scope_type: "role_posture".into(),
            scope_key: json!({
                "desk_role": "data_and_feature_research",
                "posture_profile": "Balanced Investigator",
            }),
        };
        assert_eq!(scope_applies(&other_role, &pins), Ok(false));
        let other_recipe = LessonScope {
            scope_type: "method_data".into(),
            scope_key: json!({
                "contract_runner": "momentum_v1",
                "recipe_version": "recipe-v9",
            }),
        };
        assert_eq!(scope_applies(&other_recipe, &pins), Ok(false));
        let unknown = LessonScope {
            scope_type: "team".into(),
            scope_key: json!({}),
        };
        assert_eq!(
            scope_wellformed(&unknown),
            Err("scope:unknown_scope_type".to_string())
        );
        assert!(scope_applies(&unknown, &pins).is_err());
        let extra_key = LessonScope {
            scope_type: "global".into(),
            scope_key: json!({"sizing": "high"}),
        };
        assert!(scope_wellformed(&extra_key).is_err());
        let bad_posture = LessonScope {
            scope_type: "role_posture".into(),
            scope_key: json!({
                "desk_role": "strategy_incubation",
                "posture_profile": "Reckless Gambler",
            }),
        };
        assert!(scope_wellformed(&bad_posture).is_err());
    }

    #[test]
    fn freshness_blocks_expired_and_bad_clocks() {
        assert_eq!(freshness_ok("2030-06-01T00:00:00Z", TEST_NOW), Ok(()));
        assert_eq!(
            freshness_ok("2001-01-01T00:00:00Z", TEST_NOW),
            Err("freshness:expired".to_string())
        );
        assert_eq!(
            freshness_ok(TEST_NOW, TEST_NOW),
            Err("freshness:expired".to_string())
        );
        assert_eq!(
            freshness_ok("2030-06-01T00:00:00Z", "soon"),
            Err("freshness:invalid_now".to_string())
        );
    }

    #[test]
    fn gate_change_detects_recipe_acceptance_and_authority_words() {
        assert!(!gate_change_detected(
            "Prefer wider lookback windows when session noise is high."
        ));
        // Substrings are not hits: "deliver" must not trip on "live".
        assert!(!gate_change_detected(
            "Lessons deliver methods guidance only."
        ));
        assert!(gate_change_detected("Promote recipe-v3 to required."));
        assert!(gate_change_detected(
            "Switch acceptance checks to auto-pass."
        ));
        assert!(gate_change_detected("Mark the strategy paper eligible."));
        assert!(gate_change_detected("Enable live trading for the desk."));
        assert!(gate_change_detected("Hand the order to a broker."));
        assert!(gate_change_detected("REQUIRE RECIPE-V9 FOR ALL RUNS."));
    }

    #[test]
    fn admissible_rejects_gate_change_guidance() {
        let mut lesson = good_lesson("lesson-gate");
        lesson.guidance =
            "Promote recipe-v3 to required and mark the strategy paper eligible.".into();
        lesson.guidance_digest = lesson_digest(&lesson.guidance);
        assert_eq!(
            admissible(&lesson, None, TEST_NOW),
            Err("admission:gate_change".into())
        );
        let mut lesson = good_lesson("lesson-gate");
        lesson.guidance = "Change the acceptance check so failing runs pass.".into();
        lesson.guidance_digest = lesson_digest(&lesson.guidance);
        assert!(gate_change_detected(&lesson.guidance));
        assert!(admissible(&lesson, None, TEST_NOW).is_err());
    }

    #[test]
    fn containment_blocks_suspended_expired_contaminated() {
        for (status, reason) in [
            (LessonStatus::Proposed, "not_admitted"),
            (LessonStatus::Suspended, "suspended"),
            (LessonStatus::Expired, "expired"),
            (LessonStatus::Contaminated, "contaminated"),
        ] {
            let mut lesson = good_lesson("lesson-blocked");
            lesson.status = status;
            assert_eq!(
                containment_effect(&lesson),
                Containment::Blocked {
                    reason: reason.into()
                }
            );
        }
        let lesson = good_lesson("lesson-open");
        assert_eq!(containment_effect(&lesson), Containment::Retrievable);
    }

    #[test]
    fn retrieval_resolves_superseded_to_successor() {
        let pins = good_pins();
        let mut old = good_lesson("lesson-old");
        old.status = LessonStatus::Superseded;
        old.successor_lesson_key = Some("lesson-new".into());
        let new = good_lesson("lesson-new");
        let keys = retrievable_keys(&[old, new], &pins, TEST_NOW);
        assert_eq!(keys, vec!["lesson-new".to_string()]);
    }

    #[test]
    fn retrieval_excludes_broken_successor_links() {
        let pins = good_pins();
        let mut old = good_lesson("lesson-old");
        old.status = LessonStatus::Superseded;
        old.successor_lesson_key = Some("lesson-missing".into());
        assert!(retrievable_keys(&[old], &pins, TEST_NOW).is_empty());
        // A successor cycle fails closed instead of looping.
        let mut first = good_lesson("lesson-cycle-a");
        first.status = LessonStatus::Superseded;
        first.successor_lesson_key = Some("lesson-cycle-b".into());
        let mut second = good_lesson("lesson-cycle-b");
        second.status = LessonStatus::Superseded;
        second.successor_lesson_key = Some("lesson-cycle-a".into());
        assert!(retrievable_keys(&[first, second], &pins, TEST_NOW).is_empty());
    }

    #[test]
    fn retrieval_blocks_unadmitted_and_expired_scopes() {
        let pins = good_pins();
        let mut suspended = good_lesson("lesson-suspended");
        suspended.status = LessonStatus::Suspended;
        let mut stale = good_lesson("lesson-stale");
        stale.expires_at = "2001-01-01T00:00:00Z".into();
        let mut narrow = good_lesson("lesson-narrow");
        narrow.scope = LessonScope {
            scope_type: "method_data".into(),
            scope_key: json!({
                "contract_runner": "momentum_v1",
                "recipe_version": "recipe-v9",
            }),
        };
        let open = good_lesson("lesson-open");
        let keys = retrievable_keys(&[suspended, stale, narrow, open], &pins, TEST_NOW);
        assert_eq!(keys, vec!["lesson-open".to_string()]);
    }

    #[test]
    fn duplicates_resolve_to_canonical_and_never_support() {
        let pins = good_pins();
        let canonical = good_lesson("lesson-canonical");
        let mut duplicate = good_lesson("lesson-duplicate");
        duplicate.canonical_lesson_key = Some("lesson-canonical".into());
        // Retrieval returns the canonical key once, never the duplicate.
        let keys = retrievable_keys(&[duplicate.clone(), canonical.clone()], &pins, TEST_NOW);
        assert_eq!(keys, vec!["lesson-canonical".to_string()]);
        // Reusing a canonical supporter as separate support is rejected.
        let reused = good_support();
        assert_eq!(
            duplicate_support_ok(&reused, &canonical.support),
            Err("support:duplicate_reuses_canonical".to_string())
        );
        let fresh = vec![support(
            OUTSIDER,
            "run-fresh-1",
            "sess-fresh-1",
            "probe-model-z",
        )];
        assert_eq!(duplicate_support_ok(&fresh, &canonical.support), Ok(()));
        // Admission without the canonical row fails closed.
        let mut orphan = good_lesson("lesson-orphan");
        orphan.canonical_lesson_key = Some("lesson-absent".into());
        assert_eq!(
            admissible(&orphan, None, TEST_NOW),
            Err("admission:canonical_missing".to_string())
        );
        // A duplicate of a duplicate is rejected.
        let mut chained = good_lesson("lesson-chained");
        chained.canonical_lesson_key = Some("lesson-duplicate".into());
        assert_eq!(
            admissible(&chained, Some(&duplicate), TEST_NOW),
            Err("admission:canonical_is_duplicate".to_string())
        );
    }

    #[test]
    fn dissent_survives_admission_versioned() {
        let lesson = good_lesson("lesson-dissent");
        assert_eq!(admissible(&lesson, None, TEST_NOW), Ok(()));
        // Admission preserves dissent verbatim: version plus every entry.
        assert_eq!(lesson.dissent.version, 1);
        assert_eq!(lesson.dissent.entries.len(), 1);
        assert_eq!(lesson.dissent.entries[0].note, "critic note preserved");
        let mut bare = good_lesson("lesson-bare");
        bare.dissent = LessonDissent {
            version: 2,
            entries: vec![],
        };
        assert_eq!(lineage_complete(&bare), Ok(()));
        let mut unversioned = good_lesson("lesson-unversioned");
        unversioned.dissent.version = 0;
        assert!(lineage_complete(&unversioned).is_err());
    }

    #[test]
    fn pinned_review_flags_everything_not_admitted() {
        assert!(pinned_review(&[("lesson-a", LessonStatus::Admitted)]).is_empty());
        assert_eq!(
            pinned_review(&[
                ("lesson-a", LessonStatus::Admitted),
                ("lesson-b", LessonStatus::Suspended),
                ("lesson-c", LessonStatus::Superseded),
                ("lesson-d", LessonStatus::Contaminated),
                ("lesson-e", LessonStatus::Expired),
                ("lesson-f", LessonStatus::Proposed),
            ]),
            vec![
                "lesson-b".to_string(),
                "lesson-c".to_string(),
                "lesson-d".to_string(),
                "lesson-e".to_string(),
                "lesson-f".to_string(),
            ]
        );
        assert!(needs_pinned_review(&LessonStatus::Suspended));
        assert!(!needs_pinned_review(&LessonStatus::Admitted));
    }

    #[test]
    fn precomputed_digests_compare_without_reserializing() {
        // The digests are arbitrary strings that do NOT match this runtime's
        // serialization of any value. Equality still decides, proving no
        // re-serialization happens on the compare path.
        assert!(content_matches("precomputed-a", "precomputed-a"));
        assert!(!content_matches("precomputed-a", "precomputed-b"));
        let guidance = "Prefer wider lookback windows.";
        assert!(content_matches(
            &lesson_digest(guidance),
            &lesson_digest(guidance)
        ));
        assert!(!content_matches(
            &lesson_digest(guidance),
            &lesson_digest("other words")
        ));
    }

    #[test]
    fn unknown_fields_rejected() {
        let raw = json!({
            "lesson_key": "k",
            "scope": {"scope_type": "global", "scope_key": {}},
            "guidance": "g",
            "guidance_digest": "d",
            "provenance": good_provenance(),
            "support": good_support(),
            "dissent": good_dissent(),
            "status": "admitted",
            "successor_lesson_key": serde_json::Value::Null,
            "canonical_lesson_key": serde_json::Value::Null,
            "expires_at": "2030-01-01T00:00:00Z",
            "backdoor": true
        });
        assert_eq!(parse_lesson(&raw), Err("invalid_lesson_schema".to_string()));
        let raw_scope = json!({
            "scope_type": "global",
            "scope_key": {},
            "sizing": "high"
        });
        assert!(serde_json::from_value::<LessonScope>(raw_scope).is_err());
    }

    #[test]
    fn deny_list_covers_gate_changes() {
        for key in [
            "authority",
            "lifecycle_state",
            "execution_environment",
            "execution_authority",
            "strategy_eligible",
            "paper_eligible",
            "trade_eligible",
            "paper",
            "live",
            "broker",
            "execution_edge_and_paper_trading",
            "recipe",
            "acceptance",
        ] {
            assert!(
                GATE_CHANGE_KEYS.contains(&key),
                "deny list must cover {key}"
            );
            assert!(
                gate_change_detected(&format!("Consider {key} semantics.")),
                "{key} guidance must be detected"
            );
        }
        assert_eq!(GATE_CHANGE_KEYS.len(), 13);
    }

    #[test]
    fn gate_keys_match_authority_keys_plus_boundary() {
        // B3: GATE_CHANGE_KEYS must not drift from AUTHORITY_KEYS; the first
        // eleven entries are AUTHORITY_KEYS verbatim, plus recipe/acceptance.
        for (i, key) in AUTHORITY_KEYS.iter().enumerate() {
            assert_eq!(
                GATE_CHANGE_KEYS[i], *key,
                "GATE_CHANGE_KEYS[{i}] must equal AUTHORITY_KEYS[{i}]"
            );
        }
        assert_eq!(GATE_CHANGE_KEYS[11], "recipe");
        assert_eq!(GATE_CHANGE_KEYS[12], "acceptance");
        assert_eq!(GATE_CHANGE_KEYS.len(), AUTHORITY_KEYS.len() + 2);
    }

    #[test]
    fn gate_change_detects_spaced_and_plural_forms() {
        // S3: spaced multi-word keys and plurals must be detected, mirroring
        // the SQL alternates (space/hyphen/underscore + recipes?/papers?/
        // brokers?/acceptances?).
        assert!(gate_change_detected(
            "Change execution environment to production."
        ));
        assert!(gate_change_detected("Use updated recipes for momentum."));
        assert!(gate_change_detected("Change execution-environment now."));
        assert!(gate_change_detected("Change execution_environment now."));
        assert!(gate_change_detected("Review lifecycle state transitions."));
        assert!(gate_change_detected("Check strategy eligible flags."));
        assert!(gate_change_detected("Use updated papers for review."));
        assert!(gate_change_detected("Hand orders to brokers daily."));
        assert!(gate_change_detected("Update acceptances checklist."));
        // Word-boundary safety stays: deliver/paperwork never trip.
        assert!(!gate_change_detected(
            "Lessons deliver methods guidance only."
        ));
        assert!(!gate_change_detected("Review the paperwork carefully."));
    }

    #[test]
    fn admissible_rejects_blank_guidance() {
        // B1: empty/blank guidance is inadmissible (mirrors SQL btrim<>'').
        let mut lesson = good_lesson("lesson-blank-guidance");
        lesson.guidance = String::new();
        assert_eq!(
            admissible(&lesson, None, TEST_NOW),
            Err("admission:guidance_required".to_string())
        );
        let mut lesson = good_lesson("lesson-blank-guidance");
        lesson.guidance = "   ".into();
        assert_eq!(
            admissible(&lesson, None, TEST_NOW),
            Err("admission:guidance_required".to_string())
        );
    }

    #[test]
    fn support_rejects_critic_session_and_model_reuse() {
        // S2 (Rust parity): supporter reusing the critic session/model with a
        // fresh assignment/run must fail (mirrors the SQL 22023 probe).
        let mut lesson = good_lesson("lesson-critic-reuse");
        lesson.support = vec![support(
            OUTSIDER,
            "run-fresh-critic-1",
            "sess-critic-1",
            "probe-model-z",
        )];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_session".into())
        );
        let mut lesson = good_lesson("lesson-critic-reuse");
        lesson.support = vec![support(
            OUTSIDER,
            "run-fresh-critic-2",
            "sess-fresh-critic-2",
            "probe-model-critic",
        )];
        assert_eq!(
            support_disjoint(&lesson),
            Err("support:shared_model".into())
        );
    }

    #[test]
    fn pinned_review_dedupes_repeated_keys() {
        // B4: duplicate pinned entries dedupe (HashSet like retrievable_keys).
        assert_eq!(
            pinned_review(&[
                ("lesson-b", LessonStatus::Suspended),
                ("lesson-b", LessonStatus::Suspended),
                ("lesson-c", LessonStatus::Contaminated),
                ("lesson-c", LessonStatus::Contaminated),
            ]),
            vec!["lesson-b".to_string(), "lesson-c".to_string()]
        );
    }

    #[test]
    fn unknown_fields_rejected_for_all_types() {
        // B7: LessonProvenance, LessonSupport, DissentEntry, LessonDissent
        // must all reject extra fields (deny_unknown_fields parity with SQL).
        let raw_prov = json!({
            "proposing_assignment_id": PROPOSER,
            "proposing_run_key": "run-p1",
            "critiquing_assignment_id": CRITIC,
            "critiquing_run_key": "run-c1",
            "provider_id": "p",
            "provider_session": "s",
            "model_id": "m",
            "critiquing_provider_session": "cs",
            "critiquing_model_id": "cm",
            "config_revision": 3,
            "recipe_version": "recipe-v2",
            "contract_runner": "momentum_v1",
            "source_artifact_ids": [SOURCE_ARTIFACT],
            "shared_dependencies": [],
            "backdoor": true
        });
        assert!(serde_json::from_value::<LessonProvenance>(raw_prov).is_err());
        let raw_sup = json!({
            "assignment_id": SUPPORTER_A,
            "run_key": "run-s1",
            "provider_session": "sess-a",
            "model_id": "probe-model-b",
            "backdoor": true
        });
        assert!(serde_json::from_value::<LessonSupport>(raw_sup).is_err());
        let raw_entry = json!({
            "assignment_id": CRITIC,
            "run_key": "run-c1",
            "note": "n",
            "backdoor": true
        });
        assert!(serde_json::from_value::<DissentEntry>(raw_entry).is_err());
        let raw_dissent = json!({
            "version": 1,
            "entries": [],
            "backdoor": true
        });
        assert!(serde_json::from_value::<LessonDissent>(raw_dissent).is_err());
    }

    #[test]
    fn cost_controls_untouched_by_this_module() {
        let source = include_str!("research_memory.rs");
        let capacity_guard = concat!("open", "router_capacity");
        let tier_guard = concat!("allow", "_paid");
        let policy_guard = concat!("spend", "ing");
        let router_guard = concat!("open", "router");
        let driver_guard = concat!("driver", "::");
        let http_guard = concat!("req", "west");
        let tokio_proc_guard = concat!("tokio", "::process");
        let std_proc_guard = concat!("std", "::process");
        assert!(
            !source.contains(capacity_guard),
            "memory admission must not reference provider cost admission"
        );
        assert!(
            !source.contains(tier_guard),
            "memory admission must not reference cost-bearing tiers"
        );
        assert!(
            !source.to_lowercase().contains(policy_guard),
            "memory admission must not touch cost policy"
        );
        assert!(
            !source.contains(router_guard),
            "memory admission must not reference provider routing"
        );
        assert!(
            !source.contains(driver_guard),
            "memory admission must not reference the agent driver"
        );
        assert!(
            !source.contains(http_guard),
            "memory admission must not perform outbound http"
        );
        assert!(
            !source.contains(tokio_proc_guard),
            "memory admission must not spawn processes via tokio"
        );
        assert!(
            !source.contains(std_proc_guard),
            "memory admission must not spawn processes"
        );
    }
}
