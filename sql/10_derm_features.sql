-- =============================================================================
-- Forus DS Take-Home | Part 2 feature layer: dermatology provider segmentation
-- Source:  tandem-interview.takehome_wu_timothy.prescriptions  (read-only)
-- Target:  {target}  (set in notebook)
--
-- Objects
--   derm_rx_clean               one row per prescription, with derived classes/flags
--   derm_prescriber_features    one row per prescriber: operational features for clustering
--
-- Source observations (checked 2026-09-27; see part2_clustering.ipynb §2)
--   * 65,513 prescriptions, all specialty = 'dermatology'; received 2025-01-01 to 2025-07-30.
--     Monthly volume roughly doubles over the window (6.4K Jan -> 12.6K Jul), so volume is
--     normalized per active month rather than summed.
--   * 488 prescribers, 102 practices, 435 offices. Every prescriber has >= 35 scripts
--     (looks like a pre-applied volume floor). 18 prescribers appear in >1 practice.
--   * Types differ from the data dictionary: hash_prescriber_npi and patient_id are FLOAT64
--     (dictionary says INTEGER/STRING), patient_age is INT64. Large hashed IDs stored as
--     FLOAT64 lose precision; distinct counts are still 488 prescribers, so IDs are used
--     as-is, cast to STRING.
--   * prior_auth_required is TRUE for 95% of scripts (71 NULL), so it barely varies by
--     prescriber; kept for profiling, not used as a clustering feature.
--   * Insurance type is NULL or 'UNKNOWN' on 72% of scripts and pbm_guess is NULL on 27%:
--     treated as an operational signal (missing benefits info = more chasing), not dropped.
--   * brand_name has 238 values including 'Generic' (29%) and one NULL-brand group (71 rows).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS `{target}`
OPTIONS (location = 'US');

