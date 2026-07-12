# Golden expectations generated once from the reference `openskill` package
# (dev/test-only; NOT a runtime dependency of app.rating). Reproduce with:
#
#   from openskill.models import ThurstoneMostellerFull
#   # epsilon=0.0 mirrors our decisive-win CFG(rating_draw_margin=0.0): the draw
#   # margin must not enter the win path on either side.
#   m = ThurstoneMostellerFull(mu=25.0, sigma=25/3, beta=25/6, tau=25/300,
#                              kappa=1e-4, epsilon=0.0)
#   a = [m.rating(name="a")]; b = [m.rating(name="b")]
#   [[na], [nb]] = m.rate([a, b], ranks=[0, 1])   # team A wins
#   print(na.mu, na.sigma, nb.mu, nb.sigma)
#
# Paste the printed values below to full precision.
import math

from app.config import Settings
from app.rating import Rating, default_rating, performance_score, rate_two_teams, tier_for, Outcome

CFG = Settings(rating_draw_margin=0.0)  # decisive-win golden: tie margin must not enter

# Generated from openskill 6.2.0 ThurstoneMostellerFull(..., epsilon=0.0).
GOLD_WIN_MU = 29.205473176557785     # na.mu
GOLD_WIN_SIGMA = 7.6331949777882855  # na.sigma
GOLD_LOSE_MU = 20.794526823442215    # nb.mu
GOLD_LOSE_SIGMA = 7.6331949777882855

# 2v1 decisive win, all seeded default (μ=25). Guards the team-SUM (not mean)
# aggregation of μ in the standardized margin — invisible at 1v1.
#   A = [m.rating(), m.rating()]; B = [m.rating()]; m.rate([A, B], ranks=[0, 1])
GOLD_2V1_WIN_MU = 25.519621405744676     # each of the two winners
GOLD_2V1_WIN_SIGMA = 8.151167388069535
GOLD_2V1_LOSE_MU = 24.480378594255324    # lone loser
GOLD_2V1_LOSE_SIGMA = 8.205065332370392

# 2v2 unequal-μ decisive win: A seeded μ=30, B seeded μ=20, A wins.
#   A = [m.rating(mu=30), m.rating(mu=30)]; B = [m.rating(mu=20), m.rating(mu=20)]
GOLD_2V2_WIN_MU = 30.948822277579048     # each winner (seed μ=30)
GOLD_2V2_WIN_SIGMA = 8.126489871216027
GOLD_2V2_LOSE_MU = 19.051177722420952    # each loser (seed μ=20)
GOLD_2V2_LOSE_SIGMA = 8.126489871216027


def test_golden_two_team_1v1_equal_weight():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.A_WINS, CFG)
    assert math.isclose(na[0].mu, GOLD_WIN_MU, rel_tol=1e-6)
    assert math.isclose(na[0].sigma, GOLD_WIN_SIGMA, rel_tol=1e-6)
    assert math.isclose(nb[0].mu, GOLD_LOSE_MU, rel_tol=1e-6)
    assert math.isclose(nb[0].sigma, GOLD_LOSE_SIGMA, rel_tol=1e-6)


def test_golden_2v1_decisive_win_equal_weight():
    a = [default_rating(CFG), default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0, 1.0], [1.0], Outcome.A_WINS, CFG)
    for r in na:
        assert math.isclose(r.mu, GOLD_2V1_WIN_MU, rel_tol=1e-6)
        assert math.isclose(r.sigma, GOLD_2V1_WIN_SIGMA, rel_tol=1e-6)
    assert math.isclose(nb[0].mu, GOLD_2V1_LOSE_MU, rel_tol=1e-6)
    assert math.isclose(nb[0].sigma, GOLD_2V1_LOSE_SIGMA, rel_tol=1e-6)


def test_golden_2v2_unequal_mu_decisive_win_equal_weight():
    a = [Rating(30.0, 25.0 / 3.0), Rating(30.0, 25.0 / 3.0)]
    b = [Rating(20.0, 25.0 / 3.0), Rating(20.0, 25.0 / 3.0)]
    (na, nb) = rate_two_teams(a, b, [1.0, 1.0], [1.0, 1.0], Outcome.A_WINS, CFG)
    for r in na:
        assert math.isclose(r.mu, GOLD_2V2_WIN_MU, rel_tol=1e-6)
        assert math.isclose(r.sigma, GOLD_2V2_WIN_SIGMA, rel_tol=1e-6)
    for r in nb:
        assert math.isclose(r.mu, GOLD_2V2_LOSE_MU, rel_tol=1e-6)
        assert math.isclose(r.sigma, GOLD_2V2_LOSE_SIGMA, rel_tol=1e-6)


def test_winner_rises_loser_falls_sigma_shrinks():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.A_WINS, CFG)
    assert na[0].mu > 25.0 > nb[0].mu
    assert na[0].sigma < 25.0 / 3.0 and nb[0].sigma < 25.0 / 3.0


def test_equal_teams_draw_is_near_noop_on_mu():
    a = [default_rating(CFG)]
    b = [default_rating(CFG)]
    (na, nb) = rate_two_teams(a, b, [1.0], [1.0], Outcome.DRAW, CFG)
    assert math.isclose(na[0].mu, 25.0, abs_tol=1e-6)
    assert math.isclose(nb[0].mu, 25.0, abs_tol=1e-6)


def test_objective_weight_splits_team_delta():
    # two players on the winning team, one carries all the objective weight
    a = [default_rating(CFG), default_rating(CFG)]
    b = [default_rating(CFG), default_rating(CFG)]
    (na, _) = rate_two_teams(a, b, [4.0, 1.0], [1.0, 1.0], Outcome.A_WINS, CFG)
    gain_hi = na[0].mu - 25.0
    gain_lo = na[1].mu - 25.0
    assert gain_hi > gain_lo > 0.0


def test_performance_score_objective_weighted_and_floored():
    cfg = Settings()
    objective = performance_score(
        dict(kills=0, assists=0, captures=2, neutralizes=1, revives=0, deaths=0), cfg)
    killer = performance_score(
        dict(kills=2, assists=0, captures=0, neutralizes=0, revives=0, deaths=0), cfg)
    assert objective > killer  # 2*cap(3)+1*neut(2)=8 > 2*kill(1)=2
    floored = performance_score(
        dict(kills=0, assists=0, captures=0, neutralizes=0, revives=0, deaths=10), cfg)
    assert floored == cfg.rating_perf_floor


def test_tier_for_boundaries_inclusive_lower_edge():
    cfg = Settings()
    assert tier_for(-5.0, cfg) == "Bronze"
    assert tier_for(10.0, cfg) == "Silver"    # inclusive lower edge
    assert tier_for(9.999, cfg) == "Bronze"
    assert tier_for(999.0, cfg) == "Diamond"


def test_smurf_promotion_within_few_matches():
    cfg = Settings(rating_draw_margin=0.0)
    strong = default_rating(cfg)
    start_tier = tier_for(strong.ordinal(cfg.rating_ordinal_z), cfg)
    for _ in range(6):
        weak = default_rating(cfg)
        (na, _) = rate_two_teams([strong], [weak], [1.0], [1.0], Outcome.A_WINS, cfg)
        strong = na[0]
    end_tier = tier_for(strong.ordinal(cfg.rating_ordinal_z), cfg)
    assert strong.ordinal(cfg.rating_ordinal_z) > 0.0
    # ordinal climbed materially from the seed (μ up, σ down)
    assert strong.mu > 25.0 and strong.sigma < 25.0 / 3.0
