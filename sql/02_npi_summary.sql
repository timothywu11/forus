-- =============================================================================
-- Forus DS Take-Home | Part 1 mart: npi_summary
-- Depends on: {target}.claims_enriched  (01_build_analytics_layer.sql)
-- Grain:      one row per hashed_npi (158,583 rows)
--
-- Volumes are patient-drug PAIRS (see unit caveat in 01). No dollar or cost logic
-- lives here on purpose: economics are computed in the notebook from an editable
-- ASSUMPTIONS cell, so stakeholders can change prices / minutes / costs without SQL.
--
-- Primary institution = the affiliation carrying the most patient-drug pairs for the
-- NPI (ties -> lowest affiliated_id). NPIs whose claims carry no affiliated_id are
-- is_affiliated = FALSE. Note: claims_fact assigns each (npi, drug) to exactly one
-- affiliation, so an NPI can split volume across 2 institutions; n_affiliations
-- counts institutions seen in claims.
-- =============================================================================

CREATE OR REPLACE TABLE `{target}.npi_summary`
CLUSTER BY specialty AS
WITH by_aff AS (
  SELECT hashed_npi, affiliated_id, firm_type, institution_size, region, affiliation_npi_count,
         SUM(npi_drug_patients) AS pairs
  FROM `{target}.claims_enriched`
  GROUP BY 1, 2, 3, 4, 5, 6
),
primary_aff AS (
  SELECT * EXCEPT (rn) FROM (
    SELECT hashed_npi, affiliated_id, firm_type, institution_size, region, affiliation_npi_count,
           ROW_NUMBER() OVER (PARTITION BY hashed_npi
                              ORDER BY affiliated_id IS NULL, pairs DESC, affiliated_id) AS rn
    FROM by_aff)
  WHERE rn = 1
),
top_bio AS (
  SELECT hashed_npi,
         ARRAY_AGG(ref_brand ORDER BY p DESC, ref_brand LIMIT 1)[OFFSET(0)] AS top_biologic_brand
  FROM (SELECT hashed_npi, ref_brand, SUM(npi_drug_patients) AS p
        FROM `{target}.claims_enriched`
        WHERE is_biologic_base AND has_patients
        GROUP BY 1, 2)
  GROUP BY 1
),
vol AS (
  SELECT
    hashed_npi,
    ANY_VALUE(specialty)                                        AS specialty,
    LOGICAL_OR(is_candidate_specialty)                          AS is_candidate_specialty,
    COUNT(DISTINCT affiliated_id)                               AS n_affiliations,
    -- base case ($200 tier = primer list + biosimilars)
    SUM(IF(is_biologic_base, npi_drug_patients, 0))             AS biologic_pairs,
    SUM(IF(is_biologic_base, npi_drug_newpatients, 0))          AS biologic_new_pairs,
    SUM(IF(NOT is_biologic_base, npi_drug_patients, 0))         AS other_pairs,
    SUM(IF(NOT is_biologic_base, npi_drug_newpatients, 0))      AS other_new_pairs,
    -- sensitivity ($200 tier incl. expanded list, e.g. Rinvoq)
    SUM(IF(is_biologic_sensitivity, npi_drug_patients, 0))      AS biologic_pairs_sens,
    SUM(IF(NOT is_biologic_sensitivity, npi_drug_patients, 0))  AS other_pairs_sens,
    SUM(npi_drug_patients)                                      AS total_pairs,
    COUNTIF(has_patients)                                       AS n_drugs,
    COUNT(DISTINCT IF(is_biologic_base AND has_patients, ref_brand, NULL)) AS n_biologic_brands
  FROM `{target}.claims_enriched`
  GROUP BY 1
)
SELECT
  v.hashed_npi,
  v.specialty,
  v.is_candidate_specialty,
  -- institution (primary)
  COALESCE(p.affiliated_id IS NOT NULL, FALSE) AS is_affiliated,
  v.n_affiliations,
  p.affiliated_id                              AS primary_affiliated_id,
  p.firm_type,
  p.institution_size,
  p.region,
  p.affiliation_npi_count,
  -- volume
  v.biologic_pairs, v.biologic_new_pairs, v.other_pairs, v.other_new_pairs,
  v.biologic_pairs_sens, v.other_pairs_sens, v.total_pairs,
  SAFE_DIVIDE(v.biologic_pairs, v.total_pairs) AS biologic_share,
  v.biologic_pairs > 0                         AS is_biologic_prescriber,
  v.n_drugs, v.n_biologic_brands, t.top_biologic_brand
FROM vol v
LEFT JOIN primary_aff p USING (hashed_npi)
LEFT JOIN top_bio t USING (hashed_npi);

-- -----------------------------------------------------------------------------
-- Validation: one row per NPI, volumes reconcile to claims_enriched
-- -----------------------------------------------------------------------------
SELECT
  (SELECT COUNT(DISTINCT hashed_npi) FROM `{target}.claims_enriched`) AS source_npis,
  COUNT(*)                                                            AS summary_rows,
  (SELECT SUM(npi_drug_patients) FROM `{target}.claims_enriched`)     AS source_pairs,
  SUM(total_pairs)                                                    AS summary_pairs,
  COUNTIF(biologic_pairs + other_pairs != total_pairs)                AS bad_splits
FROM `{target}.npi_summary`;
