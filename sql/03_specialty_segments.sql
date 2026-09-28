-- =============================================================================
-- Forus DS Take-Home | Part 1 mart: specialty_segments (view)
-- Depends on: {target}.npi_summary  (02_npi_summary.sql)
-- Grain:      specialty x institution_size x firm_type  (a few hundred rows)
--
-- The small table the notebook's cost model runs on. A view, so it is always in
-- sync with npi_summary and costs ~nothing to query (npi_summary is ~15 MB).
--
-- n_sales_targets = the number of separate sales motions needed to reach every
-- provider in the segment: one per distinct institution for affiliated providers,
-- one per provider for unaffiliated providers (each is its own practice).
-- Institutions are counted within specialty: a hospital with both rheum and GI
-- providers counts once in each, since each specialty launch sells to it separately.
-- =============================================================================

CREATE OR REPLACE VIEW `{target}.specialty_segments` AS
SELECT
  specialty,
  is_candidate_specialty,
  institution_size,
  COALESCE(firm_type, 'Unaffiliated')                           AS firm_type,
  COUNT(*)                                                      AS n_providers,
  COUNTIF(is_biologic_prescriber)                               AS n_biologic_prescribers,
  COUNT(DISTINCT primary_affiliated_id) + COUNTIF(NOT is_affiliated) AS n_sales_targets,
  SUM(biologic_pairs)                                           AS biologic_pairs,
  SUM(other_pairs)                                              AS other_pairs,
  SUM(biologic_new_pairs)                                       AS biologic_new_pairs,
  SUM(other_new_pairs)                                          AS other_new_pairs,
  SUM(biologic_pairs_sens)                                      AS biologic_pairs_sens,
  SUM(other_pairs_sens)                                         AS other_pairs_sens
FROM `{target}.npi_summary`
GROUP BY 1, 2, 3, 4;

-- =============================================================================
-- sales_targets (view)
-- Grain: specialty x sales target. A sales target is one institution (primary
-- affiliation) for affiliated providers, or the provider itself if unaffiliated.
-- This is the unit a GTM team actually sells to, so it drives both the
-- acquisition-cost side of the framework and the targeting list (Part 1b).
--
-- champion_* = the target's highest-volume biologic prescriber in this specialty
-- (ties -> more total volume, then lowest NPI): the natural first contact inside
-- an institution. champion_share_of_biologic shows how dependent the target's
-- biologic volume is on that one person.
-- =============================================================================

CREATE OR REPLACE VIEW `{target}.sales_targets` AS
WITH base AS (
  SELECT
    *,
    COALESCE(CAST(primary_affiliated_id AS STRING), CONCAT('npi_', CAST(hashed_npi AS STRING))) AS target_id
  FROM `{target}.npi_summary`
),
agg AS (
  SELECT
    specialty,
    is_candidate_specialty,
    target_id,
    is_affiliated,
    -- firm_type is per (npi, institution) pair and differs across NPIs for ~3K
    -- institutions, so take the most common label among this specialty's providers
    APPROX_TOP_COUNT(COALESCE(firm_type, 'Unaffiliated'), 1)[OFFSET(0)].value AS firm_type,
    ANY_VALUE(institution_size)                     AS institution_size,
    ANY_VALUE(COALESCE(region, 'Unknown'))          AS region,
    ANY_VALUE(affiliation_npi_count)                AS institution_npi_count,  -- all specialties
    COUNT(*)                                        AS n_providers,             -- this specialty only
    COUNTIF(is_biologic_prescriber)                 AS n_biologic_prescribers,
    SUM(biologic_pairs)                             AS biologic_pairs,
    SUM(other_pairs)                                AS other_pairs,
    SUM(biologic_new_pairs)                         AS biologic_new_pairs,
    SUM(other_new_pairs)                            AS other_new_pairs,
    SUM(biologic_pairs_sens)                        AS biologic_pairs_sens,
    SUM(other_pairs_sens)                           AS other_pairs_sens,
    APPROX_TOP_COUNT(top_biologic_brand, 1)[SAFE_OFFSET(0)].value AS top_biologic_brand,
    ARRAY_AGG(STRUCT(hashed_npi, biologic_pairs, biologic_new_pairs, total_pairs, top_biologic_brand)
              ORDER BY biologic_pairs DESC, total_pairs DESC, hashed_npi
              LIMIT 1)[OFFSET(0)]                   AS champion
  FROM base
  GROUP BY specialty, is_candidate_specialty, target_id, is_affiliated
)
SELECT
  * EXCEPT (champion),
  champion.hashed_npi                                          AS champion_npi,
  champion.biologic_pairs                                      AS champion_biologic_pairs,
  champion.biologic_new_pairs                                  AS champion_biologic_new_pairs,
  champion.top_biologic_brand                                  AS champion_top_brand,
  SAFE_DIVIDE(champion.biologic_pairs, biologic_pairs)         AS champion_share_of_biologic
FROM agg;
