-- WU-38 Qualification report artifact: bundle a Strategy Version with its
-- data/contract/entitlement versions, walk-forward windows, bootstrap
-- seeds, cluster counts, EIS, net-of-cost LCBs vs cash and S&P (hard
-- where declared), and failures. Deterministic replay must match.
-- The report never grants Paper or Live authority.

CREATE FUNCTION qualification_report_digest(report_value jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT encode(
        digest(convert_to(
            'market-mate-qualification-report-v1|' || report_value::text,
            'UTF8'), 'sha256'),
        'hex');
$$;

CREATE FUNCTION qualification_sp500_is_hard(spec_value jsonb)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
SET search_path = pg_catalog, public
AS $$
    SELECT jsonb_typeof(spec_value->'sp500_comparator') = 'string'
       AND btrim(spec_value->>'sp500_comparator') = 'hard';
$$;

CREATE FUNCTION compute_research_qualification_report(
    strategy_version_id_value uuid,
    walk_forward_run_id_value uuid,
    eis_estimate_id_value uuid,
    cash_bootstrap_run_id_value uuid,
    sp500_bootstrap_run_id_value uuid,
    cost_application_id_value uuid,
    data_contract_version_id_value uuid,
    data_entitlement_version_id_value uuid
) RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public
AS $$
DECLARE
    version_row strategy_version%ROWTYPE;
    wf_row walk_forward_run%ROWTYPE;
    eis_row eis_estimate%ROWTYPE;
    cash_row block_bootstrap_run%ROWTYPE;
    sp_row block_bootstrap_run%ROWTYPE;
    cost_row research_cost_application%ROWTYPE;
    schedule_row research_cost_schedule%ROWTYPE;
    contract_row data_contract_version%ROWTYPE;
    entitlement_row data_entitlement_version%ROWTYPE;
    eis_replay jsonb;
    cash_replay jsonb;
    sp_replay jsonb;
    cost_replay jsonb;
    failures jsonb := '[]'::jsonb;
    status_text text;
    lcb_cash bigint;
    lcb_sp bigint;
    eis_floor bigint;
    cluster_count bigint;
    seed_value bigint;
    report jsonb;
BEGIN
    IF strategy_version_id_value IS NULL
       OR walk_forward_run_id_value IS NULL
       OR eis_estimate_id_value IS NULL
       OR cash_bootstrap_run_id_value IS NULL
       OR cost_application_id_value IS NULL
       OR data_contract_version_id_value IS NULL
       OR data_entitlement_version_id_value IS NULL THEN
        RAISE EXCEPTION 'qualification report arguments are incomplete'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO version_row FROM strategy_version
    WHERE strategy_version_id = strategy_version_id_value;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'strategy version % is not registered',
            strategy_version_id_value USING ERRCODE = '22023';
    END IF;
    IF version_row.lifecycle_state IS DISTINCT FROM 'frozen'
       OR version_row.record_environment IS DISTINCT FROM 'local_research'
       OR lower(btrim(version_row.engine_binding->>'engine_kind'))
            IS DISTINCT FROM 'deterministic_dsl' THEN
        RAISE EXCEPTION
            'qualification report can bind only a frozen deterministic DSL Strategy Version'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO wf_row FROM walk_forward_run
    WHERE run_id = walk_forward_run_id_value;
    IF NOT FOUND OR wf_row.strategy_version_id IS DISTINCT FROM strategy_version_id_value
       OR wf_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'qualification report walk-forward run is not admissible'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO eis_row FROM eis_estimate
    WHERE estimate_id = eis_estimate_id_value;
    IF NOT FOUND OR eis_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'qualification report EIS estimate is not admissible'
            USING ERRCODE = '22023';
    END IF;
    eis_replay := compute_eis_estimate(eis_row.observations);
    IF eis_result_digest(eis_replay - 'result_digest') IS DISTINCT FROM eis_row.result_digest THEN
        RAISE EXCEPTION 'qualification report EIS replay is not deterministic'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO cash_row FROM block_bootstrap_run
    WHERE run_id = cash_bootstrap_run_id_value;
    IF NOT FOUND OR cash_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'qualification report cash bootstrap run is not admissible'
            USING ERRCODE = '22023';
    END IF;
    IF cash_row.strategy_version_id IS NOT NULL
       AND cash_row.strategy_version_id IS DISTINCT FROM strategy_version_id_value THEN
        RAISE EXCEPTION 'qualification report cash bootstrap run is not admissible'
            USING ERRCODE = '22023';
    END IF;
    cash_replay := compute_block_bootstrap_lcb(cash_row.pairs, cash_row.construction);
    IF bootstrap_result_digest(cash_replay - 'result_digest')
          IS DISTINCT FROM cash_row.result_digest THEN
        RAISE EXCEPTION 'qualification report cash LCB replay is not deterministic'
            USING ERRCODE = '22023';
    END IF;

    IF qualification_sp500_is_hard(version_row.spec) THEN
        IF sp500_bootstrap_run_id_value IS NULL THEN
            RAISE EXCEPTION 'qualification report arguments are incomplete'
                USING ERRCODE = '22023';
        END IF;
        SELECT * INTO sp_row FROM block_bootstrap_run
        WHERE run_id = sp500_bootstrap_run_id_value;
        IF NOT FOUND OR sp_row.record_environment IS DISTINCT FROM 'local_research' THEN
            RAISE EXCEPTION 'qualification report S&P bootstrap run is not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF sp_row.strategy_version_id IS NOT NULL
           AND sp_row.strategy_version_id IS DISTINCT FROM strategy_version_id_value THEN
            RAISE EXCEPTION 'qualification report S&P bootstrap run is not admissible'
                USING ERRCODE = '22023';
        END IF;
        IF sp_row.run_id = cash_row.run_id THEN
            RAISE EXCEPTION 'qualification report S&P bootstrap run is not admissible'
                USING ERRCODE = '22023';
        END IF;
        sp_replay := compute_block_bootstrap_lcb(sp_row.pairs, sp_row.construction);
        IF bootstrap_result_digest(sp_replay - 'result_digest')
              IS DISTINCT FROM sp_row.result_digest THEN
            RAISE EXCEPTION 'qualification report S&P LCB replay is not deterministic'
                USING ERRCODE = '22023';
        END IF;
        lcb_sp := (sp_row.result->>'lcb_excess_bps')::bigint;
    ELSIF sp500_bootstrap_run_id_value IS NOT NULL THEN
        RAISE EXCEPTION 'qualification report S&P bootstrap run is not admissible'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO cost_row FROM research_cost_application
    WHERE application_id = cost_application_id_value;
    IF NOT FOUND OR cost_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'qualification report cost application is not admissible'
            USING ERRCODE = '22023';
    END IF;
    IF cost_row.strategy_version_id IS NOT NULL
       AND cost_row.strategy_version_id IS DISTINCT FROM strategy_version_id_value THEN
        RAISE EXCEPTION 'qualification report cost application is not admissible'
            USING ERRCODE = '22023';
    END IF;
    SELECT * INTO schedule_row FROM research_cost_schedule
    WHERE schedule_id = cost_row.schedule_id;
    cost_replay := apply_research_costs(cost_row.trades, schedule_row.spec);
    IF research_cost_result_digest(cost_replay - 'result_digest')
          IS DISTINCT FROM cost_row.result_digest THEN
        RAISE EXCEPTION 'qualification report cost replay is not deterministic'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO contract_row FROM data_contract_version
    WHERE contract_version_id = data_contract_version_id_value;
    IF NOT FOUND OR contract_row.record_environment IS DISTINCT FROM 'local_research' THEN
        RAISE EXCEPTION 'qualification report data contract version is not admissible'
            USING ERRCODE = '22023';
    END IF;

    SELECT * INTO entitlement_row FROM data_entitlement_version
    WHERE entitlement_version_id = data_entitlement_version_id_value;
    IF NOT FOUND
       OR entitlement_row.record_environment IS DISTINCT FROM 'local_research'
       OR entitlement_row.certification_state IS DISTINCT FROM 'certified'
       OR NOT ('local_research' = ANY (entitlement_row.authorized_purposes)) THEN
        RAISE EXCEPTION 'qualification report data entitlement version is not admissible'
            USING ERRCODE = '22023';
    END IF;

    eis_floor := (eis_row.result->>'floor')::bigint;
    cluster_count := (eis_row.result->>'cluster_count')::bigint;
    lcb_cash := (cash_row.result->>'lcb_excess_bps')::bigint;
    seed_value := strategy_sandbox_integer(cash_row.construction->'seed');

    IF eis_floor < 30 THEN
        failures := failures || jsonb_build_array('eis_floor_below_30');
    END IF;
    IF lcb_cash < 0 THEN
        failures := failures || jsonb_build_array('lcb_vs_cash_negative');
    END IF;
    IF qualification_sp500_is_hard(version_row.spec) AND lcb_sp < 0 THEN
        failures := failures || jsonb_build_array('lcb_vs_sp500_negative');
    END IF;
    IF jsonb_array_length(failures) = 0 THEN
        status_text := 'passed';
    ELSE
        status_text := 'failed';
    END IF;

    report := jsonb_strip_nulls(
        jsonb_build_object(
            'engine', 'research_qualification_report_v1',
            'status', status_text,
            'failure_reasons', failures,
            'strategy_version_id', strategy_version_id_value,
            'strategy_version_digest', version_row.version_digest,
            'lifecycle_state', version_row.lifecycle_state,
            'data_contract_version_id', data_contract_version_id_value,
            'data_entitlement_version_id', data_entitlement_version_id_value,
            'source_registry_version_id', contract_row.source_registry_version_id,
            'windows', wf_row.window_plan,
            'window_plan_digest', wf_row.window_plan_digest,
            'walk_forward_manifest_digest', wf_row.manifest_digest,
            'cluster_count', cluster_count,
            'eis', (eis_row.result->>'eis')::bigint,
            'eis_floor', eis_floor,
            'bootstrap_seed', seed_value,
            'bootstrap_construction_digest', cash_row.construction_digest,
            'lcb_vs_cash_bps', lcb_cash,
            'lcb_vs_sp500_bps', lcb_sp,
            'cost_schedule_digest', schedule_row.schedule_digest,
            'gross_mean_return_bps',
                (cost_row.result->>'gross_mean_return_bps')::bigint,
            'net_mean_return_bps',
                (cost_row.result->>'mean_return_bps')::bigint,
            'replayed', true
        )
    );
    RETURN report || jsonb_build_object(
        'result_digest', qualification_report_digest(report));
END;
$$;

CREATE TABLE research_qualification_report (
    report_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    strategy_version_id uuid NOT NULL
        REFERENCES strategy_version(strategy_version_id),
    walk_forward_run_id uuid NOT NULL
        REFERENCES walk_forward_run(run_id),
    eis_estimate_id uuid NOT NULL
        REFERENCES eis_estimate(estimate_id),
    cash_bootstrap_run_id uuid NOT NULL
        REFERENCES block_bootstrap_run(run_id),
    sp500_bootstrap_run_id uuid
        REFERENCES block_bootstrap_run(run_id),
    cost_application_id uuid NOT NULL
        REFERENCES research_cost_application(application_id),
    data_contract_version_id uuid NOT NULL
        REFERENCES data_contract_version(contract_version_id),
    data_entitlement_version_id uuid NOT NULL
        REFERENCES data_entitlement_version(entitlement_version_id),
    report jsonb NOT NULL CHECK (jsonb_typeof(report) = 'object'),
    result_digest text NOT NULL CHECK (result_digest ~ '^[0-9a-f]{64}$'),
    source_lineage jsonb NOT NULL,
    receipt_time timestamptz NOT NULL,
    record_environment record_environment NOT NULL,
    CHECK (source_lineage_is_valid(source_lineage)),
    CHECK (result_digest = qualification_report_digest(report - 'result_digest')),
    CHECK (report->>'lifecycle_state' = 'frozen'),
    CHECK (report->>'status' IN ('passed', 'failed')),
    CHECK (record_environment = 'local_research'),
    UNIQUE (strategy_version_id)
);

SELECT register_evidence_table('research_qualification_report');

CREATE FUNCTION guard_qualification_report_write() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF TG_OP <> 'INSERT' THEN
        RAISE EXCEPTION 'research_qualification_report is append-only; % is forbidden', TG_OP
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_qualification_report_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON research_qualification_report
    FOR EACH STATEMENT EXECUTE FUNCTION guard_qualification_report_write();

CREATE FUNCTION guard_qualification_report_insert() RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public
AS $$
BEGIN
    IF coalesce(current_setting('market_mate.qualification_write', true), '')
          <> 'on' THEN
        RAISE EXCEPTION
            'research_qualification_report writes must go through record_research_qualification_report'
            USING ERRCODE = '55000';
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER research_qualification_report_insert_guard
    BEFORE INSERT ON research_qualification_report
    FOR EACH ROW EXECUTE FUNCTION guard_qualification_report_insert();

CREATE FUNCTION record_research_qualification_report(
    strategy_version_id_value uuid,
    walk_forward_run_id_value uuid,
    eis_estimate_id_value uuid,
    cash_bootstrap_run_id_value uuid,
    sp500_bootstrap_run_id_value uuid,
    cost_application_id_value uuid,
    data_contract_version_id_value uuid,
    data_entitlement_version_id_value uuid,
    source_lineage_value jsonb
) RETURNS research_qualification_report
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
    computed jsonb;
    stored_report jsonb;
    digest_value text;
    existing research_qualification_report%ROWTYPE;
    created research_qualification_report%ROWTYPE;
BEGIN
    IF NOT source_lineage_is_valid(source_lineage_value) THEN
        RAISE EXCEPTION 'qualification report arguments are invalid'
            USING ERRCODE = '22023';
    END IF;

    PERFORM pg_advisory_xact_lock(
        hashtextextended(strategy_version_id_value::text, 40023));

    computed := compute_research_qualification_report(
        strategy_version_id_value, walk_forward_run_id_value,
        eis_estimate_id_value, cash_bootstrap_run_id_value,
        sp500_bootstrap_run_id_value, cost_application_id_value,
        data_contract_version_id_value, data_entitlement_version_id_value);
    stored_report := computed - 'result_digest';
    digest_value := qualification_report_digest(stored_report);

    SELECT * INTO existing
    FROM research_qualification_report
    WHERE strategy_version_id = strategy_version_id_value;
    IF FOUND THEN
        IF existing.result_digest IS DISTINCT FROM digest_value
           OR existing.walk_forward_run_id IS DISTINCT FROM walk_forward_run_id_value
           OR existing.eis_estimate_id IS DISTINCT FROM eis_estimate_id_value
           OR existing.cash_bootstrap_run_id IS DISTINCT FROM cash_bootstrap_run_id_value
           OR existing.sp500_bootstrap_run_id IS DISTINCT FROM sp500_bootstrap_run_id_value
           OR existing.cost_application_id IS DISTINCT FROM cost_application_id_value THEN
            RAISE EXCEPTION
                'qualification report cannot change after results exist'
                USING ERRCODE = '22023';
        END IF;
        RETURN existing;
    END IF;

    PERFORM set_config('market_mate.qualification_write', 'on', true);
    BEGIN
        INSERT INTO research_qualification_report (
            strategy_version_id, walk_forward_run_id, eis_estimate_id,
            cash_bootstrap_run_id, sp500_bootstrap_run_id, cost_application_id,
            data_contract_version_id, data_entitlement_version_id,
            report, result_digest, source_lineage, receipt_time, record_environment
        ) VALUES (
            strategy_version_id_value, walk_forward_run_id_value, eis_estimate_id_value,
            cash_bootstrap_run_id_value, sp500_bootstrap_run_id_value,
            cost_application_id_value, data_contract_version_id_value,
            data_entitlement_version_id_value, stored_report, digest_value,
            source_lineage_value, clock_timestamp(), 'local_research'
        )
        RETURNING * INTO created;
    EXCEPTION
        WHEN OTHERS THEN
            PERFORM set_config('market_mate.qualification_write', 'off', true);
            RAISE;
    END;
    PERFORM set_config('market_mate.qualification_write', 'off', true);

    PERFORM append_audit_event(
        'qualification:' || created.report_id::text,
        'research.qualification_report_recorded',
        now(),
        jsonb_build_object(
            'report_id', created.report_id,
            'strategy_version_id', strategy_version_id_value,
            'result_digest', digest_value,
            'status', stored_report->>'status',
            'eis_floor', stored_report->>'eis_floor',
            'lcb_vs_cash_bps', stored_report->>'lcb_vs_cash_bps'
        ),
        source_lineage_value,
        now(),
        'local_research'
    );

    RETURN created;
END;
$$;

REVOKE ALL ON FUNCTION record_research_qualification_report(
    uuid, uuid, uuid, uuid, uuid, uuid, uuid, uuid, jsonb) FROM PUBLIC;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON research_qualification_report FROM PUBLIC;

SELECT assert_all_evidence_table_conventions();
