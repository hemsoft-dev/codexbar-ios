"""Approved Apple-local boundary. No shared account, service, lease or web checkout."""
import itertools
import json
import unittest
from model import Client, DAY, Event, Ledger, STATES

NOW = 100 * DAY


def event(state='active', revision=1, chain='fixture-1', **values):
    return dict(source='apple', chain=chain, revision=revision, state=state,
                expires=values.get('expires', NOW + DAY),
                grace_end=values.get('grace_end'), renewing=values.get('renewing', False),
                verified_at=values.get('verified_at', NOW))


def fixture(evidence=None):
    ledger = Ledger()
    client = Client('apple', store_fixture='fixture-store-1', local_keys={('apple', 'fixture-1')})
    if evidence:
        ledger.ingest(evidence, adapter='synthetic-verified')
    client.sync(ledger, None, NOW)
    return ledger, client


class AppleLocalTests(unittest.TestCase):
    def test_all_states_without_account(self):
        expected = {'pending': False, 'trial': True, 'active': True, 'renewal': True,
                    'canceled': True, 'expired': False, 'grace': True, 'hold': False,
                    'refunded': False, 'revoked': False, 'lifetime': True, 'original': True}
        self.assertEqual(set(expected), STATES)
        for state, access in expected.items():
            with self.subTest(state=state):
                _, client = fixture(event(state, grace_end=NOW + 2 * DAY))
                self.assertEqual(client.access(None, NOW), access)
                self.assertIsNone(client.account)

    def test_subscription_trial_cancellation_and_grace_boundaries(self):
        for state in ('active', 'trial', 'canceled', 'grace'):
            for offset in (-1, 0, 1):
                with self.subTest(state=state, offset=offset):
                    grace = NOW + 2 * DAY if state == 'grace' else None
                    end = grace or NOW + DAY
                    ledger, client = fixture(event(state, grace_end=grace))
                    deadline = end + 3 * DAY
                    saved = Client.load(client.save())
                    self.assertEqual(saved.access(None, deadline + offset), offset < 0)
                    self.assertEqual(saved.cache[0]['deadline'], deadline)
                    # A successful authoritative refresh denies an expired subscription immediately.
                    online = Client('apple', store_fixture='fixture-store-1', local_keys=client.local_keys)
                    online.sync(ledger, None, end)
                    self.assertFalse(online.access(None, end))

    def test_permanent_grants_unlimited_and_relaunch_does_not_extend_timed_access(self):
        for state in ('original', 'lifetime'):
            _, client = fixture(event(state, expires=None))
            self.assertTrue(Client.load(client.save()).access(None, NOW + 10000 * DAY))
            self.assertTrue(client.access(None, NOW - 1))
        _, client = fixture(event())
        deadline = NOW + 4 * DAY
        self.assertTrue(client.access(None, deadline - 1))
        client = Client.load(client.save())
        self.assertFalse(client.access(None, NOW))  # Rolled-back wall clock.
        self.assertFalse(client.access(None, deadline))
        self.assertEqual(client.cache[0]['deadline'], deadline)
        self.assertFalse(Client('apple').access(None, NOW))

    def test_account_free_purchase_restore_and_no_desktop_transfer(self):
        ledger, apple = fixture()
        attempt = ledger.checkout_apple_local(apple, NOW)
        self.assertEqual(attempt, 'fixture-attempt-1')
        self.assertTrue(ledger.ingest(event(renewing=True), adapter='synthetic-verified'))
        self.assertTrue(ledger.complete_apple_attempt(apple, attempt, adapter='synthetic-verified'))
        apple.sync(ledger, None, NOW)
        self.assertTrue(apple.access(None, NOW))
        restored = Client('apple', store_fixture='fixture-store-1', local_keys={('apple', 'fixture-1')})
        self.assertFalse(restored.access(None, NOW))
        restored.sync(ledger, None, NOW)
        self.assertTrue(restored.access(None, NOW))
        desktop = Client('desktop')
        desktop.sync(ledger, None, NOW)
        self.assertFalse(desktop.access(None, NOW))
        self.assertEqual(ledger.checkout_apple_local(desktop, NOW), 'unsupported_platform')
        self.assertEqual(ledger.checkout_apple_local(restored, NOW), 'already_pro')
        self.assertEqual(ledger.charges, 1)
        self.assertEqual(ledger.owners, {})

    def test_original_buyer_and_unproven_family_no_charge(self):
        ledger, apple = fixture(event('original', expires=None))
        self.assertEqual(ledger.checkout_apple_local(apple, NOW), 'already_pro')
        desktop = Client('desktop')
        desktop.sync(ledger, None, NOW)
        self.assertFalse(desktop.access(None, NOW))
        family = Client('apple', store_fixture='fixture-store-1', local_keys={('apple', 'fixture-2')})
        family.sync(ledger, None, NOW)
        self.assertFalse(family.access(None, NOW))
        self.assertEqual(ledger.charges, 0)

    def test_refund_reconnect_and_distinct_valid_lifetime(self):
        for second_grant in (False, True):
            ledger, apple = fixture(event())
            ledger.ingest(event('revoked', 2), adapter='synthetic-verified')
            self.assertTrue(apple.access(None, NOW))  # Offline cache cannot observe refund yet.
            if second_grant:
                ledger.ingest(event('lifetime', chain='fixture-2', expires=None), adapter='synthetic-verified')
                apple.local_keys.add(('apple', 'fixture-2'))
            apple.sync(ledger, None, NOW)
            self.assertEqual(apple.access(None, NOW), second_grant)
            self.assertEqual(ledger.charges, 0)
        for state in ('original', 'lifetime'):
            permanent_ledger, permanent = fixture(event(state, expires=None))
            permanent_ledger.ingest(event('revoked', 2), adapter='synthetic-verified')
            permanent.sync(permanent_ledger, None, NOW)
            self.assertFalse(permanent.access(None, NOW))
        ledger, apple = fixture(event())
        self.assertTrue(ledger.ingest(event('refunded', 2), adapter='synthetic-verified'))
        self.assertTrue(apple.sync(ledger, None, NOW))
        self.assertFalse(apple.access(None, NOW))

    def test_duplicate_unordered_and_stale_revocation(self):
        stream = [event('active', 1), event('revoked', 2), event('renewal', 3)]
        for ordering in itertools.permutations(stream):
            ledger, client = fixture()
            for evidence in (*ordering, *ordering):
                ledger.ingest(evidence, adapter='synthetic-verified')
            client.sync(ledger, None, NOW)
            self.assertTrue(client.access(None, NOW))
            self.assertEqual(ledger.events[('apple', 'fixture-1')], Event.fixture(stream[2]))
            self.assertEqual(ledger.charges, 0)
        ledger, client = fixture(event('revoked', 4))
        ledger.ingest(event('active', 3), adapter='synthetic-verified')
        client.sync(ledger, None, NOW)
        self.assertFalse(client.access(None, NOW))

    def test_pending_renewal_hold_unverified_and_forged_results(self):
        for state in ('pending', 'hold', 'expired', 'grace'):
            ledger, apple = fixture(event(state, renewing=True, grace_end=NOW + DAY))
            self.assertEqual(ledger.checkout_apple_local(apple, NOW + 2 * DAY), 'manage_or_wait')
            self.assertEqual(ledger.charges, 0)
        ledger, apple = fixture()
        self.assertEqual(ledger.checkout_apple_local(apple, NOW, reconciled=False), 'verification_required')
        first = ledger.checkout_apple_local(apple, NOW)
        for adapter in ('unverified', 'browser-return', 'forged'):
            self.assertFalse(ledger.ingest(event('lifetime'), adapter=adapter))
            self.assertFalse(ledger.complete_apple_attempt(apple, first, adapter=adapter))
            apple.sync(ledger, None, NOW)
            self.assertFalse(apple.access(None, NOW))
            self.assertEqual(ledger.checkout_apple_local(apple, NOW), first)
        self.assertEqual(ledger.charges, 1)
        self.assertEqual(ledger.checkout_apple_local(apple, NOW - 1), 'verification_required')

    def test_apple_store_identity_switch_and_restore(self):
        ledger, apple = fixture(event('lifetime'))
        # Store identity changes invalidate this client's snapshot and verified local chain set.
        apple.switch_apple_store('fixture-store-2', set())
        self.assertFalse(apple.access(None, NOW))
        second_attempt = ledger.checkout_apple_local(apple, NOW)
        self.assertEqual(second_attempt, 'fixture-attempt-1')
        apple.switch_apple_store('fixture-store-1', {('apple', 'fixture-1')})
        self.assertFalse(ledger.complete_apple_attempt(apple, second_attempt, adapter='synthetic-verified'))
        apple.sync(ledger, None, NOW)
        self.assertTrue(apple.access(None, NOW))
        self.assertEqual(ledger.owners, {})

    def test_store_identities_have_independent_pending_attempts(self):
        ledger, first = fixture()
        second = Client('apple', store_fixture='fixture-store-2')
        self.assertEqual(ledger.checkout_apple_local(Client('apple'), NOW), 'verification_required')
        one = ledger.checkout_apple_local(first, NOW)
        two = ledger.checkout_apple_local(second, NOW)
        self.assertNotEqual(one, two)
        self.assertFalse(ledger.complete_apple_attempt(second, one, adapter='synthetic-verified'))
        first.switch_apple_store('fixture-store-2', set())
        self.assertEqual(ledger.checkout_apple_local(first, NOW), two)
        self.assertFalse(ledger.complete_apple_attempt(first, one, adapter='synthetic-verified'))
        first.switch_apple_store('fixture-store-1', set())
        self.assertEqual(ledger.checkout_apple_local(first, NOW), one)
        self.assertTrue(ledger.complete_apple_attempt(first, one, adapter='synthetic-verified'))
        self.assertEqual(ledger.checkout_apple_local(second, NOW), two)
        self.assertEqual(ledger.charges, 2)

    def test_reverification_time_is_not_conflicting_merchant_evidence(self):
        for state in ('active', 'lifetime', 'revoked'):
            ledger, client = fixture(event(state))
            self.assertFalse(ledger.ingest(event(state, verified_at=NOW + 1), adapter='synthetic-verified'))
            self.assertFalse(ledger.ingest(event(state, verified_at=NOW), adapter='synthetic-verified'))
            self.assertEqual(ledger.events[('apple', 'fixture-1')].verified_at, NOW + 1)
            client.sync(ledger, None, NOW + 1)
            self.assertEqual(client.access(None, NOW + 1), state != 'revoked')
            self.assertEqual(ledger.errors, [])

    def test_settings_lifetime_transition_requires_verified_renewal_off(self):
        for state in ('active', 'trial', 'renewal', 'canceled'):
            for renewing in (False, True):
                ledger, client = fixture(event(state, renewing=renewing))
                self.assertEqual(ledger.checkout_apple_local(client, NOW, product='lifetime'), 'already_pro')
                self.assertEqual(ledger.checkout_apple_local(client, NOW, entry='settings'), 'already_pro')
                result = ledger.checkout_apple_local(client, NOW, product='lifetime', entry='settings')
                self.assertEqual(result, 'manage_or_wait' if renewing else 'fixture-attempt-1')
                self.assertEqual(ledger.charges, int(not renewing))
        for state in ('original', 'lifetime', 'grace', 'hold', 'pending'):
            ledger, client = fixture(event(state, grace_end=NOW + DAY))
            result = ledger.checkout_apple_local(client, NOW, product='lifetime', entry='settings')
            self.assertIn(result, ('already_pro', 'manage_or_wait'))
            self.assertEqual(ledger.charges, 0)

    def test_non_grace_states_ignore_unrelated_grace_dates(self):
        for state in ('active', 'trial', 'renewal', 'canceled'):
            ledger, client = fixture(event(state, grace_end=NOW + 10 * DAY))
            self.assertEqual(client.cache[0]['deadline'], NOW + 4 * DAY)
            self.assertTrue(client.access(None, NOW + 4 * DAY - 1))
            self.assertFalse(client.access(None, NOW + 4 * DAY))
            fresh = Client('apple', local_keys=client.local_keys)
            self.assertTrue(fresh.sync(ledger, None, NOW + DAY))
            self.assertFalse(fresh.access(None, NOW + DAY))

    def test_permanent_cache_survives_absence_until_matching_observed_revocation(self):
        for state in ('lifetime', 'original'):
            _, client = fixture(event(state, expires=None))
            client = Client.load(client.save())
            ledger = Ledger()
            self.assertTrue(client.sync(ledger, None, NOW + DAY))
            self.assertTrue(client.access(None, NOW + DAY))
            self.assertEqual(len(client.cache), 1)
            self.assertTrue(ledger.ingest(event('revoked', 2, chain='fixture-2'), adapter='synthetic-verified'))
            client.sync(ledger, None, NOW + DAY)
            self.assertTrue(client.access(None, NOW + DAY))
            self.assertTrue(ledger.ingest(event('revoked', 2, verified_at=NOW + 2 * DAY),
                                          adapter='synthetic-verified'))
            client.sync(ledger, None, NOW + DAY)
            self.assertTrue(client.access(None, NOW + DAY))
            client.sync(ledger, None, NOW + 2 * DAY)
            self.assertFalse(client.access(None, NOW + 2 * DAY))
            client.sync(Ledger(), None, NOW + 3 * DAY)
            self.assertFalse(client.access(None, NOW + 3 * DAY))
        ledger, client = fixture(event('lifetime', revision=4, expires=None))
        client = Client.load(client.save())
        empty = Ledger()
        empty.ingest(event('revoked', revision=3), adapter='synthetic-verified')
        client.sync(empty, None, NOW)
        self.assertTrue(client.access(None, NOW), 'Stale denial cannot erase newer permanent proof after relaunch')
        empty.ingest(event('revoked', revision=5), adapter='synthetic-verified')
        client.sync(empty, None, NOW)
        self.assertFalse(client.access(None, NOW))
        _, client = fixture(event('lifetime', expires=None))
        client.switch_apple_store('fixture-store-2', set())
        client.sync(Ledger(), None, NOW)
        self.assertFalse(client.access(None, NOW))

    def test_checkout_ignores_not_yet_observed_evidence(self):
        for state in ('pending', 'hold', 'grace', 'expired'):
            ledger, client = fixture(event(state, renewing=True, grace_end=NOW + DAY, verified_at=NOW + 1))
            self.assertEqual(ledger.checkout_apple_local(client, NOW), 'fixture-attempt-1')
            self.assertEqual(ledger.charges, 1)
        ledger, client = fixture(event('canceled'))
        self.assertTrue(ledger.ingest(event('lifetime', chain='fixture-2', verified_at=NOW + 1),
                                     adapter='synthetic-verified'))
        client.local_keys.add(('apple', 'fixture-2'))
        self.assertEqual(ledger.checkout_apple_local(client, NOW, product='lifetime', entry='settings'),
                         'fixture-attempt-1')
        self.assertEqual(ledger.checkout_apple_local(client, NOW + 1, product='lifetime', entry='settings'),
                         'already_pro')
        self.assertEqual(ledger.charges, 1)

    def test_future_revisions_preserve_visible_evidence_in_any_arrival_order(self):
        for order in itertools.permutations((
                event('active'), event('revoked', 2, verified_at=NOW + 10),
                event('canceled', 3, verified_at=NOW + 20))):
            ledger, client = fixture()
            for payload in order:
                ledger.ingest(payload, adapter='synthetic-verified')
            self.assertEqual(ledger.checkout_apple_local(client, NOW), 'already_pro')
            self.assertTrue(client.access(None, NOW))
            self.assertEqual(ledger.charges, 0)
            client.sync(ledger, None, NOW + 10)
            self.assertFalse(client.access(None, NOW + 10))
            self.assertEqual(ledger.checkout_apple_local(client, NOW + 20), 'already_pro')
            self.assertEqual(ledger.charges, 0)

    def test_future_equal_revision_refresh_and_conflict_preserve_current_proof(self):
        for state in ('active', 'revoked'):
            for reverse in (False, True):
                ledger, client = fixture()
                records = [event('active'), event(state, verified_at=NOW + 10)]
                for payload in reversed(records) if reverse else records:
                    ledger.ingest(payload, adapter='synthetic-verified')
                self.assertEqual(ledger.checkout_apple_local(client, NOW), 'already_pro')
                client.sync(ledger, None, NOW + 10)
                self.assertEqual(client.access(None, NOW + 10), state == 'active')
                self.assertEqual(ledger.charges, 0)

    def test_cached_permanent_blocks_settings_lifetime_with_missing_chain(self):
        for state in ('lifetime', 'original'):
            _, client = fixture(event(state, expires=None))
            client = Client.load(client.save())
            ledger = Ledger()
            ledger.ingest(event('canceled', chain='fixture-2'), adapter='synthetic-verified')
            client.local_keys.add(('apple', 'fixture-2'))
            self.assertEqual(ledger.checkout_apple_local(client, NOW, product='lifetime', entry='settings'),
                             'already_pro')
            self.assertEqual(ledger.charges, 0)
            ledger.ingest(event('revoked', 2, verified_at=NOW + 10), adapter='synthetic-verified')
            self.assertEqual(ledger.checkout_apple_local(client, NOW, product='lifetime', entry='settings'),
                             'already_pro')
            self.assertEqual(ledger.checkout_apple_local(client, NOW + 10, product='lifetime', entry='settings'),
                             'fixture-attempt-1')
            self.assertEqual(ledger.charges, 1)

    def test_billing_payload_and_errors_reject_provider_data(self):
        ledger, _ = fixture(event())
        for name in ('provider_credentials', 'account_labels', 'balances', 'usage', 'history'):
            self.assertFalse(ledger.ingest({**event(), name: 'PRIVATE-SENTINEL'}, adapter='synthetic-verified'))
        text = json.dumps(ledger.billing_payload())
        self.assertNotIn('PRIVATE-SENTINEL', text)
        self.assertEqual(ledger.billing_payload()['bindings'], [])
        self.assertTrue(all(set(e) == {'code'} for e in ledger.errors))


if __name__ == '__main__':
    unittest.main(verbosity=2)
