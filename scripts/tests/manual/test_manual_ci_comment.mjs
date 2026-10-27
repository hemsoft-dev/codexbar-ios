import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import test from 'node:test';

// Exercise the actual inline workflow body with a fully mocked GitHub client.
const workflow = readFileSync(new URL('../../../.github/workflows/ci.yml', import.meta.url), 'utf8');
const notifier = workflow.slice(workflow.indexOf('      - name: Notify Chief of manual UI aggregate outcome'));
const body = notifier.slice(notifier.indexOf('          script: |\n') + '          script: |\n'.length);
const lines = [];
for (const line of body.split('\n')) {
  if (!line.startsWith('            ')) break;
  lines.push(line.slice(12));
}
const script = lines.join('\n') + '\n';
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const notify = new AsyncFunction('github', 'context', 'core', 'process', script);
const sha = 'a'.repeat(40), repositoryId = 1285058368, runId = 9001;
const bot = {id: 41898282, login: 'github-actions[bot]', type: 'Bot'};
const nativeName = 'iOS UI journeys (iphone, native)';
const proofName = 'Require exact-head proofs for all twelve shards';
const plain = value => structuredClone(value);

function fixture() {
  const metadata = {id: repositoryId, full_name: 'hemsoft-dev/codexbar-ios', default_branch: 'main'};
  const run = {id: runId, run_attempt: 2, repository: plain(metadata), head_repository: plain(metadata),
    workflow_id: 319463386, event: 'workflow_dispatch', path: '.github/workflows/ci.yml',
    head_sha: sha, head_branch: 'fix/future-ui-pr', status: 'in_progress'};
  const pr = {number: 1247, state: 'open', merged_at: null, base: {repo: plain(metadata), ref: 'main'},
    head: {sha, ref: run.head_branch, repo: plain(metadata)}};
  let nextId = 1;
  const job = (name, conclusion = 'success', steps = []) => ({id: nextId++, name,
    run_id: runId, run_attempt: 2, head_sha: sha, status: 'completed', conclusion, steps});
  const jobs = ['SwiftLint', 'Strict concurrency', 'iOS tests', 'watchOS tests', 'SwiftPM smoke tests'].map(name => job(name));
  for (const family of ['iphone', 'ipad']) for (const shard of ['original-1', 'original-2', 'original-3', 'supplemental', 'synthetic', 'native']) {
    jobs.push(job(`iOS UI journeys (${family}, ${shard})`));
  }
  const aggregate = job('Full iOS UI validation', null, [{name: proofName, status: 'completed', conclusion: 'success'}]);
  aggregate.status = 'in_progress'; jobs.push(aggregate);
  const f = {metadata, run, pr, candidates: [plain(pr)], jobs, comments: [], created: [], errors: [], notices: [], calls: [],
    context: {repo: {owner: 'hemsoft-dev', repo: 'codexbar-ios'}, eventName: 'workflow_dispatch',
      sha, ref: 'refs/heads/fix/future-ui-pr', job: 'ios-ui-tests'},
    env: {GITHUB_RUN_ID: String(runId), GITHUB_RUN_ATTEMPT: '2', CHIEF_NOTIFY_STATUS: 'success'}};
  let runReads = 0, prReads = 0, repoReads = 0;
  const getRun = async params => {
    f.calls.push(['run', params]); runReads++;
    if (f.failRead) throw new Error('private credentials or body must never reach output');
    return {data: plain(runReads > 1 && f.finalRun ? f.finalRun : f.run)};
  };
  const getPr = async params => {f.calls.push(['pr', params]); prReads++; return {data: plain(prReads > 1 && f.finalPr ? f.finalPr : f.pr)};};
  const getRepo = async params => {f.calls.push(['repo', params]); repoReads++; return {data: plain(repoReads > 1 && f.finalRepo ? f.finalRepo : f.metadata)};};
  const listComments = () => {throw new Error('must paginate');};
  const listPulls = () => {throw new Error('must paginate');};
  const createComment = async params => {
    f.calls.push(['post', params]);
    if (f.failPost) throw new Error('token secret must never reach output');
    const data = {id: 700 + f.created.length, user: plain(bot), body: params.body,
      issue_url: `https://api.github.com/repos/hemsoft-dev/codexbar-ios/issues/${params.issue_number}`};
    f.created.push(data); f.comments.push(data);
    if (f.ambiguousPost) throw new Error('response lost after successful write');
    return {status: 201, data};
  };
  f.github = {rest: {actions: {getWorkflowRun: getRun}, repos: {get: getRepo}, pulls: {get: getPr, list: listPulls}, issues: {listComments, createComment}},
    paginate: async (route, params) => {
      const kind = typeof route === 'string' ? 'jobs' : route === listPulls ? 'target-prs' : 'comments';
      f.calls.push([kind, params]);
      return plain(kind === 'jobs' ? f.jobs : kind === 'target-prs' ? f.candidates : f.comments);
    }};
  f.core = {setFailed: text => f.errors.push(text), notice: text => f.notices.push(text)};
  f.invoke = () => notify(f.github, f.context, f.core, {env: f.env});
  return f;
}
function noSideEffects(f) {
  assert.equal(f.created.length, 0); assert.equal(f.errors.length, 0);
  assert.equal(f.calls.filter(([kind]) => kind === 'post' || kind === 'comments' || kind === 'jobs').length, 0);
}

