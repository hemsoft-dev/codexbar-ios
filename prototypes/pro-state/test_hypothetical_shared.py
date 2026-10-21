"""EXCLUDED hypothetical sharing experiments. These are not Apple-local acceptance or promises."""
from dataclasses import replace
import itertools
import json
import unittest
from model import Client, DAY, Event, Ledger, Proposal, STATES

NOW = 100 * DAY
ACCOUNT = 'fixture-account-1'
OTHER = 'fixture-account-2'
POLICY = Proposal(True, True, True, 3 * DAY, 30 * DAY, True, frozenset({'TEST'}))


def evidence(state='active', revision=1, source='apple', chain='fixture-1', **values):
    return dict(source=source, chain=chain, revision=revision, state=state,
                expires=values.get('expires', NOW + DAY),
                grace_end=values.get('grace_end'), renewing=values.get('renewing', False),
                verified_at=values.get('verified_at', NOW))


def setup(event=None, policy=POLICY):
    ledger = Ledger()
    event = event or evidence()
    assert ledger.ingest(event, adapter='synthetic-verified')
    key = (event['source'], event['chain'])
    assert ledger.bind(key, ACCOUNT)
    apple, desktop = Client('apple', local_keys={key}), Client('desktop')
    for client in (apple, desktop):
        client.sign_in(ledger, ACCOUNT)
        client.sync(ledger, policy, NOW)
    return ledger, apple, desktop


