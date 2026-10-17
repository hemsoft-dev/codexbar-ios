#!/usr/bin/env python3
"""Reproducible CodexBar Pro economics model for docs/2026-10-16-codexbar-pro-plan.md.

Every input is a command-line option, so a reviewer can change downloads,
conversion, price mix, churn or commission and recompute the table. Prices are
the decided US base prices; all other defaults are labeled estimates in the plan.
Run: python3 scripts/pro-economics/model.py --scenario all
"""
import argparse

PRICES = {"monthly": 1.99, "yearly": 14.99, "lifetime": 29.99}  # Decided US base prices.

SCENARIOS = {
    # name: (new downloads per month, paid conversion)  -- estimates, not measurements
    "low": (100, 0.02),
    "base": (300, 0.04),
    "high": (1000, 0.06),
}


def simulate(downloads, conversion, mix, monthly_churn, commission, months=12):
    """Returns (proceeds over `months`, proceeds in the final month)."""
    keep = 1.0 - commission
    active_monthly = 0.0
    total = 0.0
    final_month = 0.0
    for month in range(months):
        buyers = downloads * conversion
        active_monthly = active_monthly * (1.0 - monthly_churn) + buyers * mix["monthly"]
        # Yearly buyers pay up front; no cohort reaches its first renewal inside 12 months.
        gross = (
            active_monthly * PRICES["monthly"]
            + buyers * mix["yearly"] * PRICES["yearly"]
            + buyers * mix["lifetime"] * PRICES["lifetime"]
        )
        proceeds = gross * keep
        total += proceeds
        if month == months - 1:
            final_month = proceeds
    return total, final_month


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--scenario", choices=[*SCENARIOS, "all"], default="all")
    parser.add_argument("--downloads", type=float, help="New downloads per month (overrides scenario).")
    parser.add_argument("--conversion", type=float, help="Share of new downloads that pay (0-1).")
    parser.add_argument("--mix", default="0.40,0.45,0.15", help="monthly,yearly,lifetime shares of payers.")
    parser.add_argument("--monthly-churn", type=float, default=0.15, help="Monthly subscriber churn (0-1).")
    parser.add_argument("--commission", type=float, default=0.15, help="Apple commission: 0.15 SBP, 0.30 standard.")
    args = parser.parse_args()

    shares = [float(value) for value in args.mix.split(",")]
    if len(shares) != 3 or abs(sum(shares) - 1.0) > 1e-9 or min(shares) < 0:
        parser.error("--mix needs three non-negative shares that sum to 1")
    mix = dict(zip(["monthly", "yearly", "lifetime"], shares))
    names = list(SCENARIOS) if args.scenario == "all" else [args.scenario]

    print(f"commission={args.commission:.0%} mix={args.mix} monthly_churn={args.monthly_churn:.0%}")
    print("| Scenario | Downloads/month | Conversion | Payers/month | Proceeds, first 12 months | Proceeds, month 12 |")
    print("| --- | ---: | ---: | ---: | ---: | ---: |")
    for name in names:
        downloads, conversion = SCENARIOS[name]
        downloads = args.downloads if args.downloads is not None else downloads
        conversion = args.conversion if args.conversion is not None else conversion
        total, final = simulate(downloads, conversion, mix, args.monthly_churn, args.commission)
        print(
            f"| {name} | {downloads:,.0f} | {conversion:.0%} | {downloads * conversion:,.0f} "
            f"| US${total:,.0f} | US${final:,.0f} |"
        )


if __name__ == "__main__":
    main()
