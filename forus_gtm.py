"""
forus_gtm.py - Part 1 economics layer for the Forus DS take-home.

All business logic that turns claims volume into dollars lives here, driven by one
assumptions dict. The SQL layer (sql/01-03) produces volumes only; nothing in it
needs to change to explore a new scenario.

Typical use (see part1_gtm.ipynb):

    from forus_gtm import DEFAULT_ASSUMPTIONS, specialty_scorecard, capture_curve
    a = {**DEFAULT_ASSUMPTIONS, "ops_hourly_cost": 55}
    specialty_scorecard(segments, a)

Inputs are DataFrames from the BigQuery views:
    specialty_segments  specialty x institution_size x firm_type   (n_sales_targets col)
    sales_targets       specialty x institution/practice           (1 row = 1 target)

Units: volumes are patient-drug PAIRS from claims (a patient on 2 drugs counts
twice). `scripts_per_pair` converts pairs to annual scripts Forus would service.
If both tiers use the same multiplier, it scales every specialty equally and cannot
change the ranking; it matters only for absolute $ and for payback vs acquisition.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

CANDIDATES = ["Dermatology", "Gastroenterology", "Rheumatology"]

# ---------------------------------------------------------------------------
# Assumptions. Every number a stakeholder might argue with is here.
# Given by Forus: price_* and minutes_*. Everything else is an assumption (label
# it as such in the write-up) and is meant to be changed.
# ---------------------------------------------------------------------------
DEFAULT_ASSUMPTIONS = {
    # Revenue + servicing (given in the prompt)
    "price_biologic": 200.0,          # $ per script
    "price_other": 10.0,              # $ per script
    "minutes_biologic": 30.0,         # manual servicing minutes per script
    "minutes_other": 10.0,
    # Volume conversion (assumption)
    "scripts_per_pair_biologic": 1.0, # serviced scripts per patient-drug pair per year
    "scripts_per_pair_other": 1.0,
    "capture_rate": 0.25,             # share of an onboarded provider's scripts that flow through Forus
    # Servicing cost (assumption)
    "ops_hourly_cost": 40.0,          # fully loaded $ per Provider Ops hour
    "fte_hours_per_year": 1800.0,     # productive hours per Ops FTE
    "service_other_scripts": True,    # False = platform declines to manually service $10 scripts
    # Acquisition cost (assumption)
    "cost_per_sales_target": 5000.0,  # one sales cycle per institution / independent practice
    "cost_per_provider_onboard": 250.0,  # training + setup per provider
    # Which drugs count as the $200 tier: "base" = primer list (+ biosimilars),
    # "sensitivity" = adds Rinvoq, Olumiant, Sotyktu, Kevzara, etc.
    "biologic_definition": "base",
}


def _volume_cols(a: dict) -> tuple[str, str]:
    if a["biologic_definition"] == "base":
        return "biologic_pairs", "other_pairs"
    if a["biologic_definition"] == "sensitivity":
        return "biologic_pairs_sens", "other_pairs_sens"
    raise ValueError("biologic_definition must be 'base' or 'sensitivity'")


def unit_economics(a: dict = DEFAULT_ASSUMPTIONS) -> pd.DataFrame:
    """Per-script revenue, servicing cost and margin for each tier."""
    rows = []
    for tier in ("biologic", "other"):
        price, minutes = a[f"price_{tier}"], a[f"minutes_{tier}"]
        cost = minutes / 60 * a["ops_hourly_cost"]
        rows.append({
            "tier": tier,
            "price_per_script": price,
            "service_cost_per_script": cost,
            "margin_per_script": price - cost,
            "margin_per_ops_hour": (price - cost) * 60 / minutes,
            "breakeven_ops_hourly_cost": price * 60 / minutes,
        })
    return pd.DataFrame(rows).set_index("tier")


def add_economics(df: pd.DataFrame, a: dict = DEFAULT_ASSUMPTIONS) -> pd.DataFrame:
    """Add annual revenue, servicing cost, contribution and acquisition cost columns.

    Works on any grain that has biologic/other pair columns and n_providers.
    If `n_sales_targets` is absent, each row is treated as one sales target
    (the sales_targets view).
    """
    out = df.copy()
    bio_col, oth_col = _volume_cols(a)
    n_targets = out["n_sales_targets"] if "n_sales_targets" in out else 1

    bio_scripts = out[bio_col] * a["scripts_per_pair_biologic"] * a["capture_rate"]
    oth_scripts = out[oth_col] * a["scripts_per_pair_other"] * a["capture_rate"]
    if not a["service_other_scripts"]:
        oth_scripts = oth_scripts * 0

    out["scripts_biologic"] = bio_scripts
    out["scripts_other"] = oth_scripts
    out["revenue"] = bio_scripts * a["price_biologic"] + oth_scripts * a["price_other"]
    out["ops_hours"] = (bio_scripts * a["minutes_biologic"] + oth_scripts * a["minutes_other"]) / 60
    out["service_cost"] = out["ops_hours"] * a["ops_hourly_cost"]
    out["contribution"] = out["revenue"] - out["service_cost"]
    out["acquisition_cost"] = (n_targets * a["cost_per_sales_target"]
                               + out["n_providers"] * a["cost_per_provider_onboard"])
    out["year1_net"] = out["contribution"] - out["acquisition_cost"]
    out["roi_year1"] = out["contribution"] / out["acquisition_cost"]
    return out


def _payback_months(acq, contrib):
    return np.where(contrib > 0, acq / (contrib / 12), np.inf)


def specialty_scorecard(segments: pd.DataFrame, a: dict = DEFAULT_ASSUMPTIONS,
                        specialties: list[str] | None = None) -> pd.DataFrame:
    """One row per specialty: size, value, efficiency and ops load, assuming Forus
    onboards every provider in the specialty. Use capture_curve for the more
    realistic 'first N sales targets' view."""
    specialties = specialties or CANDIDATES + ["Internal Medicine"]
    e = add_economics(segments[segments["specialty"].isin(specialties)], a)
    g = e.groupby("specialty").agg(
        providers=("n_providers", "sum"),
        biologic_prescribers=("n_biologic_prescribers", "sum"),
        sales_targets=("n_sales_targets", "sum"),
        scripts_biologic=("scripts_biologic", "sum"),
        scripts_other=("scripts_other", "sum"),
        revenue=("revenue", "sum"),
        service_cost=("service_cost", "sum"),
        contribution=("contribution", "sum"),
        acquisition_cost=("acquisition_cost", "sum"),
        ops_hours=("ops_hours", "sum"),
    )
    bio_rev = g["scripts_biologic"] * a["price_biologic"]
    g["biologic_share_of_revenue"] = bio_rev / g["revenue"]
    g["contribution_margin"] = g["contribution"] / g["revenue"]
    g["contribution_per_provider"] = g["contribution"] / g["providers"]
    g["contribution_per_sales_target"] = g["contribution"] / g["sales_targets"]
    g["providers_per_sales_target"] = g["providers"] / g["sales_targets"]
    g["payback_months"] = _payback_months(g["acquisition_cost"], g["contribution"])
    g["ops_fte"] = g["ops_hours"] / a["fte_hours_per_year"]
    g["contribution_per_ops_hour"] = g["contribution"] / g["ops_hours"]
    return g.reindex([s for s in specialties if s in g.index])


def capture_curve(targets: pd.DataFrame, a: dict = DEFAULT_ASSUMPTIONS,
                  specialties: list[str] | None = None,
                  rank_by: str = "roi_year1") -> pd.DataFrame:
    """Sort each specialty's sales targets best-first and accumulate.

    Answers: 'if the GTM team can close N targets, how much contribution does each
    specialty yield?' Rows can be single targets (sales_targets view) or segments
    carrying n_sales_targets; x-axis is cumulative sales targets either way.
    """
    specialties = specialties or CANDIDATES
    e = add_economics(targets[targets["specialty"].isin(specialties)], a)
    if "n_sales_targets" not in e:
        e["n_sales_targets"] = 1
    e = e.sort_values(["specialty", rank_by], ascending=[True, False])
    grp = e.groupby("specialty")
    for col in ("n_sales_targets", "n_providers", "contribution", "acquisition_cost"):
        e[f"cum_{col}"] = grp[col].cumsum()
    e["cum_share_contribution"] = e["cum_contribution"] / grp["contribution"].transform("sum")
    e["cum_payback_months"] = _payback_months(e["cum_acquisition_cost"], e["cum_contribution"])
    return e


def at_budget(curve: pd.DataFrame, n_targets: int | list[int]) -> pd.DataFrame:
    """Contribution, providers and payback reached by closing the best N targets."""
    ns = [n_targets] if np.isscalar(n_targets) else list(n_targets)
    rows = []
    for spec, c in curve.groupby("specialty"):
        for n in ns:
            hit = c[c["cum_n_sales_targets"] <= n]
            last = hit.iloc[-1] if len(hit) else None
            rows.append({
                "specialty": spec, "n_targets": n,
                "providers": 0 if last is None else last["cum_n_providers"],
                "contribution": 0.0 if last is None else last["cum_contribution"],
                "acquisition_cost": 0.0 if last is None else last["cum_acquisition_cost"],
                "share_of_specialty_contribution": 0.0 if last is None else last["cum_share_contribution"],
                "payback_months": np.inf if last is None else last["cum_payback_months"],
            })
    return pd.DataFrame(rows).set_index(["n_targets", "specialty"]).sort_index()


LOWER_IS_BETTER = {"payback_months", "acquisition_cost", "service_cost", "ops_fte", "ops_hours"}


def sensitivity(segments: pd.DataFrame, param: str, values: list,
                a: dict = DEFAULT_ASSUMPTIONS, metric: str = "contribution_per_sales_target",
                specialties: list[str] | None = None) -> pd.DataFrame:
    """Recompute the scorecard across values of one assumption; returns metric by
    specialty plus the leader, so you can see where (if anywhere) the ranking flips.

    Pick a metric the parameter can actually move: acquisition-cost parameters do
    not affect contribution metrics, so pair them with payback_months or roi_year1.
    """
    specialties = specialties or CANDIDATES
    rows = {}
    for v in values:
        sc = specialty_scorecard(segments, {**a, param: v}, specialties)
        if metric == "roi_year1":
            rows[v] = sc["contribution"] / sc["acquisition_cost"]
        else:
            rows[v] = sc[metric]
    out = pd.DataFrame(rows).T
    out.index.name = param
    pick = out[specialties].idxmin if metric in LOWER_IS_BETTER else out[specialties].idxmax
    out["leader"] = pick(axis=1)
    return out


def rank_targets(targets: pd.DataFrame, specialty: str, a: dict = DEFAULT_ASSUMPTIONS,
                 top: int = 50) -> pd.DataFrame:
    """Targeting list for one specialty, best year-1 ROI first.

    champion_* columns name the institution's highest-volume biologic prescriber
    (the first contact) and how much of the target's biologic volume they carry.
    """
    e = with_firm_group(add_economics(targets[targets["specialty"] == specialty], a))
    cols = ["target_id", "firm_group", "firm_type", "institution_size", "region", "n_providers",
            "n_biologic_prescribers", "biologic_pairs", "other_pairs", "top_biologic_brand",
            "champion_npi", "champion_biologic_pairs", "champion_share_of_biologic",
            "champion_top_brand", "contribution", "acquisition_cost", "roi_year1"]
    cols = [c for c in cols if c in e]
    return e.sort_values("roi_year1", ascending=False)[cols].head(top).reset_index(drop=True)


# ---------------------------------------------------------------------------
# Targeting breakdowns (Part 1b)
# ---------------------------------------------------------------------------
MAJOR_FIRM_TYPES = ("Hospital", "Physician Group", "Unaffiliated")


def with_firm_group(df: pd.DataFrame) -> pd.DataFrame:
    """Add firm_group: Hospital / Physician Group / Unaffiliated / Other facility.

    The 14 cleaned firm types are dominated by hospitals and physician groups;
    the rest (ASCs, FQHCs, home health, etc.) are small enough to pool.
    """
    out = df.copy()
    ft = out["firm_type"].fillna("Unaffiliated")
    out["firm_group"] = ft.where(ft.isin(MAJOR_FIRM_TYPES), "Other facility")
    return out


def breakdown(df: pd.DataFrame, specialty: str, by: str | list[str],
              a: dict = DEFAULT_ASSUMPTIONS) -> pd.DataFrame:
    """Where a specialty's value sits, by any dimension(s) of segments or targets.

    by: e.g. "institution_size", "firm_group", ["firm_group", "institution_size"],
        or "region" (targets only). Works on specialty_segments or sales_targets.
    """
    by = [by] if isinstance(by, str) else list(by)
    e = with_firm_group(add_economics(df[df["specialty"] == specialty], a))
    if "n_sales_targets" not in e:
        e["n_sales_targets"] = 1
    g = e.groupby(by, observed=True).agg(
        providers=("n_providers", "sum"),
        biologic_prescribers=("n_biologic_prescribers", "sum"),
        sales_targets=("n_sales_targets", "sum"),
        biologic_pairs=("biologic_pairs", "sum"),
        contribution=("contribution", "sum"),
        acquisition_cost=("acquisition_cost", "sum"),
    )
    g["providers_per_target"] = g["providers"] / g["sales_targets"]
    g["biologic_pairs_per_provider"] = g["biologic_pairs"] / g["providers"]
    g["contribution_per_target"] = g["contribution"] / g["sales_targets"]
    g["share_of_contribution"] = g["contribution"] / g["contribution"].sum()
    g["roi_year1"] = g["contribution"] / g["acquisition_cost"]
    return g.sort_values("roi_year1", ascending=False)


# --- New-patient mix -----------------------------------------------------------
# Manufacturers value new starts most: a new patient on a biologic is a new revenue
# stream for them, while a continuing patient is a re-authorization of one they
# already have. The cost model treats both the same (one authorization per patient
# per year); this view shows how the specialties differ on that dimension.

def new_patient_mix(df: pd.DataFrame, specialties: list[str] | None = None,
                    by: str | list[str] = "specialty") -> pd.DataFrame:
    """New vs continuing patient-drug pairs, as shares and per unit of sales effort.

    Works on specialty_segments (or sales_targets). Volumes are patient-drug pairs
    before capture_rate, so the per-target figures are the full market a deal reaches.
    """
    by = [by] if isinstance(by, str) else list(by)
    specialties = specialties or CANDIDATES
    e = with_firm_group(df[df["specialty"].isin(specialties)])
    if "n_sales_targets" not in e:
        e["n_sales_targets"] = 1
    g = e.groupby(by, observed=True).agg(
        providers=("n_providers", "sum"),
        sales_targets=("n_sales_targets", "sum"),
        biologic_pairs=("biologic_pairs", "sum"),
        biologic_new_pairs=("biologic_new_pairs", "sum"),
        other_pairs=("other_pairs", "sum"),
        other_new_pairs=("other_new_pairs", "sum"),
    )
    g["biologic_new_share"] = g["biologic_new_pairs"] / g["biologic_pairs"]
    g["other_new_share"] = g["other_new_pairs"] / g["other_pairs"]
    g["total_new_share"] = ((g["biologic_new_pairs"] + g["other_new_pairs"])
                            / (g["biologic_pairs"] + g["other_pairs"]))
    g["new_biologic_per_provider"] = g["biologic_new_pairs"] / g["providers"]
    g["new_biologic_per_target"] = g["biologic_new_pairs"] / g["sales_targets"]
    g["share_of_new_biologic"] = g["biologic_new_pairs"] / g["biologic_new_pairs"].sum()
    return g.sort_values("new_biologic_per_target", ascending=False)
