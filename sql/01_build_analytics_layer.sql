-- =============================================================================
-- Forus DS Take-Home | Part 1 analytics layer
-- Source:  tandem-interview.takehome_wu_timothy  (read-only)
-- Target:  {target}  (set in notebook, e.g. my-project.forus_analytics)
--
-- Objects
--   biologic_ref       drug reference for the $200 / 30-min tier (edit to change scenarios)
--   claims_enriched    claims_fact + specialty + institution + drug tier, same grain as claims_fact
--
-- Data caveats handled here (see data checks in write-up)
--   1. npi_affiliations joined on (hashed_npi, affiliated_id) PAIR. Joining on hashed_npi
--      alone fans out the 12.4K NPIs with 2 affiliations and inflates patients by
--      +8.7% Rheum / +7.7% GI / +0.8% Derm (non-uniform -> biases specialty ranking).
--   2. 12.6% of claims have NULL affiliated_id (16.8% in Derm). Kept and labeled
--      'Unaffiliated' rather than dropped by an inner join.
--   3. 7,919 NPIs missing from provider_specialty (5% of patients). Kept as 'Unknown'.
--   4. affiliated_firm_type has case/whitespace variants ('Hospital', 'Hospital ',
--      'hospital'); normalized with INITCAP(TRIM()) -> 38 values collapse to 14.
--   5. affiliated_firm_lookup has one junk row (NULL id, npi_count 577,804); excluded.
--   6. Data dictionary says affiliated_region; actual column is affiliation_region.
--   7. 4% of rows have 0 patients; kept (harmless in sums), flagged via has_patients
--      so prescriber counts can exclude them.
--   8. Drug names: lowercase with device/formulation suffixes and biosimilar brands
--      (e.g. 'actemra actpen', 'inflectra', 'adalimumab-adbm'); matched by regex on
--      brand|generic|biosimilar aliases.
--
-- Unit caveat: npi_drug_patients = patient-drug PAIRS. Not scripts (revenue model is
-- per script -> needs a scripts-per-patient assumption) and not unique patients
-- (a patient on 2 drugs is counted twice).
-- =============================================================================

CREATE SCHEMA IF NOT EXISTS `{target}`
OPTIONS (location = 'US');

