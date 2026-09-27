-- =============================================================================
-- Forus DS Take-Home | Source data checks
-- Read-only against tandem-interview.takehome_wu_timothy. Run before 01.
-- Each query returns one row of check results; expected values (as of the build
-- on 2026-09-25) are in the comments so a reviewer can spot drift.
-- =============================================================================

-- 1. Keys and nulls in claims_fact --------------------------------------------
--    expect: 22,722,760 rows = distinct (npi, drug) keys; 0 null npi/drug/patients;
--            2,856,155 null affiliated_id (12.6%); 912,025 zero-patient rows;
--            0 rows with newpatients > patients
SELECT
  COUNT(*)                                                   AS rows_,
  COUNT(DISTINCT CONCAT(CAST(hashed_npi AS STRING), '|', drug_name)) AS npi_drug_keys,
  COUNTIF(hashed_npi IS NULL OR drug_name IS NULL OR npi_drug_patients IS NULL) AS null_keys,
  COUNTIF(affiliated_id IS NULL)                             AS null_affiliation,
  COUNTIF(npi_drug_patients = 0)                             AS zero_patient_rows,
  COUNTIF(npi_drug_newpatients > npi_drug_patients)          AS new_gt_total
FROM `tandem-interview.takehome_wu_timothy.claims_fact`;

-- 2. Coverage of claims by the dimension tables -------------------------------
--    expect: 7,919 claim NPIs missing from provider_specialty (~5% of patients);
--            0 claim affiliations missing from npi_affiliations or the lookup
SELECT
  COUNT(DISTINCT IF(ps.hashed_npi IS NULL, cf.hashed_npi, NULL)) AS npis_no_specialty,
  SAFE_DIVIDE(SUM(IF(ps.hashed_npi IS NULL, cf.npi_drug_patients, 0)),
              SUM(cf.npi_drug_patients))                         AS share_patients_no_specialty,
  COUNTIF(cf.affiliated_id IS NOT NULL AND na.hashed_npi IS NULL) AS rows_pair_missing_in_affiliations,
  COUNTIF(cf.affiliated_id IS NOT NULL AND fl.affiliated_id IS NULL) AS rows_aff_missing_in_lookup
FROM `tandem-interview.takehome_wu_timothy.claims_fact` cf
LEFT JOIN `tandem-interview.takehome_wu_timothy.provider_specialty` ps USING (hashed_npi)
LEFT JOIN `tandem-interview.takehome_wu_timothy.npi_affiliations` na
  ON na.hashed_npi = cf.hashed_npi AND na.affiliated_id = cf.affiliated_id
LEFT JOIN (SELECT DISTINCT affiliated_id
           FROM `tandem-interview.takehome_wu_timothy.affiliated_firm_lookup`
           WHERE affiliated_id IS NOT NULL) fl
  ON fl.affiliated_id = cf.affiliated_id;

-- 3. Dimension table quality --------------------------------------------------
--    expect: 4 specialties, 1 per NPI; 12,414 NPIs with 2 affiliations (fan-out
--            risk if joined on NPI alone); 38 raw firm_type labels -> 14 cleaned;
--            1 lookup row with NULL affiliated_id (npi_count 577,804)
SELECT
  (SELECT COUNT(DISTINCT specialty) FROM `tandem-interview.takehome_wu_timothy.provider_specialty`) AS n_specialties,
  (SELECT COUNT(*) FROM (SELECT hashed_npi FROM `tandem-interview.takehome_wu_timothy.provider_specialty`
                         GROUP BY 1 HAVING COUNT(*) > 1))                                        AS npis_multi_specialty,
  (SELECT COUNT(*) FROM (SELECT hashed_npi FROM `tandem-interview.takehome_wu_timothy.npi_affiliations`
                         GROUP BY 1 HAVING COUNT(*) > 1))                                        AS npis_multi_affiliation,
  (SELECT COUNT(DISTINCT affiliated_firm_type) FROM `tandem-interview.takehome_wu_timothy.npi_affiliations`)                    AS firm_type_raw,
  (SELECT COUNT(DISTINCT INITCAP(TRIM(affiliated_firm_type))) FROM `tandem-interview.takehome_wu_timothy.npi_affiliations`)     AS firm_type_clean,
  (SELECT COUNTIF(affiliated_id IS NULL) FROM `tandem-interview.takehome_wu_timothy.affiliated_firm_lookup`)                    AS lookup_null_ids;
