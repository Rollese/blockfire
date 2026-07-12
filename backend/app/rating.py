"""Pure Weng-Lin OpenSkill two-team rating (ADR-0012). No I/O, no DB, no deps.

The two-team Thurstone-Mosteller full-pairing update; reduces to the classic
pairwise update at 1v1. Objective-weighting scales each player's share of the
team's Δμ by their contribution weight (σ shrinks uniformly). Kept dependency-
free and deterministic so it is fully unit-testable and gate-reproducible.
"""
import math
from dataclasses import dataclass
from enum import Enum

RATING_MODULE_VERSION = 1
_SIGMA_FLOOR_FRACTION = 1e-4  # kappa: never let a σ² factor go <= 0


class Outcome(Enum):
    A_WINS = "a_wins"
    B_WINS = "b_wins"
    DRAW = "draw"


@dataclass(frozen=True)
class Rating:
    mu: float
    sigma: float

    def ordinal(self, z: float) -> float:
        return self.mu - z * self.sigma


def default_rating(cfg) -> Rating:
    return Rating(cfg.rating_mu_init, cfg.rating_sigma_init)


def performance_score(mp, cfg) -> float:
    """Objective-weighted contribution weight for one match_player row (dict or
    ORM object exposing kills/assists/captures/neutralizes/revives/deaths)."""
    def g(k):
        return mp[k] if isinstance(mp, dict) else getattr(mp, k)
    score = (cfg.rating_w_kill * g("kills")
             + cfg.rating_w_assist * g("assists")
             + cfg.rating_w_capture * g("captures")
             + cfg.rating_w_neutralize * g("neutralizes")
             + cfg.rating_w_revive * g("revives")
             - cfg.rating_w_death * g("deaths"))
    return max(score, cfg.rating_perf_floor)


def _pdf(x: float) -> float:
    return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)


def _cdf(x: float) -> float:
    return 0.5 * math.erfc(-x / math.sqrt(2.0))


def _v_win(t: float) -> float:
    denom = _cdf(t)
    if denom < 1e-12:
        return -t  # numerical tail guard (matches TM limiting behavior)
    return _pdf(t) / denom


def _w_win(t: float) -> float:
    v = _v_win(t)
    return v * (v + t)


def _v_draw(t: float, eps: float) -> float:
    num = _pdf(-eps - t) - _pdf(eps - t)
    den = _cdf(eps - t) - _cdf(-eps - t)
    if abs(den) < 1e-12:
        return 0.0
    return num / den


def _w_draw(t: float, eps: float) -> float:
    den = _cdf(eps - t) - _cdf(-eps - t)
    if abs(den) < 1e-12:
        return 1.0
    v = _v_draw(t, eps)
    return v * v + (((eps - t) * _pdf(eps - t) - (-eps - t) * _pdf(-eps - t)) / den)


def rate_two_teams(team_a, team_b, weights_a, weights_b, outcome, cfg):
    """Return (new_team_a, new_team_b) as lists of Rating. weights_* are the
    per-player objective contribution weights within their team."""
    beta2 = cfg.rating_beta ** 2
    tau2 = cfg.rating_tau ** 2
    # dynamics: re-inflate σ² before the update
    a_sig2 = [r.sigma ** 2 + tau2 for r in team_a]
    b_sig2 = [r.sigma ** 2 + tau2 for r in team_b]
    a_mu = [r.mu for r in team_a]
    b_mu = [r.mu for r in team_b]

    sum_a2 = sum(a_sig2)
    sum_b2 = sum(b_sig2)
    c = math.sqrt(sum_a2 + sum_b2 + 2.0 * beta2)
    # Weng-Lin team performance is the SUM of player μ, not the mean; this only
    # differs from a mean for multi-player teams and is what standardizes the
    # margin t below (feeds both v and w). 1v1 reduces to a single μ.
    sum_a_mu = sum(a_mu)
    sum_b_mu = sum(b_mu)
    eps = cfg.rating_draw_margin  # already a fraction of c-scale margin; applied on standardized t

    # Weng-Lin multi-team correction (openskill's gamma): the σ² shrink of a
    # team scales by sqrt(team Σσ²)/c so a team never over-collapses uncertainty.
    # For a single-team-per-side (1v1) match this reduces to sqrt(σ²)/c.
    gamma_a = math.sqrt(sum_a2) / c
    gamma_b = math.sqrt(sum_b2) / c

    mean_wa = sum(weights_a) / len(weights_a)
    mean_wb = sum(weights_b) / len(weights_b)

    def updated(mu_i, sig2_i, mu_self, mu_opp, sign, w_i, mean_w, gamma):
        t = (mu_self - mu_opp) / c
        if outcome is Outcome.DRAW:
            v = _v_draw(t, eps)
            w = _w_draw(t, eps)
            s = 1.0  # draw v is already signed by t
        else:
            v = _v_win(sign * t)
            w = _w_win(sign * t)
            s = sign
        new_mu = mu_i + s * (w_i / mean_w) * (sig2_i / c) * v
        factor = max(1.0 - (sig2_i / (c * c)) * gamma * w, _SIGMA_FLOOR_FRACTION)
        new_sigma = math.sqrt(sig2_i * factor)
        return Rating(new_mu, new_sigma)

    if outcome is Outcome.A_WINS:
        sign_a, sign_b = 1.0, -1.0
    elif outcome is Outcome.B_WINS:
        sign_a, sign_b = -1.0, 1.0
    else:
        sign_a = sign_b = 1.0

    new_a = [updated(a_mu[i], a_sig2[i], sum_a_mu, sum_b_mu, sign_a, weights_a[i], mean_wa, gamma_a)
             for i in range(len(team_a))]
    new_b = [updated(b_mu[i], b_sig2[i], sum_b_mu, sum_a_mu, sign_b, weights_b[i], mean_wb, gamma_b)
             for i in range(len(team_b))]
    return new_a, new_b


def tier_for(ordinal: float, cfg) -> str:
    name = cfg.rating_tier_breakpoints()[0][1]
    for lo, label in cfg.rating_tier_breakpoints():
        if ordinal >= lo:
            name = label
        else:
            break
    return name