class StateTests(unittest.TestCase):
    def test_every_source_specific_state_and_one_calculated_access(self):
        expected = {'pending': False, 'trial': True, 'active': True, 'renewal': True,
                    'canceled': True, 'expired': False, 'grace': True, 'hold': False,
                    'refunded': False, 'revoked': False, 'lifetime': True, 'original': True}
        self.assertEqual(set(expected), STATES)
        for source, state in itertools.product(('apple', 'web', 'play', 'microsoft'), STATES):
            with self.subTest(source=source, state=state):
                ledger, _, desktop = setup(evidence(state, source=source, grace_end=NOW + 2 * DAY))
                self.assertEqual(desktop.access(POLICY, NOW), expected[state])
                self.assertEqual(len(ledger.events), 1)

    def test_scope_candidates_preserve_apple_local_promise(self):
        for state in ('original', 'lifetime', 'active'):
            for shared, original, lifetime in itertools.product((False, True), repeat=3):
                policy = replace(POLICY, shared=shared, share_original=original, share_lifetime=lifetime)
                _, apple, desktop = setup(evidence(state), policy)
                self.assertTrue(apple.access(policy, NOW))
                expected = shared and (state != 'original' or original) and (state != 'lifetime' or lifetime)
                self.assertEqual(desktop.access(policy, NOW), expected)

    def test_subscriber_walkthrough_exact_charge_attempts(self):
        ledger = Ledger()
        apple, desktop = Client('apple'), Client('desktop')
        apple.sign_in(ledger, ACCOUNT)
        self.assertEqual(ledger.checkout(apple, POLICY, NOW, 'TEST'), 'fixture-attempt-1')
        self.assertTrue(ledger.ingest(evidence(renewing=True), adapter='synthetic-verified'))
        apple.local_keys.add(('apple', 'fixture-1'))
        apple.sync(ledger, POLICY, NOW)
        desktop.sign_in(ledger, ACCOUNT)
        desktop.sync(ledger, POLICY, NOW)
        self.assertTrue(apple.access(POLICY, NOW))
        self.assertFalse(desktop.access(POLICY, NOW))
        self.assertEqual(ledger.checkout(desktop, POLICY, NOW, 'UNAPPROVED'), 'region_disabled')
        ledger.bind(('apple', 'fixture-1'), ACCOUNT)
        for client in (apple, desktop):
            client.sync(ledger, POLICY, NOW)
            self.assertTrue(client.access(POLICY, NOW))
            self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST'), 'already_pro')
        ledger.ingest(evidence('canceled', 2), adapter='synthetic-verified')
        for client in (apple, desktop):
            client.sync(ledger, POLICY, NOW)
            self.assertTrue(client.access(POLICY, NOW))
        ledger.ingest(evidence('expired', 3, expires=NOW + DAY), adapter='synthetic-verified')
        ledger.attempts.clear()  # Merchant confirmation completed the historical attempt.
        for client in (apple, desktop):
            client.sync(ledger, POLICY, NOW + DAY)
            self.assertFalse(client.access(POLICY, NOW + DAY))
        self.assertEqual(ledger.checkout(desktop, POLICY, NOW + DAY, 'TEST'), 'fixture-attempt-2')
        self.assertEqual(ledger.charges, 2)

    def test_original_buyer_reinstall_family_and_zero_charges(self):
        ledger, apple, desktop = setup(evidence('original'))
        for client in (apple, desktop):
            self.assertTrue(client.access(POLICY, NOW))
            self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST'), 'already_pro')
        reinstall = Client('desktop')
        self.assertFalse(reinstall.access(POLICY, NOW))
        reinstall.sign_in(ledger, ACCOUNT)
        reinstall.sync(ledger, POLICY, NOW)
        self.assertTrue(reinstall.access(POLICY, NOW))
        family = Client('desktop')
        family.sign_in(ledger, OTHER)
        family.sync(ledger, POLICY, NOW)
        self.assertFalse(family.access(POLICY, NOW))
        self.assertEqual(ledger.charges, 0)

    def test_refund_one_chain_preserves_independent_lifetime(self):
        ledger, apple, desktop = setup()
        ledger.ingest(evidence('lifetime', chain='fixture-2'), adapter='synthetic-verified')
        ledger.bind(('apple', 'fixture-2'), ACCOUNT)
        apple.local_keys.add(('apple', 'fixture-2'))
        ledger.ingest(evidence('refunded', 2), adapter='synthetic-verified')
        for client in (apple, desktop):
            client.sync(ledger, POLICY, NOW)
            self.assertTrue(client.access(POLICY, NOW))
            self.assertEqual({e['chain'] for e in client.cache}, {'fixture-2'})
            self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST'), 'already_pro')
        self.assertEqual(ledger.charges, 0)

    def test_refund_reconnect_and_offline_deadline(self):
        ledger, apple, desktop = setup()
        ledger.ingest(evidence('revoked', 2), adapter='synthetic-verified')
        self.assertTrue(desktop.access(POLICY, NOW))
        apple.sync(ledger, POLICY, NOW)
        self.assertFalse(apple.access(POLICY, NOW))
        desktop.sync(ledger, POLICY, NOW)
        self.assertFalse(desktop.access(POLICY, NOW))
        self.assertEqual(ledger.charges, 0)

    def test_duplicate_unordered_events_and_stale_revocations(self):
        stream = [evidence('active', 1), evidence('revoked', 2), evidence('renewal', 3)]
        for ordering in itertools.permutations(stream):
            ledger = Ledger()
            for event in (*ordering, *ordering):
                ledger.ingest(event, adapter='synthetic-verified')
            self.assertEqual(ledger.events[('apple', 'fixture-1')], Event.fixture(stream[2]))
            self.assertEqual(ledger.charges, 0)
        ledger, _, desktop = setup(evidence('revoked', 4))
        self.assertFalse(ledger.ingest(evidence('active', 3), adapter='synthetic-verified'))
        desktop.sync(ledger, POLICY, NOW)
        self.assertFalse(desktop.access(POLICY, NOW))

    def test_equal_revision_conflict_fails_closed_in_both_orders(self):
        for ordering in itertools.permutations([evidence(), evidence('lifetime')]):
            ledger = Ledger()
            for event in ordering:
                ledger.ingest(event, adapter='synthetic-verified')
            self.assertEqual(ledger.events[('apple', 'fixture-1')].state, 'revoked')

    def test_binding_conflict_source_namespacing_and_signout_switch(self):
        ledger, apple, desktop = setup()
        self.assertFalse(ledger.bind(('apple', 'fixture-1'), OTHER))
        ledger.ingest(evidence(source='web'), adapter='synthetic-verified')
        self.assertTrue(ledger.bind(('web', 'fixture-1'), OTHER))
        desktop.sign_out()
        self.assertFalse(desktop.access(POLICY, NOW))
        desktop.sign_in(ledger, 'fixture-account-3')
        desktop.sync(ledger, POLICY, NOW)
        self.assertFalse(desktop.access(POLICY, NOW))
        apple.sign_out()
        apple.sync(ledger, POLICY, NOW)
        self.assertTrue(apple.access(POLICY, NOW))

    def test_delete_recovery_preserves_local_and_prevents_claim_theft(self):
        ledger, apple, desktop = setup(evidence(renewing=True))
        ledger.delete(ACCOUNT)
        desktop.sync(ledger, POLICY, NOW)
        apple.sync(ledger, POLICY, NOW)
        self.assertFalse(desktop.access(POLICY, NOW))
        self.assertTrue(apple.access(POLICY, NOW))
        self.assertTrue(ledger.events[('apple', 'fixture-1')].renewing)
        self.assertFalse(ledger.bind(('apple', 'fixture-1'), OTHER))
        self.assertFalse(ledger.recover(ACCOUNT, ('apple', 'fixture-1')))
        self.assertTrue(ledger.recover(ACCOUNT, ('apple', 'fixture-1'), adapter='synthetic-verified'))
        desktop.sync(ledger, POLICY, NOW)
        self.assertFalse(desktop.access(POLICY, NOW))  # Old session stays revoked.
        desktop.sign_in(ledger, ACCOUNT)
        desktop.sync(ledger, POLICY, NOW)
        self.assertTrue(desktop.access(POLICY, NOW))
        self.assertEqual(ledger.charges, 0)

    def test_offline_boundaries_relaunch_clock_rollback_and_no_proof(self):
        for allowance, lease in ((0, DAY), (3 * DAY, 30 * DAY), (7 * DAY, 90 * DAY)):
            policy = replace(POLICY, subscription_allowance=allowance, lifetime_lease=lease)
            for state in ('trial', 'active', 'canceled', 'grace', 'lifetime', 'original'):
                with self.subTest(allowance=allowance, lease=lease, state=state):
                    _, apple, desktop = setup(evidence(state, grace_end=NOW + 2 * DAY), policy)
                    deadline = (NOW + lease if state in {'lifetime', 'original'}
                                else NOW + (2 * DAY if state == 'grace' else DAY) + allowance)
                    desktop = Client.load(desktop.save())
                    self.assertTrue(desktop.access(policy, deadline - 1))
                    saved_deadline = desktop.cache[0]['deadline']
                    desktop = Client.load(desktop.save())
                    self.assertFalse(desktop.access(policy, NOW))
                    self.assertFalse(desktop.access(policy, deadline))
                    self.assertFalse(desktop.access(policy, deadline + 1))
                    self.assertEqual(desktop.cache[0]['deadline'], saved_deadline)
                    if state in {'lifetime', 'original'}:
                        self.assertTrue(apple.access(policy, NOW + 10000 * DAY))
            self.assertFalse(Client('desktop').access(policy, NOW))
        ledger, _, desktop = setup()
        self.assertFalse(desktop.sync(ledger, POLICY, NOW - 1))

    def test_apple_allowance_is_independent_and_online_expiry_denies(self):
        policy = replace(POLICY, subscription_allowance=0)
        ledger, apple, desktop = setup(policy=policy)
        self.assertTrue(apple.access(policy, NOW + DAY + 3 * DAY - 1))
        self.assertFalse(apple.access(policy, NOW + DAY + 3 * DAY))
        self.assertFalse(desktop.access(policy, NOW + DAY))
        fresh = Client('apple', local_keys={('apple', 'fixture-1')})
        fresh.sync(ledger, policy, NOW + DAY)
        self.assertFalse(fresh.access(policy, NOW + DAY))

    def test_pending_renewing_hold_and_grace_suppress_checkout(self):
        for state in ('pending', 'hold', 'grace', 'expired'):
            ledger, _, desktop = setup(evidence(state, renewing=True, grace_end=NOW + DAY))
            result = ledger.checkout(desktop, POLICY, NOW + 2 * DAY, 'TEST')
            self.assertEqual(result, 'manage_or_wait')
            self.assertEqual(ledger.charges, 0)

    def test_checkout_retry_unverified_results_and_unknown_region(self):
        ledger = Ledger()
        client = Client('desktop')
        self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST'), 'sign_in')
        client.sign_in(ledger, ACCOUNT)
        self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST', reconcile=False), 'verification_required')
        self.assertEqual(ledger.checkout(client, POLICY, NOW, 'US'), 'region_disabled')
        first = ledger.checkout(client, POLICY, NOW, 'TEST')
        for adapter in ('browser-return', 'forged', 'unverified'):
            self.assertFalse(ledger.ingest(evidence('lifetime'), adapter=adapter))
            client.sync(ledger, POLICY, NOW)
            self.assertFalse(client.access(POLICY, NOW))
            self.assertEqual(ledger.checkout(client, POLICY, NOW, 'TEST'), first)
        self.assertEqual(ledger.charges, 1)

    def test_future_linked_state_does_not_change_checkout_before_observation(self):
        for state in ('pending', 'hold', 'grace', 'expired'):
            ledger, _, desktop = setup(evidence(state, renewing=True, grace_end=NOW + DAY, verified_at=NOW + 1))
            self.assertEqual(ledger.checkout(desktop, POLICY, NOW, 'TEST'), 'fixture-attempt-1')
            self.assertEqual(ledger.charges, 1)

    def test_future_revision_retains_visible_shared_access_and_checkout_blockers(self):
        for source in ('apple', 'web', 'play', 'microsoft'):
            for state, expected in (('active', 'already_pro'), ('hold', 'manage_or_wait')):
                ledger, _, desktop = setup(evidence(state, source=source))
                ledger.ingest(evidence('expired', 2, source=source, verified_at=NOW + 10),
                              adapter='synthetic-verified')
                self.assertEqual(ledger.checkout(desktop, POLICY, NOW, 'TEST'), expected)
                self.assertEqual(ledger.charges, 0)
                self.assertEqual(ledger.checkout(desktop, POLICY, NOW + 10, 'TEST'), 'fixture-attempt-1')

    def test_privacy_rejects_sensitive_fields_values_and_logs(self):
        ledger, _, _ = setup()
        sensitive = ('provider_credentials', 'account_labels', 'balances', 'usage', 'history')
        for field in sensitive:
            self.assertFalse(ledger.ingest({**evidence(), field: 'PRIVATE-SENTINEL'}, adapter='synthetic-verified'))
            self.assertFalse(ledger.ingest({'error': 'PRIVATE-SENTINEL'}, adapter='redirect'))
        for field in ('chain', 'source', 'state', 'expires', 'revision'):
            self.assertFalse(ledger.ingest({**evidence(), field: 'PRIVATE-SENTINEL'}, adapter='synthetic-verified'))
        self.assertFalse(ledger.bind(('apple', 'fixture-1'), 'PRIVATE-SENTINEL'))
        serialized = json.dumps(ledger.billing_payload())
        self.assertNotIn('PRIVATE-SENTINEL', serialized)
        for field in sensitive:
            self.assertNotIn(field, serialized)
        self.assertEqual(set(ledger.billing_payload()), {'events', 'bindings', 'deleted', 'errors'})
        self.assertTrue(all(set(e) == {'code'} for e in ledger.errors))

    def test_malformed_events_cannot_create_grants(self):
        for invalid in (None, False, [], {}, {**evidence(), 'expires': True},
                        {**evidence(), 'verified_at': -1}, {**evidence(), 'revision': 1.1}):
            ledger = Ledger()
            self.assertFalse(ledger.ingest(invalid, adapter='synthetic-verified'))
            self.assertEqual(ledger.events, {})


if __name__ == '__main__':
    unittest.main(verbosity=2)
