"""Apple-local #477 simulator with explicitly excluded sharing hypotheticals.

No network, store SDK, secrets or production adapter.
"""
from dataclasses import asdict, dataclass, field, replace
import json
import re

DAY = 86400
STATES = frozenset({'pending', 'trial', 'active', 'renewal', 'canceled', 'expired',
                    'grace', 'hold', 'refunded', 'revoked', 'lifetime', 'original'})
DENIED = frozenset({'pending', 'expired', 'hold', 'refunded', 'revoked'})
PERMANENT = frozenset({'lifetime', 'original'})
SOURCES = frozenset({'apple', 'web', 'play', 'microsoft'})


@dataclass(frozen=True)
class Proposal:
    """Explicit candidates, never approval. Apple-local constants are separate."""
    shared: bool
    share_original: bool
    share_lifetime: bool
    subscription_allowance: int
    lifetime_lease: int
    grace_access: bool
    synthetic_regions: frozenset[str]
    label: str = 'UNAPPROVED PROPOSAL'

    def __post_init__(self):
        if (type(self.subscription_allowance) is not int or self.subscription_allowance < 0
                or type(self.lifetime_lease) is not int or self.lifetime_lease <= 0
                or self.label != 'UNAPPROVED PROPOSAL'):
            raise ValueError('invalid_proposal')


@dataclass(frozen=True)
class Event:
    source: str
    chain: str
    revision: int
    state: str
    expires: int | None
    grace_end: int | None
    renewing: bool
    verified_at: int

    @property
    def key(self):
        return self.source, self.chain

    @classmethod
    def fixture(cls, payload):
        """Trusted fixture boundary only. This does NOT verify merchant evidence."""
        if type(payload) is not dict or set(payload) != set(cls.__dataclass_fields__):
            raise ValueError('invalid_billing_schema')
        event = cls(**payload)
        if (event.source not in SOURCES or event.state not in STATES
                or type(event.chain) is not str or re.fullmatch(r'fixture-[0-9]{1,12}', event.chain) is None
                or len(event.chain) > 80 or type(event.revision) is not int or event.revision < 0
                or type(event.verified_at) is not int or event.verified_at < 0
                or type(event.renewing) is not bool
                or any(x is not None and (type(x) is not int or x < 0)
                       for x in (event.expires, event.grace_end))
                or (event.state not in PERMANENT | DENIED and event.expires is None)
                or (event.state == 'grace' and event.grace_end is None)):
            raise ValueError('invalid_billing_event')
        return event


