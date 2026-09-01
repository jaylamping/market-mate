import type {
  Cost,
  CostModel,
  NotRecorded,
  Qualification,
  Stage1SurfacesModel,
} from "../Stage1Surfaces";

type JsonObject = Record<string, unknown>;

function object(value: unknown, name: string): JsonObject {
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error(`${name} must be an object`);
  }
  return { ...value };
}

function string(value: unknown, name: string): string {
  if (typeof value !== "string") throw new Error(`${name} must be a string`);
  return value;
}

function number(value: unknown, name: string): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    throw new Error(`${name} must be a finite number`);
  }
  return value;
}

function boolean(value: unknown, name: string): boolean {
  if (typeof value !== "boolean") throw new Error(`${name} must be a boolean`);
  return value;
}

function nullableNumber(value: unknown, name: string): number | null {
  return value === null ? null : number(value, name);
}

function nullableBoolean(value: unknown, name: string): boolean | null {
  return value === null ? null : boolean(value, name);
}

function checkpointState(
  value: unknown,
): Stage1SurfacesModel["checkpoint_pack"]["state"] {
  if (
    value === "CHECKPOINT UNVERIFIED" ||
    value === "CHECKPOINT PENDING" ||
    value === "CHECKPOINT VERIFIED"
  ) {
    return value;
  }
  throw new Error("checkpoint_pack.state is invalid");
}

function notRecorded(value: JsonObject, name: string): NotRecorded {
  if (value.recorded !== false || value.state !== "not_recorded") {
    throw new Error(`${name} must be explicitly not_recorded`);
  }
  return { recorded: false, state: "not_recorded", detail: string(value.detail, `${name}.detail`) };
}

function qualification(value: unknown): Qualification {
  const item = object(value, "qualification");
  if (item.recorded === false) return notRecorded(item, "qualification");
  const status = string(item.status, "qualification.status");
  if (status !== "passed" && status !== "failed") {
    throw new Error("qualification.status must be passed or failed");
  }
  const reasons = item.failure_reasons;
  if (!Array.isArray(reasons)) {
    throw new Error("qualification.failure_reasons must be strings");
  }
  const failureReasons = reasons.map((reason, index) =>
    string(reason, `qualification.failure_reasons[${index}]`),
  );
  return {
    recorded: true,
    status,
    strategy_version_digest: string(item.strategy_version_digest, "qualification.strategy_version_digest"),
    window_count: number(item.window_count, "qualification.window_count"),
    eis: number(item.eis, "qualification.eis"),
    eis_floor: number(item.eis_floor, "qualification.eis_floor"),
    meets_eis_floor: boolean(item.meets_eis_floor, "qualification.meets_eis_floor"),
    lcb_vs_cash_bps: number(item.lcb_vs_cash_bps, "qualification.lcb_vs_cash_bps"),
    lcb_vs_sp500_bps: nullableNumber(item.lcb_vs_sp500_bps, "qualification.lcb_vs_sp500_bps"),
    sp500_comparator_required: boolean(item.sp500_comparator_required, "qualification.sp500_comparator_required"),
    meets_cash_floor: boolean(item.meets_cash_floor, "qualification.meets_cash_floor"),
    meets_sp500_floor: nullableBoolean(item.meets_sp500_floor, "qualification.meets_sp500_floor"),
    net_mean_return_bps: number(item.net_mean_return_bps, "qualification.net_mean_return_bps"),
    failure_reasons: failureReasons,
    result_digest: string(item.result_digest, "qualification.result_digest"),
    as_of: string(item.as_of, "qualification.as_of"),
    receipt_time: string(item.receipt_time, "qualification.receipt_time"),
  };
}

function cost(value: unknown): Cost {
  const item = object(value, "cost");
  if (item.recorded === false) return notRecorded(item, "cost");
  const register = object(item.register, "cost.register");
  return {
    recorded: true,
    envelope_key: string(item.envelope_key, "cost.envelope_key"),
    register: {
      entries: number(register.entries, "cost.register.entries"),
      monthly_spent_cents: string(register.monthly_spent_cents, "cost.register.monthly_spent_cents"),
      year_one_spent_cents: string(register.year_one_spent_cents, "cost.register.year_one_spent_cents"),
      monthly_state: string(register.monthly_state, "cost.register.monthly_state"),
      year_one_state: string(register.year_one_state, "cost.register.year_one_state"),
      monthly_hard_ceiling_cents: string(register.monthly_hard_ceiling_cents, "cost.register.monthly_hard_ceiling_cents"),
      year_one_hard_ceiling_cents: string(register.year_one_hard_ceiling_cents, "cost.register.year_one_hard_ceiling_cents"),
    },
    as_of: string(item.as_of, "cost.as_of"),
  };
}