-- -----------------------------------------------------------------------------
-- biologic_ref
--   tier = 'primer'   : Forus primer list + biosimilars of those molecules (BASE CASE)
--   tier = 'expanded' : similar advanced therapies not on the primer (SENSITIVITY)
--   is_true_biologic  : FALSE for small molecules (JAK / S1P / TYK2) that the primer
--                       includes "because they're used similarly"
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{target}.biologic_ref` AS
SELECT brand, aliases, tier, is_true_biologic,
  CONCAT(r'\b(', brand, '|', aliases, r')\b') AS match_pattern
FROM UNNEST([
  STRUCT('humira' AS brand, 'adalimumab|amjevita|hadlima|cyltezo|yusimry|hyrimoz|idacio|yuflyma|hulio|abrilada|simlandi' AS aliases, 'primer' AS tier, TRUE AS is_true_biologic),
  ('stelara',  'ustekinumab|wezlana|selarsdi|pyzchiva|otulfi|imuldosa|yesintek|steqeyma', 'primer', TRUE),
  ('tremfya',  'guselkumab',   'primer', TRUE),
  ('cosentyx', 'secukinumab',  'primer', TRUE),
  ('taltz',    'ixekizumab',   'primer', TRUE),
  ('dupixent', 'dupilumab',    'primer', TRUE),
  ('skyrizi',  'risankizumab', 'primer', TRUE),
  ('siliq',    'brodalumab',   'primer', TRUE),
  ('enbrel',   'etanercept|erelzi|eticovo', 'primer', TRUE),
  ('remicade', 'infliximab|inflectra|avsola|renflexis|ixifi|zymfentra', 'primer', TRUE),
  ('entyvio',  'vedolizumab',  'primer', TRUE),
  ('cimzia',   'certolizumab', 'primer', TRUE),
  ('simponi',  'golimumab',    'primer', TRUE),
  ('tysabri',  'natalizumab|tyruko', 'primer', TRUE),
  ('xeljanz',  'tofacitinib',  'primer', FALSE),   -- JAK inhibitor
  ('zeposia',  'ozanimod',     'primer', FALSE),   -- S1P modulator
  ('actemra',  'tocilizumab|tofidence|tyenne', 'primer', TRUE),
  ('orencia',  'abatacept',    'primer', TRUE),
  ('rituxan',  'rituximab|ruxience|truxima|riabni', 'primer', TRUE),
  -- expanded (sensitivity only)
  ('rinvoq',   'upadacitinib', 'expanded', FALSE),
  ('olumiant', 'baricitinib',  'expanded', FALSE),
  ('sotyktu',  'deucravacitinib', 'expanded', FALSE),
  ('cibinqo',  'abrocitinib',  'expanded', FALSE),
  ('velsipity','etrasimod',    'expanded', FALSE),
  ('kevzara',  'sarilumab',    'expanded', TRUE),
  ('adbry',    'tralokinumab', 'expanded', TRUE),
  ('ilumya',   'tildrakizumab','expanded', TRUE),
  ('bimzelx',  'bimekizumab',  'expanded', TRUE),
  ('omvoh',    'mirikizumab',  'expanded', TRUE)
]);

-- -----------------------------------------------------------------------------
-- claims_enriched
--   Grain: (hashed_npi, drug_name) -- identical to claims_fact (22,722,760 rows).
--   Materialized (not a view): regex match runs once over ~9K distinct drug names.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE `{target}.claims_enriched`
CLUSTER BY specialty, drug_tier AS
WITH drug_map AS (
  SELECT d.drug_name, b.brand AS ref_brand, b.tier, b.is_true_biologic
  FROM (SELECT DISTINCT drug_name FROM `tandem-interview.takehome_wu_timothy.claims_fact`) d
  LEFT JOIN `{target}.biologic_ref` b
    ON REGEXP_CONTAINS(LOWER(d.drug_name), b.match_pattern)
),
firm_lookup AS (
  SELECT * FROM `tandem-interview.takehome_wu_timothy.affiliated_firm_lookup`
  WHERE affiliated_id IS NOT NULL                                   -- caveat 5
)
SELECT
  cf.hashed_npi,
  cf.drug_name,
  cf.npi_drug_patients,
  cf.npi_drug_newpatients,
  cf.npi_drug_patients > 0                          AS has_patients,       -- caveat 7
  -- provider
  COALESCE(ps.specialty, 'Unknown')                 AS specialty,          -- caveat 3
  COALESCE(ps.specialty IN ('Dermatology','Gastroenterology','Rheumatology'), FALSE) AS is_candidate_specialty,
  -- drug economics
  dm.ref_brand,
  CASE WHEN dm.tier = 'primer'   THEN 'biologic_primer'
       WHEN dm.tier = 'expanded' THEN 'biologic_expanded'
       ELSE 'other' END                             AS drug_tier,
  COALESCE(dm.tier = 'primer', FALSE)               AS is_biologic_base,         -- $200 tier, base case
  dm.tier IS NOT NULL                               AS is_biologic_sensitivity,  -- $200 tier incl. expanded
  COALESCE(dm.is_true_biologic, FALSE)              AS is_true_biologic,
  -- institution
  cf.affiliated_id,
  cf.affiliated_id IS NOT NULL                      AS is_affiliated,      -- caveat 2
  COALESCE(INITCAP(TRIM(na.affiliated_firm_type)), 'Unaffiliated') AS firm_type,  -- caveat 4
  fl.affiliation_npi_count,                                                -- ALL providers at institution
  COALESCE(fl.affiliation_region, 'Unknown')        AS region,             -- caveat 6
  CASE WHEN cf.affiliated_id IS NULL        THEN '0. Unaffiliated'
       WHEN fl.affiliation_npi_count <= 5   THEN '1. Small (1-5)'
       WHEN fl.affiliation_npi_count <= 25  THEN '2. Mid (6-25)'
       WHEN fl.affiliation_npi_count <= 100 THEN '3. Large (26-100)'
       WHEN fl.affiliation_npi_count <= 500 THEN '4. Very large (101-500)'
       ELSE '5. System (500+)' END                  AS institution_size   -- cut points: p50=2, p90=13, p99=343
FROM `tandem-interview.takehome_wu_timothy.claims_fact` cf
LEFT JOIN `tandem-interview.takehome_wu_timothy.provider_specialty` ps
  ON ps.hashed_npi = cf.hashed_npi
LEFT JOIN `tandem-interview.takehome_wu_timothy.npi_affiliations` na
  ON na.hashed_npi = cf.hashed_npi AND na.affiliated_id = cf.affiliated_id  -- caveat 1: PAIR join
LEFT JOIN firm_lookup fl
  ON fl.affiliated_id = cf.affiliated_id
LEFT JOIN drug_map dm
  ON dm.drug_name = cf.drug_name;

-- -----------------------------------------------------------------------------
-- Validation: row count must equal claims_fact (22,722,760)
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(*) FROM `tandem-interview.takehome_wu_timothy.claims_fact`)   AS source_rows,
  (SELECT COUNT(*) FROM `{target}.claims_enriched`)   AS enriched_rows;

-- -----------------------------------------------------------------------------
-- Specialty summary (your original query, on the corrected base)
-- -----------------------------------------------------------------------------
SELECT
  specialty,
  COUNT(DISTINCT hashed_npi)                                               AS num_providers,
  COUNT(DISTINCT IF(is_biologic_base AND has_patients, hashed_npi, NULL))  AS num_biologic_prescribers,
  SUM(npi_drug_patients)                                                   AS patient_drug_pairs,
  SUM(IF(is_biologic_base, npi_drug_patients, 0))                          AS biologic_pairs_base,
  SUM(IF(is_biologic_sensitivity, npi_drug_patients, 0))                   AS biologic_pairs_sensitivity,
  SUM(npi_drug_newpatients)                                                AS new_patient_drug_pairs,
  COUNT(*)                                                                 AS npi_drug_rows,
  ROUND(COUNTIF(NOT is_affiliated) / COUNT(*), 3)                          AS pct_rows_unaffiliated
FROM `{target}.claims_enriched`
GROUP BY ROLLUP(specialty)
ORDER BY specialty IS NULL, specialty;