@dataclass
class Ledger:
    events: dict = field(default_factory=dict)
    observations: dict = field(default_factory=dict)
    owners: dict = field(default_factory=dict)
    generations: dict = field(default_factory=dict)
    deleted: set = field(default_factory=set)
    attempts: dict = field(default_factory=dict)
    charges: int = 0
    errors: list = field(default_factory=list)

    def ingest(self, payload, *, adapter='unverified'):
        # Only named, explicit synthetic adapters can publish fixture evidence.
        if adapter != 'synthetic-verified':
            self.errors.append({'code': 'unverified_result'})
            return False
        try:
            event = Event.fixture(payload)
        except (ValueError, TypeError):
            self.errors.append({'code': 'invalid_billing_event'})
            return False
        # Retain even late lower revisions and equal-revision observations.
        # Arrival order must not erase evidence visible at an earlier time.
        records = self.observations.setdefault(event.key, [])
        if event not in records:
            records.append(event)
        old = self.events.get(event.key)
        if old and event.revision == old.revision:
            # Verification time is an observation, not signed entitlement state.
            if replace(event, verified_at=old.verified_at) == old:
                self.events[event.key] = replace(old, verified_at=max(old.verified_at, event.verified_at))
                return False
            # Equal-revision contradictory evidence is denied deterministically.
            self.events[event.key] = Event(event.source, event.chain, event.revision,
                                           'revoked', None, None, False,
                                           max(old.verified_at, event.verified_at))
            self.errors.append({'code': 'conflicting_revision'})
            return False
        if old and event.revision <= old.revision:
            return False
        self.events[event.key] = event
        return True

    def visible_events(self, now):
        """Highest observed revision per present chain, independent of arrival order."""
        visible = {}
        for key, latest in self.events.items():
            records = [e for e in self.observations.get(key, [latest]) if e.verified_at <= now]
            if not records:
                continue
            revision = max(e.revision for e in records)
            current = [e for e in records if e.revision == revision]
            observed = max(current, key=lambda e: e.verified_at)
            if any(replace(e, verified_at=observed.verified_at) != observed for e in current):
                observed = replace(observed, state='revoked', expires=None, grace_end=None, renewing=False)
            visible[key] = observed
        return visible

    def bind(self, key, account):
        if (type(account) is not str or re.fullmatch(r'fixture-account-[0-9]{1,12}', account) is None
                or key not in self.events or account in self.deleted):
            return False
        owner = self.owners.get(key)
        if owner is not None and owner != account:
            self.errors.append({'code': 'account_conflict'})
            return False
        self.owners[key] = account
        return True

    def delete(self, account):
        self.deleted.add(account)
        self.generations[account] = self.generations.get(account, 0) + 1
        # Retain chain binding tombstones to prevent account-deletion claim theft.
        self.attempts = {k: v for k, v in self.attempts.items() if k[0] != account}

    def recover(self, account, key, *, adapter='unverified'):
        # Candidate recovery requires fresh ownership proof, not a redirect/email.
        if (adapter != 'synthetic-verified' or account not in self.deleted
                or self.owners.get(key) != account):
            return False
        self.deleted.remove(account)
        return True

    def checkout(self, client, policy, now, region, *, reconcile=True):
        """Returns a local simulated attempt. Cannot call or enable real checkout."""
        if client.account is None or client.account in self.deleted:
            return 'sign_in'
        if client.generation != self.generations.get(client.account, 0):
            return 'session_revoked'
        if region not in policy.synthetic_regions:
            return 'region_disabled'
        if not reconcile:
            return 'verification_required'
        if not client.sync(self, policy, now):
            return 'verification_required'
        if client.access(policy, now):
            return 'already_pro'
        linked = [e for k, e in self.visible_events(now).items()
                  if self.owners.get(k) == client.account and e.verified_at <= now]
        if any(e.state == 'pending' or (e.renewing and e.state not in {'refunded', 'revoked'})
               or e.state in {'hold', 'grace'} for e in linked):
            return 'manage_or_wait'
        key = (client.account, 'hypothetical-checkout')
        if key in self.attempts:
            return self.attempts[key]
        self.charges += 1
        attempt = f'fixture-attempt-{self.charges}'
        self.attempts[key] = attempt
        return attempt

    def checkout_apple_local(self, client, now, *, reconciled=True, product="subscription", entry="paywall"):
        """Apple-local simulated purchase, account-free. Never invokes StoreKit."""
        if client.platform != 'apple':
            return 'unsupported_platform'
        if product not in {'subscription', 'lifetime'} or entry not in {'paywall', 'settings'}:
            return 'unsupported_purchase_intent'
        if (not client.has_store_identity or not reconciled
                or not client.sync(self, None, now)):
            return 'verification_required'
        local = [e for k, e in self.visible_events(now).items()
                 if k in client.local_keys and e.source == 'apple' and e.verified_at <= now]
        has_access = client.access(None, now)
        # Only Settings permits a paid-through subscriber's intentional lifetime transition.
        switch_to_lifetime = (product == 'lifetime' and entry == 'settings'
                              and any(e.state in {'active', 'trial', 'renewal', 'canceled'}
                                      and e.expires is not None and now < e.expires for e in local)
                              and not any(e['deadline'] is None for e in client.cache))
        if has_access and not switch_to_lifetime:
            return 'already_pro'
        if any(e.state in {'pending', 'hold', 'grace'}
               or (e.renewing and e.state not in {'refunded', 'revoked'}) for e in local):
            return 'manage_or_wait'
        key = ('apple-local', client.store_fixture)
        if key not in self.attempts:
            self.charges += 1
            self.attempts[key] = f'fixture-attempt-{self.charges}'
        return self.attempts[key]

    def complete_apple_attempt(self, client, attempt, *, adapter='unverified'):
        # Only a fixture adapter can reconcile an attempt, never a browser return.
        key = ('apple-local', client.store_fixture)
        if (not client.has_store_identity or adapter != 'synthetic-verified'
                or self.attempts.get(key) != attempt):
            return False
        del self.attempts[key]
        return True

    def billing_payload(self):
        # Fixed allowlist; no arbitrary metadata or exception text is serialized.
        return {'events': [asdict(e) for _, e in sorted(self.events.items())],
                'bindings': [{'source': k[0], 'chain': k[1], 'account': a}
                             for k, a in sorted(self.owners.items())],
                'deleted': sorted(self.deleted), 'errors': self.errors}