-- -----------------------------------------------------------------------------
-- derm_rx_clean
--   drug_class:
--     advanced_systemic  biologics + oral immunomodulators (JAK/TYK2/PDE4). These drive the
--                        heaviest prior-auth / appeal / bridge work. Superset of the Part 1
--                        biologic list, since derm prescribing has moved to newer agents
--                        (Nemluvio, Ebglyss, Bimzelx, Sotyktu, ...).
--     generic            brand_name = 'Generic'
--     branded_other      everything else (mostly branded topicals: Zoryve, Opzelura, Vtama)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{target}.derm_rx_clean` AS
SELECT
  prescription_id,
  CAST(hash_prescriber_npi AS STRING)                         AS prescriber_id,
  practice_id,
  office_id,
  CAST(patient_id AS STRING)                                  AS patient_id,
  rx_received_on,
  DATE_TRUNC(DATE(rx_received_on), MONTH)                     AS rx_month,
  TRIM(brand_name)                                            AS brand_name,
  drug_description,
  CASE
    WHEN brand_name = 'Generic' THEN 'generic'
    WHEN REGEXP_CONTAINS(LOWER(TRIM(brand_name)),
      r'^(dupixent|skyrizi|tremfya|cosentyx|taltz|nemluvio|bimzelx|rinvoq|humira|ebglyss|adbry|sotyktu|stelara|otezla|cibinqo|olumiant|litfulo|xolair|hyrimoz|amjevita|enbrel|cimzia|cyltezo|hadlima|ilumya|simlandi|siliq|idacio|yusimry|yuflyma|yesintek|wezlana|xeljanz|spevigo|tezspire|steqeyma|otulfi|selarsdi|leqselvi|nucala)')
      THEN 'advanced_systemic'
    ELSE 'branded_other'
  END                                                         AS drug_class,
  prior_auth_required,
  CASE
    WHEN pa_ins_type = 'COMMERCIAL'           THEN 'commercial'
    WHEN pa_ins_type = 'GOVERNMENT_MEDICARE'  THEN 'medicare'
    WHEN pa_ins_type = 'GOVERNMENT_MEDICAID'  THEN 'medicaid'
    WHEN pa_ins_type = 'GOVERNMENT_OTHER'     THEN 'government_other'
    ELSE 'unknown'                                             -- NULL or 'UNKNOWN'
  END                                                         AS ins_group,
  pbm_guess,
  most_recent_transfer_pharmacy,
  bridge_status,
  bridge_status = 'enrolled'                                  AS is_bridge_enrolled,
  patient_gender,
  patient_age,
  quantity,
  refills,
  prescriber_address_state
FROM `tandem-interview.takehome_wu_timothy.prescriptions`;

-- -----------------------------------------------------------------------------
-- derm_prescriber_features
--   Grain: one row per prescriber (488).
--   Primary practice = practice with the most of the prescriber's scripts.
--   Columns prefixed f_ are the clustering inputs (see forus_segments.FEATURES); the rest
--   are for profiling and ops sizing.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{target}.derm_prescriber_features` AS
WITH window_end AS (
  SELECT MAX(rx_month) AS last_month FROM `{target}.derm_rx_clean`
),
primary_practice AS (
  SELECT prescriber_id, practice_id FROM (
    SELECT prescriber_id, practice_id,
           ROW_NUMBER() OVER (PARTITION BY prescriber_id ORDER BY COUNT(*) DESC, practice_id) AS rn
    FROM `{target}.derm_rx_clean`
    GROUP BY 1, 2)
  WHERE rn = 1
),
practice_size AS (
  SELECT practice_id,
         COUNT(DISTINCT prescriber_id) AS practice_prescribers,
         COUNT(DISTINCT office_id)     AS practice_offices
  FROM `{target}.derm_rx_clean`
  GROUP BY 1
),
pharmacy_share AS (   -- concentration of the prescriber's scripts at their #1 pharmacy
  SELECT prescriber_id, MAX(n) / SUM(n) AS top_pharmacy_share, COUNT(*) AS n_pharmacies
  FROM (SELECT prescriber_id, most_recent_transfer_pharmacy, COUNT(*) AS n
        FROM `{target}.derm_rx_clean`
        WHERE most_recent_transfer_pharmacy IS NOT NULL
        GROUP BY 1, 2)
  GROUP BY 1
),
base AS (
  SELECT
    r.prescriber_id,
    COUNT(*)                                                    AS n_rx,
    COUNT(DISTINCT r.patient_id)                                AS n_patients,
    COUNT(DISTINCT r.brand_name)                                AS n_brands,
    COUNT(DISTINCT r.office_id)                                 AS n_offices_used,
    COUNT(DISTINCT r.practice_id)                               AS n_practices,
    ANY_VALUE(r.prescriber_address_state)                       AS state,
    MIN(r.rx_month)                                             AS first_month,
    DATE_DIFF(ANY_VALUE(w.last_month), MIN(r.rx_month), MONTH) + 1 AS months_active,
    COUNTIF(r.drug_class = 'advanced_systemic') / COUNT(*)      AS advanced_share,
    COUNTIF(r.drug_class = 'generic') / COUNT(*)                AS generic_share,
    COUNTIF(r.drug_class = 'branded_other') / COUNT(*)          AS branded_other_share,
    AVG(IF(r.prior_auth_required, 1, 0))                        AS pa_rate,
    COUNTIF(r.is_bridge_enrolled) / COUNT(*)                    AS bridge_rate,
    COUNTIF(r.ins_group = 'commercial') / COUNT(*)              AS commercial_share,
    COUNTIF(r.ins_group IN ('medicare', 'medicaid', 'government_other')) / COUNT(*) AS government_share,
    COUNTIF(r.ins_group = 'unknown') / COUNT(*)                 AS unknown_ins_share,
    COUNTIF(r.pbm_guess IS NULL) / COUNT(*)                     AS unknown_pbm_share,
    COUNTIF(r.patient_age < 18) / COUNT(*)                      AS peds_share,
    COUNTIF(r.patient_age >= 65) / COUNT(*)                     AS senior_share,
    AVG(r.refills)                                              AS avg_refills
  FROM `{target}.derm_rx_clean` r
  CROSS JOIN window_end w
  GROUP BY r.prescriber_id
)
SELECT
  b.*,
  b.n_rx / b.months_active                                     AS rx_per_month,
  pp.practice_id                                               AS primary_practice_id,
  ps.practice_prescribers,
  ps.practice_offices,
  COALESCE(ph.top_pharmacy_share, 1)                           AS top_pharmacy_share,
  COALESCE(ph.n_pharmacies, 0)                                 AS n_pharmacies,
  -- clustering inputs (log for right-skewed counts)
  LN(b.n_rx / b.months_active)                                 AS f_log_rx_per_month,
  b.advanced_share                                             AS f_advanced_share,
  b.generic_share                                              AS f_generic_share,
  b.bridge_rate                                                AS f_bridge_rate,
  b.commercial_share                                           AS f_commercial_share,
  b.government_share                                           AS f_government_share,
  b.unknown_ins_share                                          AS f_unknown_ins_share,
  b.peds_share                                                 AS f_peds_share,
  LN(b.n_brands)                                               AS f_log_brands,
  COALESCE(ph.top_pharmacy_share, 1)                           AS f_top_pharmacy_share,
  LN(ps.practice_prescribers)                                  AS f_log_practice_prescribers
FROM base b
JOIN primary_practice pp USING (prescriber_id)
JOIN practice_size ps ON ps.practice_id = pp.practice_id
LEFT JOIN pharmacy_share ph USING (prescriber_id);

-- -----------------------------------------------------------------------------
-- Validation: one row per prescriber; scripts reconcile to source
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `tandem-interview.takehome_wu_timothy.prescriptions`)                 AS source_rx,
  (SELECT COUNT(*) FROM `{target}.derm_rx_clean`)                                             AS clean_rx,
  (SELECT COUNT(DISTINCT CAST(hash_prescriber_npi AS STRING))
     FROM `tandem-interview.takehome_wu_timothy.prescriptions`)                               AS source_prescribers,
  COUNT(*)                                                                                     AS feature_rows,
  SUM(n_rx)                                                                                    AS feature_rx
FROM `{target}.derm_prescriber_features`;