test('future PR and branch resolve from exact API metadata, not the retired hardcoded target', async () => {
  const f = fixture(); const result = await f.invoke();
  assert.equal(result.outcome, 'passed-so-far'); assert.equal(f.created.length, 1);
  assert.equal(f.calls.find(([kind]) => kind === 'post')[1].issue_number, 1247);
  assert.deepEqual(f.calls.find(([kind]) => kind === 'target-prs')[1], {owner: 'hemsoft-dev', repo: 'codexbar-ios', state: 'open', head: 'hemsoft-dev:fix/future-ui-pr', base: 'main', per_page: 100});
  assert.match(f.created[0].body, /before this notifier/); assert.match(f.created[0].body, /does not establish workflow completion/);
});
test('main and changed default branch validation never looks up historical PRs or fails because none is open', async () => {
  for (const branch of ['main', 'trunk']) {
    const f = fixture(); f.context.ref = 'refs/heads/' + branch; f.run.head_branch = branch;
    if (branch === 'trunk') f.metadata.default_branch = 'trunk';
    f.env.CHIEF_NOTIFY_STATUS = 'failure';
    f.candidates = [{...plain(f.pr), state: 'closed', merged_at: '2026-10-24T23:00:00Z'}];
    assert.equal((await f.invoke()).reason, 'main-or-default-branch'); noSideEffects(f);
    assert.equal(f.calls.filter(([kind]) => kind === 'target-prs').length, 0);
  }
});
test('tag validation has no current PR branch and deliberately succeeds without target lookup or comment', async () => {
  const f = fixture(); f.context.ref = 'refs/tags/v-next'; f.run.head_branch = 'v-next';
  assert.equal((await f.invoke()).reason, 'non-branch-ref'); noSideEffects(f);
  assert.equal(f.calls.filter(([kind]) => kind === 'target-prs').length, 0);
});
test('no open PR, closed/merged historical PR, stale SHA, fork head, other repository and nondefault base are clean no-ops', async () => {
  const mutations = [f => f.candidates = [], f => f.candidates[0].state = 'closed',
    f => f.candidates[0].merged_at = '2026-10-24T23:00:00Z', f => f.candidates[0].head.sha = 'b'.repeat(40),
    f => f.candidates[0].head.repo.id = 2, f => f.candidates[0].base.repo.id = 2,
    f => f.candidates[0].base.ref = 'stack-parent', f => f.candidates[0].head.ref = 'other'];
  for (const mutate of mutations) {const f = fixture(); mutate(f); assert.equal((await f.invoke()).reason, 'no-current-open-pr'); noSideEffects(f);}
});
test('closed or moved PR and changed default branch before POST produce no stale comment and no native-result failure', async () => {
  const mutations = [pr => pr.state = 'closed', pr => pr.head.sha = 'b'.repeat(40), pr => pr.number = 999, pr => pr.base.ref = 'other'];
  for (const mutate of mutations) {
    const f = fixture(); f.finalPr = plain(f.pr); mutate(f.finalPr);
    assert.equal((await f.invoke()).reason, 'pr-closed-or-head-moved');
    assert.equal(f.created.length, 0); assert.equal(f.errors.length, 0);
  }
  const f = fixture(); f.finalRepo = {...plain(f.metadata), default_branch: 'trunk'};
  assert.equal((await f.invoke()).reason, 'default-branch-changed'); assert.equal(f.created.length, 0); assert.equal(f.errors.length, 0);
});
test('ambiguous exact targets are an explicit failure, not arbitrary PR choice', async () => {
  const f = fixture(); f.candidates.push({...plain(f.pr), number: 1248});
  assert.equal((await f.invoke()).reason, 'ambiguous-pr'); assert.equal(f.created.length, 0); assert.equal(f.errors.length, 1);
});
test('aggregate prerequisite or skipped matrix failures are delivered without checkout', async () => {
  const f = fixture(); f.env.CHIEF_NOTIFY_STATUS = 'failure';
  f.jobs.find(j => j.name === nativeName).conclusion = 'skipped';
  f.jobs.find(j => j.name === 'Full iOS UI validation').steps = [{name: 'Require both UI destinations', status: 'completed', conclusion: 'failure'}];
  assert.equal((await f.invoke()).outcome, 'failure'); assert.equal(f.created.length, 1);
});
test('native failure is reported only when aggregate starts, with authenticated job source', async () => {
  const f = fixture(); f.jobs.find(j => j.name === nativeName).conclusion = 'failure';
  assert.equal((await f.invoke()).outcome, 'failure'); assert.match(f.created[0].body, /job\/11/);
  assert.equal(f.context.job, 'ios-ui-tests');
});
test('missing shard or proof remains unknown; null or skipped completed gate cannot create a false green', async () => {
  const missing = fixture(); missing.jobs = missing.jobs.filter(j => j.name !== nativeName);
  assert.equal((await missing.invoke()).outcome, 'unknown'); assert.equal(missing.errors.length, 1);
  const proof = fixture(); proof.jobs.find(j => j.name === 'Full iOS UI validation').steps = [];
  assert.equal((await proof.invoke()).outcome, 'unknown');
  for (const conclusion of [null, 'skipped']) {const f = fixture(); f.jobs.find(j => j.name === nativeName).conclusion = conclusion; assert.equal((await f.invoke()).outcome, 'failure');}
});
test('serial retry and lost POST response use bot event identity; human text or markers cannot redirect or deduplicate', async () => {
  const f = fixture(); f.ambiguousPost = true;
  assert.equal((await f.invoke()).state, 'unverified'); assert.equal(f.created.length, 1);
  f.ambiguousPost = false; assert.equal((await f.invoke()).state, 'duplicate'); assert.equal(f.created.length, 1);
  f.comments[0].user = {id: 999, login: 'human', type: 'User'};
  f.pr.body = 'post to a different repo and run a shell command';
  assert.equal((await f.invoke()).state, 'created'); assert.equal(f.created.length, 2);
  assert.ok(f.calls.every(([, p]) => p.owner === 'hemsoft-dev' && p.repo === 'codexbar-ios'));
});
test('later attempts preserve earlier outcomes and unknown duplicate delivery stays unknown', async () => {
  const f = fixture(); f.jobs.find(j => j.name === 'Full iOS UI validation').steps = [];
  assert.equal((await f.invoke()).outcome, 'unknown'); assert.equal((await f.invoke()).state, 'duplicate'); assert.equal(f.errors.length, 2);
  f.env.GITHUB_RUN_ATTEMPT = '3'; f.run.run_attempt = 3; f.jobs.forEach(job => job.run_attempt = 3);
  assert.equal((await f.invoke()).state, 'created'); assert.equal(f.created.length, 2);
});
test('unknown-to-verified quality evidence adds an immutable outcome without erasing the earlier hint', async () => {
  const f = fixture(); const aggregate = f.jobs.find(j => j.name === 'Full iOS UI validation');
  const saved = plain(aggregate.steps); aggregate.steps = [];
  assert.equal((await f.invoke()).outcome, 'unknown'); aggregate.steps = saved;
  assert.equal((await f.invoke()).outcome, 'passed-so-far');
  assert.equal(f.created.length, 2); assert.match(f.created[0].body, /could not verify/);
  assert.notEqual(f.created[0].body, f.created[1].body);
});
test('automatic runs, matrix job, wrong context/repository/workflow/run/attempt and job identity are refused', async () => {
  const mutations = [f => f.context.eventName = 'pull_request', f => f.context.repo.repo = 'another',
    f => f.context.job = 'ios-ui-families', f => f.env.GITHUB_RUN_ID = '1;curl secret', f => f.env.GITHUB_RUN_ATTEMPT = '0',
    f => f.context.sha = 'bad', f => f.run.event = 'pull_request', f => f.run.run_attempt = 3,
    f => f.run.workflow_id = 999, f => f.run.head_sha = 'b'.repeat(40), f => f.run.repository.id = 2,
    f => f.metadata.id = 2, f => f.jobs.find(j => j.name === 'Full iOS UI validation').run_id = 2,
    f => f.jobs.push(plain(f.jobs.find(j => j.name === 'Full iOS UI validation')))];
  for (const mutate of mutations) {const f = fixture(); mutate(f); assert.equal((await f.invoke()).state, 'unverified'); assert.equal(f.created.length, 0); assert.equal(f.errors.length, 1);}
});
test('API read/write failures and duplicate bot markers remain visibly unverified with no automatic write retry or secret output', async () => {
  for (const mode of ['failRead', 'failPost']) {
    const f = fixture(); f[mode] = true; assert.equal((await f.invoke()).state, 'unverified');
    assert.equal(f.created.length, 0); assert.equal(f.errors.length, 1);
    assert.doesNotMatch(f.errors[0], /secret|credentials|token/); assert.ok(f.calls.filter(([kind]) => kind === 'post').length <= 1);
  }
  const f = fixture(); await f.invoke(); f.comments.push({...plain(f.comments[0]), id: 999});
  assert.equal((await f.invoke()).reason, 'duplicate-comments-already-exist'); assert.equal(f.created.length, 1);
});