@dataclass
class Client:
    platform: str
    account: str | None = None
    store_fixture: str | None = None
    generation: int = 0
    local_keys: set = field(default_factory=set)
    cache: list = field(default_factory=list)
    high_water: int = 0

    @property
    def has_store_identity(self):
        return (self.platform == 'apple' and type(self.store_fixture) is str
                and re.fullmatch(r'fixture-store-[0-9]{1,12}', self.store_fixture) is not None)

    def switch_apple_store(self, identity, local_keys):
        if (self.platform != 'apple' or type(identity) is not str
                or re.fullmatch(r'fixture-store-[0-9]{1,12}', identity) is None):
            raise ValueError('invalid_store_fixture')
        self.store_fixture = identity
        self.local_keys = set(local_keys)
        self.cache = []

    def sign_in(self, ledger, account):
        self.account = account
        self.generation = ledger.generations.get(account, 0)
        self.cache = []

    def sign_out(self):
        self.account = None
        self.cache = []

    def sync(self, ledger, policy, now):
        if type(now) is not int or now < self.high_water:
            return False
        self.high_water = now
        # Missing evidence is not a revocation of an independently cached local lifetime grant.
        visible = ledger.visible_events(now)
        permanent = []
        for cached in self.cache:
            key = (cached['source'], cached['chain'])
            observed = visible.get(key)
            current = (observed is not None and observed.verified_at <= now
                       and observed.revision >= cached.get('revision', 0))
            revoked = current and observed.state in {'refunded', 'revoked'}
            if (self.platform == 'apple' and cached['source'] == 'apple'
                    and cached['deadline'] is None and key in self.local_keys and not revoked):
                cached = dict(cached)
                if current:
                    cached['revision'] = observed.revision
                permanent.append(cached)
        self.cache = permanent
        session = (self.account is not None and self.account not in ledger.deleted
                   and self.generation == ledger.generations.get(self.account, 0))
        for key, e in sorted(visible.items()):
            local = self.platform == 'apple' and e.source == 'apple' and key in self.local_keys
            shared = (policy is not None and session and policy.shared and ledger.owners.get(key) == self.account
                      and (e.state != 'original' or policy.share_original)
                      and (e.state != 'lifetime' or policy.share_lifetime))
            if not (local or shared) or e.state in DENIED or e.verified_at > now:
                continue
            if e.state == 'grace' and not local and not policy.grace_access:
                continue
            end = (max(e.expires or 0, e.grace_end or 0) if e.state == 'grace' else e.expires or 0)
            # Online expiry is authoritative. Offline allowance applies only to cached proof.
            if e.state not in PERMANENT and now >= end:
                continue
            if e.state in PERMANENT:
                deadline = None if local else now + policy.lifetime_lease
            else:
                deadline = end + (3 * DAY if local else policy.subscription_allowance)
            cached = next((c for c in self.cache
                           if (c['source'], c['chain']) == key and c['deadline'] is None), None)
            if cached is not None:
                if e.state in PERMANENT and e.revision >= cached.get('revision', 0):
                    cached.update(state=e.state, revision=e.revision)
            else:
                self.cache.append({'source': e.source, 'chain': e.chain,
                                   'state': e.state, 'deadline': deadline, 'revision': e.revision})
        return True

    def access(self, policy, now):
        # The approved Apple-local permanent promise has no clock deadline.
        if any(e['deadline'] is None for e in self.cache):
            if type(now) is int:
                self.high_water = max(self.high_water, now)
            return True
        if type(now) is not int or now < self.high_water:
            return False
        self.high_water = now
        return any(e['deadline'] is None or now < e['deadline'] for e in self.cache)

    def save(self):
        return json.dumps({**asdict(self), 'local_keys': sorted(self.local_keys)}, sort_keys=True)

    @classmethod
    def load(cls, value):
        data = json.loads(value)
        data['local_keys'] = {tuple(k) for k in data['local_keys']}
        return cls(**data)