function costModel(value: unknown): CostModel {
  const item = object(value, "cost_model");
  if (item.recorded === false) return notRecorded(item, "cost_model");
  return {
    recorded: true,
    model_key: string(item.model_key, "cost_model.model_key"),
    vendor_set_key: string(item.vendor_set_key, "cost_model.vendor_set_key"),
    within_caps: boolean(item.within_caps, "cost_model.within_caps"),
    required_decision: item.required_decision === null ? null : string(item.required_decision, "cost_model.required_decision"),
    monthly_projected_cents: number(item.monthly_projected_cents, "cost_model.monthly_projected_cents"),
    year_one_projected_cents: number(item.year_one_projected_cents, "cost_model.year_one_projected_cents"),
    monthly_escalation: string(item.monthly_escalation, "cost_model.monthly_escalation"),
    year_one_escalation: string(item.year_one_escalation, "cost_model.year_one_escalation"),
    monthly_hard_ceiling_cents: number(item.monthly_hard_ceiling_cents, "cost_model.monthly_hard_ceiling_cents"),
    year_one_hard_ceiling_cents: number(item.year_one_hard_ceiling_cents, "cost_model.year_one_hard_ceiling_cents"),
    as_of: string(item.as_of, "cost_model.as_of"),
  };
}

export function parseStage1Surfaces(value: unknown): Stage1SurfacesModel {
  const root = object(value, "stage1_surfaces");
  const stage = object(root.stage, "stage");
  const snapshots = object(root.snapshots, "snapshots");
  const manifests = snapshots.latest_manifests;
  const checkpoint = object(root.checkpoint_pack, "checkpoint_pack");
  if (root.environment !== "local_research" || root.order_authority !== false) {
    throw new Error("stage-1 surfaces must be local_research with zero authority");
  }
  if (stage.stage !== 1 || stage.display_only !== true || stage.order_authority !== "none") {
    throw new Error("stage badge must be stage 1 and display-only");
  }
  if (!Array.isArray(manifests)) throw new Error("snapshots.latest_manifests must be an array");
  const parsedCheckpointState = checkpointState(checkpoint.state);

  return {
    environment: "local_research",
    order_authority: false,
    checkpoints_verified: boolean(root.checkpoints_verified, "checkpoints_verified"),
    stage: {
      badge: string(stage.badge, "stage.badge"),
      stage: 1,
      name: string(stage.name, "stage.name"),
      display_only: true,
      order_authority: "none",
    },
    qualification: qualification(root.qualification),
    cost: cost(root.cost),
    cost_model: costModel(root.cost_model),
    snapshots: {
      recorded: boolean(snapshots.recorded, "snapshots.recorded"),
      manifest_count: number(snapshots.manifest_count, "snapshots.manifest_count"),
      snapshot_count: number(snapshots.snapshot_count, "snapshots.snapshot_count"),
      latest_manifests: manifests.map((entry, index) => {
        const item = object(entry, `snapshots.latest_manifests[${index}]`);
        return {
          cycle_key: string(item.cycle_key, "manifest.cycle_key"),
          cycle_kind: string(item.cycle_kind, "manifest.cycle_kind"),
          cycle_as_of: string(item.cycle_as_of, "manifest.cycle_as_of"),
          expected_snapshot_count: number(item.expected_snapshot_count, "manifest.expected_snapshot_count"),
          completed_snapshot_count: number(item.completed_snapshot_count, "manifest.completed_snapshot_count"),
          completion_state: string(item.completion_state, "manifest.completion_state"),
          evidence_state: string(item.evidence_state, "manifest.evidence_state"),
        };
      }),
    },
    checkpoint_pack: {
      recorded: boolean(checkpoint.recorded, "checkpoint_pack.recorded"),
      checkpoint_count: number(checkpoint.checkpoint_count, "checkpoint_pack.checkpoint_count"),
      verified_position: nullableNumber(checkpoint.verified_position, "checkpoint_pack.verified_position"),
      head_position: nullableNumber(checkpoint.head_position, "checkpoint_pack.head_position"),
      pending_events: nullableNumber(checkpoint.pending_events, "checkpoint_pack.pending_events"),
      state: parsedCheckpointState,
    },
  };
}
