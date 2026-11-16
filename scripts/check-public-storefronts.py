#!/usr/bin/env python3
"""Observe public App Store offers, without accounts, purchases or ASC access.

Run manually. One page fetch per territory, including Apple's canonical
redirects, serially and without retries or cookies.
Raw responses stay in the supplied evidence directory; the compact receipt
records hashes and observed offers. Errors stop collection and retain progress.
"""

import argparse
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
from html.parser import HTMLParser
import json
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, Request


APP_ID = "6787769891"
DEVELOPER_ID = "6787769894"


def now():
    return datetime.now(timezone.utc).isoformat()


class StorefrontError(ValueError):
    """The response cannot prove this app's offer in the requested territory."""


class PageData(HTMLParser):
    def __init__(self):
        super().__init__()
        self.canonical = []
        self.blocks = []
        self.current = None

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == "link" and attrs.get("rel") == "canonical":
            self.canonical.append(attrs.get("href", ""))
        if tag == "script" and attrs.get("type") == "application/ld+json":
            self.current = []

    def handle_data(self, data):
        if self.current is not None:
            self.current.append(data)

    def handle_endtag(self, tag):
        if tag == "script" and self.current is not None:
            self.blocks.append("".join(self.current))
            self.current = None


def is_app_url(url, country):
    parts = urlsplit(url)
    return (
        parts.scheme == "https" and parts.netloc == "apps.apple.com"
        and parts.path.startswith(f"/{country}/app/")
        and parts.path.rstrip("/").endswith(f"/id{APP_ID}")
    )


def parse_offer(raw, final_url, country):
    if not is_app_url(final_url, country):
        raise StorefrontError("Response changed app identity or storefront")
    page = PageData()
    page.feed(raw.decode("utf-8"))
    if len(page.canonical) != 1 or not is_app_url(page.canonical[0], country):
        raise StorefrontError("Missing or mismatched canonical app/storefront")
    apps = []
    for block in page.blocks:
        value = json.loads(block)
        if isinstance(value, dict) and value.get("@type") == "SoftwareApplication":
            apps.append(value)
    if len(apps) != 1:
        raise StorefrontError("Expected exactly one SoftwareApplication")
    app = apps[0]
    author = app.get("author")
    if not isinstance(author, dict) or not str(author.get("url", "")).endswith(f"/id{DEVELOPER_ID}"):
        raise StorefrontError("Unexpected developer identity")
    offer = app.get("offers")
    if not isinstance(offer, dict) or offer.get("@type") != "Offer":
        raise StorefrontError("Missing single offer")
    price = offer.get("price")
    if isinstance(price, bool) or not isinstance(price, (int, float, str)):
        raise StorefrontError("Price must be explicit numeric data")
    try:
        amount = Decimal(str(price))
    except InvalidOperation as error:
        raise StorefrontError("Invalid price") from error
    currency = offer.get("priceCurrency")
    if not amount.is_finite() or amount < 0 or not isinstance(currency, str) or not re.fullmatch("[A-Z]{3}", currency):
        raise StorefrontError("Invalid amount or currency")
    return {"name": app.get("name"), "developerURL": author["url"],
            "canonicalURL": page.canonical[0], "price": price,
            "currency": currency, "free": amount == 0}


class PublicRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).scheme != "https" or urlsplit(newurl).netloc != "apps.apple.com":
            raise StorefrontError("Refused redirect outside public Apple storefront")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def fetch(url):
    # No cookie handler, account credentials, custom auth headers or retries.
    with build_opener(PublicRedirects()).open(Request(url), timeout=20) as response:
        if response.status != 200:
            raise StorefrontError(f"Unexpected HTTP status {response.status}")
        raw = response.read(2_000_001)
        if len(raw) > 2_000_000:
            raise StorefrontError("Response exceeds evidence size bound")
        return raw, response.url


def collect(territories, output, raw_dir, fetch_page=fetch, manifest_sha256=None):
    if not territories or any(not re.fullmatch("[A-Z]{3}", k) or not re.fullmatch("[a-z]{2}", v)
                              for k, v in territories.items()) or len(set(territories.values())) != len(territories):
        raise StorefrontError("Expected unique explicit territory/storefront mapping")
    if output.exists() or raw_dir.exists():
        raise StorefrontError("Evidence destinations must be new; existing evidence is preserved")
    raw_dir.mkdir(parents=True)
    report = {"startedAt": now(), "appID": APP_ID, "method": "anonymous public GET; serial; no retries",
              "territoryManifestSHA256": manifest_sha256,
              "expectedTerritories": sorted(territories), "observations": [], "complete": False}
    primary_failure = None
    try:
        for territory, country in sorted(territories.items()):
            row = {"territory": territory, "country": country,
                   "requestedURL": f"https://apps.apple.com/{country}/app/id{APP_ID}", "startedAt": now()}
            report["observations"].append(row)
            try:
                raw, final_url = fetch_page(row["requestedURL"])
                (raw_dir / f"{territory}.html").write_bytes(raw)
                row.update({"finalURL": final_url, "responseSHA256": hashlib.sha256(raw).hexdigest(),
                            "responseBytes": len(raw)})
                row["offer"] = parse_offer(raw, final_url, country)
            except Exception as error:
                row["error"] = f"{type(error).__name__}: {error}"
                raise
            finally:
                row["finishedAt"] = now()
        report["complete"] = True
    except Exception as error:
        primary_failure = error
        raise
    finally:
        report["finishedAt"] = now()
        report["freeCount"] = sum(row.get("offer", {}).get("free", False) for row in report["observations"])
        try:
            with output.open("x", encoding="utf-8") as receipt:
                receipt.write(json.dumps(report, indent=2, ensure_ascii=True) + "\n")
        except OSError:
            if primary_failure is None:
                raise
            print("Could not persist receipt; preserving the primary collection failure and raw evidence.", file=sys.stderr)
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--territories", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--raw-dir", required=True, type=Path)
    args = parser.parse_args()
    manifest_bytes = args.territories.read_bytes()
    manifest = json.loads(manifest_bytes)
    result = collect(manifest["territories"], args.output, args.raw_dir,
                     manifest_sha256=hashlib.sha256(manifest_bytes).hexdigest())
    print(f"Observed {len(result['observations'])} storefronts; {result['freeCount']} explicit Free offers")
    return 0 if result["freeCount"] == len(result["expectedTerritories"]) else 1


if __name__ == "__main__":
    raise SystemExit(main())
