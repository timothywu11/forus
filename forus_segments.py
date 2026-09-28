"""
forus_segments.py - Part 2: dermatology provider segmentation for Provider Operations.

Unit of analysis: the prescriber (488 in the data). Practices are rolled up afterwards,
because Ops routes at the practice/account level but support needs are driven by what
individual prescribers write.

Pipeline (see part2_clustering.ipynb):
    feats = prepare(bq("SELECT * FROM derm_prescriber_features"))
    evaluate_k(feats)                          # pick k: silhouette, Davies-Bouldin, bootstrap stability
    seg = fit_segments(feats, k=4)             # scaler + k-means + human-readable names
    profile(feats, seg.labels)                 # what each segment looks like
    routing_rules(feats, seg.labels)           # shallow tree: rules Ops can apply without the model
    workload(rx_monthly, seg.assignments)      # Ops hours / FTE per segment
    staffing_forecast(...)                     # scenario: FTE needed as each segment grows

Everything a stakeholder might change (features, k, minutes per script, FTE hours) is a
parameter; nothing is hard-coded to this snapshot except the default segment names.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.cluster import AgglomerativeClustering, KMeans
from sklearn.metrics import adjusted_rand_score, davies_bouldin_score, silhouette_score
from sklearn.mixture import GaussianMixture
from sklearn.model_selection import cross_val_score
from sklearn.preprocessing import StandardScaler
from sklearn.tree import DecisionTreeClassifier, export_text

# ---------------------------------------------------------------------------
# Features
# ---------------------------------------------------------------------------
# Each feature is a driver of support need, not just a description:
FEATURES = {
    "f_log_rx_per_month":         "Volume: scripts per active month (log). Drives total workload.",
    "advanced_share":             "Complexity: share of biologic / advanced systemic scripts (heaviest PA work).",
    "bridge_rate":                "Access friction: share of scripts placed on a bridge (temporary supply) program.",
    "commercial_share":           "Payer mix: share with commercial insurance (step therapy, copay programs).",
    "government_share":           "Payer mix: share with Medicare / Medicaid / other government coverage.",
    "peds_share":                 "Patient mix: share of patients under 18 (different PA criteria).",
    "f_log_brands":               "Breadth: distinct brands prescribed (log). More payer policies to know.",
    "top_pharmacy_share":         "Pharmacy concentration: share at the #1 pharmacy (specialty-pharmacy reliance).",
    "f_log_practice_prescribers": "Account size: prescribers in the primary practice (log).",
}

# Considered and dropped (documented so reviewers can see the choice):
DROPPED_FEATURES = {
    "generic_share":     "r = -0.77 with advanced_share; would double-weight drug mix.",
    "unknown_ins_share": "r = -0.86 with commercial_share; mirror image of it.",
    "pa_rate":           "PA required on ~95% of scripts; almost no variation between prescribers.",
    "months_active":     "Lifecycle stage (new vs established), not a practice type; used as an overlay.",
}

# Extra columns shown in profiles (not clustered on).
PROFILE_COLS = [
    "rx_per_month", "n_rx", "advanced_share", "generic_share", "branded_other_share",
    "bridge_rate", "commercial_share", "government_share", "unknown_ins_share",
    "peds_share", "senior_share", "n_brands", "top_pharmacy_share",
    "practice_prescribers", "months_active", "pa_rate",
]

# Ops assumptions (minutes per script from the Part 1 prompt).
OPS_ASSUMPTIONS = {
    "minutes_advanced": 30.0,     # biologic / advanced systemic script
    "minutes_other": 10.0,        # generic or other branded script
    "fte_hours_per_year": 1800.0, # productive hours per Provider Ops FTE (same as Part 1)
}

SEGMENT_NAMES_K4 = {
    "biologic": "Biologic Specialists",
    "volume": "High-Volume Mixed Practices",
    "commercial": "Commercial Topical & Acne",
    "generic": "Generic-Leaning, Government-Payer",
}


def prepare(features: pd.DataFrame) -> pd.DataFrame:
    """Add the log-transformed columns if the input came from raw counts (idempotent)."""
    df = features.copy()
    if "f_log_rx_per_month" not in df:
        df["f_log_rx_per_month"] = np.log(df["rx_per_month"])
    if "f_log_brands" not in df:
        df["f_log_brands"] = np.log(df["n_brands"])
    if "f_log_practice_prescribers" not in df:
        df["f_log_practice_prescribers"] = np.log(df["practice_prescribers"])
    return df


def feature_matrix(df: pd.DataFrame, features: list[str] | None = None):
    features = features or list(FEATURES)
    scaler = StandardScaler().fit(df[features])
    return scaler, scaler.transform(df[features]), features


# ---------------------------------------------------------------------------
# Choosing k
# ---------------------------------------------------------------------------
def bootstrap_stability(X: np.ndarray, k: int, n_boot: int = 30, frac: float = 0.8,
                        seed: int = 0) -> tuple[float, float]:
    """Refit k-means on random 80% subsamples and compare to the full-data solution
    (adjusted Rand index on the overlapping rows). ~1 = the same segments every time."""
    rng = np.random.default_rng(seed)
    full = KMeans(k, n_init=20, random_state=seed).fit(X)
    scores = []
    for b in range(n_boot):
        idx = rng.choice(len(X), int(frac * len(X)), replace=False)
        sub = KMeans(k, n_init=10, random_state=seed + b + 1).fit(X[idx])
        scores.append(adjusted_rand_score(full.labels_[idx], sub.predict(X[idx])))
    return float(np.mean(scores)), float(np.min(scores))


def evaluate_k(df: pd.DataFrame, ks=range(2, 9), features: list[str] | None = None,
               n_boot: int = 30, seed: int = 0) -> pd.DataFrame:
    """Compare cluster counts. Higher silhouette and stability are better; lower
    Davies-Bouldin is better. Smallest-segment size guards against tiny clusters."""
    _, X, _ = feature_matrix(df, features)
    rows = []
    for k in ks:
        km = KMeans(k, n_init=20, random_state=seed).fit(X)
        stab_mean, stab_min = bootstrap_stability(X, k, n_boot=n_boot, seed=seed)
        rows.append({
            "k": k,
            "inertia": km.inertia_,
            "silhouette": silhouette_score(X, km.labels_),
            "davies_bouldin": davies_bouldin_score(X, km.labels_),
            "bootstrap_ari_mean": stab_mean,
            "bootstrap_ari_min": stab_min,
            "smallest_segment": int(np.bincount(km.labels_).min()),
        })
    return pd.DataFrame(rows).set_index("k")


# ---------------------------------------------------------------------------
# Fitting and naming
# ---------------------------------------------------------------------------
@dataclass
class Segmentation:
    scaler: StandardScaler
    model: KMeans
    features: list[str]
    labels: np.ndarray            # segment name per row of the input
    centers: pd.DataFrame         # z-scored centroids, indexed by segment name
    assignments: pd.DataFrame     # prescriber_id, primary_practice_id, segment

    def predict(self, df: pd.DataFrame) -> np.ndarray:
        """Assign new or updated prescribers to the existing segments."""
        X = self.scaler.transform(prepare(df)[self.features])
        return self.centers.index.to_numpy()[self.model.predict(X)]


def _name_k4(centers: pd.DataFrame) -> dict[int, str]:
    """Deterministic names for the 4-segment solution, read off the centroids so the
    names survive re-runs (k-means cluster numbers are arbitrary):
      highest advanced_share                 -> Biologic Specialists
      of the rest, highest volume            -> High-Volume Mixed Practices
      of the rest, highest commercial share  -> Commercial Topical & Acne
      remaining                              -> Generic-Leaning, Government-Payer
    """
    left = list(centers.index)
    out = {}
    for key, col in (("biologic", "advanced_share"), ("volume", "f_log_rx_per_month"),
                     ("commercial", "commercial_share")):
        pick = centers.loc[left, col].idxmax()
        out[pick] = SEGMENT_NAMES_K4[key]
        left.remove(pick)
    out[left[0]] = SEGMENT_NAMES_K4["generic"]
    return out


def fit_segments(df: pd.DataFrame, k: int = 4, features: list[str] | None = None,
                 seed: int = 0, n_init: int = 50) -> Segmentation:
    df = prepare(df)
    scaler, X, feats = feature_matrix(df, features)
    km = KMeans(k, n_init=n_init, random_state=seed).fit(X)
    centers = pd.DataFrame(km.cluster_centers_, columns=feats)
    names = _name_k4(centers) if (k == 4 and set(FEATURES) <= set(feats)) \
        else {i: f"Segment {i + 1}" for i in range(k)}
    # reorder model centroids so that model.predict index -> names order
    order = sorted(names, key=lambda i: list(SEGMENT_NAMES_K4.values()).index(names[i])
                   if names[i] in SEGMENT_NAMES_K4.values() else i)
    km.cluster_centers_ = km.cluster_centers_[order]
    centers = centers.loc[order]
    centers.index = [names[i] for i in order]
    labels = centers.index.to_numpy()[km.predict(X)]
    assignments = df[["prescriber_id", "primary_practice_id"]].copy()
    assignments["segment"] = labels
    return Segmentation(scaler, km, feats, labels, centers, assignments)


# ---------------------------------------------------------------------------
# Interpretation and evaluation
# ---------------------------------------------------------------------------
def profile(df: pd.DataFrame, labels, cols: list[str] | None = None) -> pd.DataFrame:
    """Median of each profile column by segment, plus size and share of scripts."""
    cols = cols or PROFILE_COLS
    d = prepare(df).assign(segment=labels)
    out = d.groupby("segment")[cols].median().T
    out.loc["prescribers"] = d.groupby("segment").size()
    out.loc["share_of_scripts"] = d.groupby("segment")["n_rx"].sum() / d["n_rx"].sum()
    out.loc["practices"] = d.groupby("segment")["primary_practice_id"].nunique()
    return out


RULE_COLS = ["rx_per_month", "advanced_share", "generic_share", "branded_other_share",
             "bridge_rate", "commercial_share", "government_share", "peds_share",
             "n_brands", "top_pharmacy_share", "practice_prescribers"]


def routing_rules(df: pd.DataFrame, labels, max_depth: int = 3, min_leaf: int = 10,
                  cols: list[str] | None = None) -> tuple[str, float, DecisionTreeClassifier]:
    """Fit a shallow decision tree that mimics the segments on raw (unscaled) features.
    Returns human-readable rules and 5-fold cross-validated agreement with k-means.
    This is how Ops can route a new provider without running the model."""
    cols = cols or RULE_COLS
    tree = DecisionTreeClassifier(max_depth=max_depth, min_samples_leaf=min_leaf, random_state=0)
    cv = cross_val_score(tree, df[cols], labels, cv=5).mean()
    tree.fit(df[cols], labels)
    return export_text(tree, feature_names=cols, decimals=2), float(cv), tree


def robustness(df: pd.DataFrame, labels, k: int = 4, features: list[str] | None = None,
               seed: int = 0) -> pd.Series:
    """Agreement (adjusted Rand index) between k-means and other algorithms on the same
    features. ~1 = identical; ~0 = unrelated. Moderate values mean the segments are
    real tendencies rather than sharply separated groups."""
    _, X, _ = feature_matrix(prepare(df), features)
    codes = pd.factorize(labels)[0]
    return pd.Series({
        "ward_hierarchical": adjusted_rand_score(codes, AgglomerativeClustering(k, linkage="ward").fit_predict(X)),
        "gaussian_mixture": adjusted_rand_score(codes, GaussianMixture(k, n_init=5, random_state=seed).fit(X).predict(X)),
    }, name="adjusted_rand_vs_kmeans")


def practice_rollup(assignments: pd.DataFrame, features: pd.DataFrame | None = None) -> pd.DataFrame:
    """One row per practice: prescribers, dominant segment and how dominant it is.
    'mixed' practices (dominant share < 75%) should route per prescriber."""
    a = assignments.copy()
    if features is not None:
        a = a.merge(features[["prescriber_id", "n_rx"]], on="prescriber_id", how="left")
    g = a.groupby("primary_practice_id")
    out = pd.DataFrame({
        "prescribers": g.size(),
        "dominant_segment": g["segment"].agg(lambda s: s.value_counts().index[0]),
        "dominant_share": g["segment"].agg(lambda s: s.value_counts(normalize=True).iloc[0]),
    })
    if "n_rx" in a:
        out["scripts"] = g["n_rx"].sum()
    out["routing"] = np.where(out["dominant_share"] >= 0.75, "route as practice", "mixed: route per prescriber")
    return out.sort_values("prescribers", ascending=False)


# ---------------------------------------------------------------------------
# Ops translation: workload and staffing
# ---------------------------------------------------------------------------
def workload(rx_monthly: pd.DataFrame, assignments: pd.DataFrame,
             a: dict = OPS_ASSUMPTIONS) -> pd.DataFrame:
    """Monthly Ops hours by segment.

    rx_monthly: prescriber_id, rx_month, drug_class, n  (from derm_rx_clean)
    Hours = advanced scripts x minutes_advanced + other scripts x minutes_other.
    """
    d = rx_monthly.merge(assignments[["prescriber_id", "segment"]], on="prescriber_id")
    d["minutes"] = np.where(d["drug_class"] == "advanced_systemic", a["minutes_advanced"], a["minutes_other"])
    d["hours"] = d["n"] * d["minutes"] / 60
    out = d.groupby(["rx_month", "segment"]).agg(
        scripts=("n", "sum"), hours=("hours", "sum"), active_prescribers=("prescriber_id", "nunique"))
    out["hours_per_prescriber"] = out["hours"] / out["active_prescribers"]
    out["fte"] = out["hours"] / (a["fte_hours_per_year"] / 12)
    return out


def staffing_forecast(current: pd.DataFrame, growth: dict[str, float] | float,
                      a: dict = OPS_ASSUMPTIONS) -> pd.DataFrame:
    """FTE needed if each segment's prescriber count grows by the given factor.

    current: one month of workload() for the baseline (index = segment).
    growth:  e.g. {"Biologic Specialists": 2.0, ...} or a single factor for all.
    Assumes hours per prescriber stay at the baseline month's level.
    """
    base = current[["active_prescribers", "hours_per_prescriber"]].copy()
    g = pd.Series(growth, index=base.index) if isinstance(growth, dict) else pd.Series(growth, index=base.index)
    base["growth"] = g.fillna(1.0)
    base["future_prescribers"] = base["active_prescribers"] * base["growth"]
    base["future_hours"] = base["future_prescribers"] * base["hours_per_prescriber"]
    base["current_fte"] = base["active_prescribers"] * base["hours_per_prescriber"] / (a["fte_hours_per_year"] / 12)
    base["future_fte"] = base["future_hours"] / (a["fte_hours_per_year"] / 12)
    total = base[["active_prescribers", "future_prescribers", "future_hours", "current_fte", "future_fte"]].sum()
    base.loc["Total", total.index] = total
    return base


# What each segment means for Provider Operations (kept next to the code so the
# notebook, the write-up and any dashboard use the same wording).
OPS_PLAYBOOK = pd.DataFrame([
    {"segment": "Biologic Specialists",
     "support_need": "Complex access: biologic PAs, appeals, bridge enrollment, specialty-pharmacy coordination",
     "queue": "Specialty access queue (senior PA specialists, bridge/appeals expertise)",
     "staffing_driver": "Hours per script (30 min); highest bridge and not-eligible rates"},
    {"segment": "High-Volume Mixed Practices",
     "support_need": "Throughput across many brands and pharmacies; large multi-prescriber accounts",
     "queue": "Dedicated account pods with batching and automation for routine PAs",
     "staffing_driver": "Script volume; largest share of total hours"},
    {"segment": "Commercial Topical & Acne",
     "support_need": "Step-therapy and formulary exceptions for branded topicals; copay/savings programs; younger patients",
     "queue": "Commercial formulary queue (templated step-therapy letters, copay card workflow)",
     "staffing_driver": "Moderate volume, low per-script complexity"},
    {"segment": "Generic-Leaning, Government-Payer",
     "support_need": "Mostly routine generic PAs; Medicare/Medicaid rules; newer accounts still onboarding",
     "queue": "Standard queue with templates; onboarding track for first 90 days",
     "staffing_driver": "Low hours per prescriber; onboarding effort front-loaded"},
]).set_index("segment")
