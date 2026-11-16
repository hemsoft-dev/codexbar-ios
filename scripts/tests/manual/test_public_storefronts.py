"""Manual public-offer checks; never added to automatic PR CI."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[3]
SPEC = importlib.util.spec_from_file_location("public_storefronts", ROOT / "scripts/check-public-storefronts.py")
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
URL = "https://apps.apple.com/us/app/codexbar-usage-monitor/id6787769891"


def page(price=0, currency="USD", **changes):
    app = {"@type": "SoftwareApplication", "name": "CodexBar Usage Monitor",
           "author": {"url": "https://apps.apple.com/us/developer/franz-hemmer/id6787769894"},
           "offers": {"@type": "Offer", "price": price, "priceCurrency": currency}}
    app.update(changes)
    return (f'<link rel="canonical" href="{URL}">'
            f'<script type="application/ld+json">{json.dumps(app)}</script>').encode()


class PublicStorefrontTests(unittest.TestCase):
    def test_explicit_zero_is_free_and_paid_offer_stays_paid(self):
        self.assertTrue(CHECK.parse_offer(page(), URL, "us")["free"])
        paid = CHECK.parse_offer(page(3.99), URL, "us")
        self.assertFalse(paid["free"])
        self.assertEqual(paid["price"], 3.99)

    def test_price_never_defaults_to_zero(self):
        for price in (None, False, True, "", "NaN", "Infinity", -1, [], {}):
            with self.subTest(price=price), self.assertRaises(CHECK.StorefrontError):
                CHECK.parse_offer(page(price), URL, "us")
        with self.assertRaises(CHECK.StorefrontError):
            CHECK.parse_offer(page(offers={"@type": "Offer", "priceCurrency": "USD"}), URL, "us")

    def test_currency_and_developer_are_required(self):
        for currency in (None, "", "US", "usd"):
            with self.subTest(currency=currency), self.assertRaises(CHECK.StorefrontError):
                CHECK.parse_offer(page(currency=currency), URL, "us")
        with self.assertRaises(CHECK.StorefrontError):
            CHECK.parse_offer(page(author={"url": "https://apps.apple.com/us/developer/other/id123"}), URL, "us")

    def test_redirect_cannot_substitute_another_country_or_app(self):
        for target in (URL.replace("/us/", "/ca/"), URL.replace("6787769891", "123"),
                       URL.replace("https:", "http:"), URL.replace("apps.apple.com", "example.com")):
            with self.subTest(target=target), self.assertRaises(CHECK.StorefrontError):
                CHECK.parse_offer(page(), target, "us")
        with self.assertRaises(CHECK.StorefrontError):
            CHECK.parse_offer(page().replace(URL.encode(), URL.replace("/us/", "/ca/").encode()), URL, "us")

    def test_missing_or_duplicate_app_and_canonical_are_rejected(self):
        raw = page()
        for bad in (b"<p>Free</p>", raw + raw, raw[raw.index(b"<script"):],
                    page(offers=[]), page(**{"@type": "WebPage"})):
            with self.subTest(raw=bad), self.assertRaises(CHECK.StorefrontError):
                CHECK.parse_offer(bad, URL, "us")

    def test_partial_transport_failure_keeps_progress_and_never_retries(self):
        calls = []
        failure = OSError("synthetic connection failure")

        def fetch(url):
            calls.append(url)
            if len(calls) == 2:
                raise failure
            return page(), URL

        with tempfile.TemporaryDirectory() as temp:
            output, raw = Path(temp) / "report.json", Path(temp) / "raw"
            with self.assertRaises(OSError) as caught:
                CHECK.collect({"USA": "us", "ZZZ": "zz", "ZZY": "zy"}, output, raw, fetch)
            self.assertIs(caught.exception, failure)
            report = json.loads(output.read_text())
            self.assertFalse(report["complete"])
            self.assertEqual(report["freeCount"], 1)
            self.assertEqual(len(report["observations"]), 2)
            self.assertEqual(len(calls), 2)
            self.assertEqual((raw / "USA.html").read_bytes(), page())
            self.assertIn("synthetic connection failure", report["observations"][-1]["error"])

    def test_empty_duplicate_or_existing_destinations_make_no_requests(self):
        def forbidden(_):
            self.fail("Invalid input must not fetch")

        with tempfile.TemporaryDirectory() as temp:
            output, raw = Path(temp) / "report.json", Path(temp) / "raw"
            for mapping in ({}, {"USA": "us", "CAN": "us"}, {"USA": "../"}):
                with self.subTest(mapping=mapping), self.assertRaises(CHECK.StorefrontError):
                    CHECK.collect(mapping, output, raw, forbidden)
            output.write_text("retain")
            with self.assertRaises(CHECK.StorefrontError):
                CHECK.collect({"USA": "us"}, output, raw, forbidden)
            self.assertEqual(output.read_text(), "retain")

    def test_pinned_mapping_covers_original_inventory_exactly(self):
        manifest = json.loads((ROOT / "docs/evidence/2026-11-15-storefront-territories.json").read_text())
        original = json.loads((ROOT / "docs/evidence/2026-10-29-free-schedule-readback.json").read_text())
        self.assertEqual(sorted(manifest["territories"]), sorted(original["expectedTerritories"]))
        self.assertEqual(len(manifest["territories"]), 175)
        self.assertEqual(len(set(manifest["territories"].values())), 175)
        self.assertEqual(manifest["territories"]["XKS"], "xk")

    def test_receipt_failure_cannot_mask_primary_or_qualify_success(self):
        failure = OSError("primary fetch failure")
        def failed_fetch(_):
            raise failure
        for fetch, expected in ((failed_fetch, failure), (lambda _: (page(), URL), None)):
            with self.subTest(primary=expected), tempfile.TemporaryDirectory() as temp:
                output, raw = Path(temp) / "report.json", Path(temp) / "raw"
                # Raw-byte writes use io.open via write_bytes; patch only the report's open.
                original = Path.open
                def report_failure(path, *args, **kwargs):
                    if path == output:
                        raise PermissionError("synthetic receipt failure")
                    return original(path, *args, **kwargs)
                with patch.object(Path, "open", report_failure), self.assertRaises(OSError) as caught:
                    CHECK.collect({"USA": "us"}, output, raw, fetch)
                if expected is not None:
                    self.assertIs(caught.exception, expected)
                else:
                    self.assertIsInstance(caught.exception, PermissionError)


if __name__ == "__main__":
    unittest.main()
