import { emptyFilter, parseXml, fromGmail, toXml, buildQuery, checkFilters, mergeFilters, normalizeProposal, validateProposal, describeActions, getReplacementPlan } from './filter-model.js';
import { DEFAULT_RULES, buildAnalysisRequest, callAI, getHealth } from './ai.js';
import { connectGoogle, readGoogleFilters, readInbox, signOutGoogle } from './gmail.js';

// Only the protected service is used. API keys belong in Cloudflare secrets.
const AI_URL = 'https://spiiira-filters-ai.jonas-spira.workers.dev';
const SETTINGS_KEY = 'spiiira.filters.settings.v11';
const $ = id => document.getElementById(id);
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const count = (n, noun) => `${n} ${noun}${n === 1 ? '' : 's'}`;
const initialSettings = () => {
  try {
    const value = JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}');
    return {provider:value.provider === 'anthropic' ? 'anthropic' : 'openai', accessCode:typeof value.accessCode === 'string' ? value.accessCode : '', rules:typeof value.rules === 'string' && value.rules.trim() ? value.rules : DEFAULT_RULES};
  } catch { return {provider:'openai', accessCode:'', rules:DEFAULT_RULES}; }
};
const state = {
  settings:initialSettings(), health:null, healthError:'', filters:[], source:'none', sourceName:'', connection:null,
  task:'review', fixMode:'paste', buildMode:'manual', findings:[], proposals:[], aiSummary:'', aiFindings:[], unmatched:[],
  emails:[], missed:{from:'',subject:'',listId:'',snippet:''}, idea:'', examples:'',
  draft:emptyFilter({source:'new'}), busy:false, scanning:false, connecting:false, expired:false,
  revision:0, sourceOp:0, controller:null, download:null, filterSearch:'', filterView:'all', showFilters:false
};
let expiryTimer;
function watchSessionExpiry(connection) {
  clearTimeout(expiryTimer);
  expiryTimer=setTimeout(()=>{
    if(state.connection!==connection)return;
    state.expired=true;state.emails=[];clearResults();renderSource();renderTask();
    if(state.source==='live')notify('Your Google sign-in expired. Click Sign in again to continue.');
  },Math.max(0,connection.expiresAt-Date.now()));
}

function notify(message, type='') {
  $('notice').textContent = message;
  $('notice').className = `notice ${type}`;
  $('notice').hidden = !message;
}
function report(error) {
  if (error.name === 'AbortError') return;
  if (error.name === 'GmailError' && error.status === 401) { state.expired = Boolean(state.connection); renderSource(); renderTask(); }
  notify(error.message || 'Something went wrong. Please try again.', 'error');
}
function saveSettings() {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(state.settings)); }
  catch { notify('This browser could not save Settings. They will work for this visit.'); }
}
function clearResults() {
  state.revision++;
  state.controller?.abort(); state.controller = null; state.busy = false; state.scanning = false;
  if(state.download?.url)URL.revokeObjectURL(state.download.url);
  state.proposals = []; state.aiSummary = ''; state.aiFindings = []; state.unmatched = []; state.download = null;
  renderResults(); $('download-panel').hidden = true;
}
function setSource(filters, source, name) {
  clearResults(); state.sourceOp++; state.filters = filters; state.source = source; state.sourceName = name;
  state.emails = []; state.filterSearch = ''; state.filterView = 'all'; state.findings = checkFilters(filters);
  state.showFilters = false; notify(''); renderSource(); renderTask();
}
function beginSourceLoad() { clearResults(); return ++state.sourceOp; }
function isLive() { return state.source === 'live' && state.connection && !state.expired && state.connection.expiresAt > Date.now(); }
function knownLabels() {
  return [...new Set([...state.filters.map(f => f.actions.label).filter(Boolean), ...(state.source === 'live' ? (state.connection?.labels || []).filter(l => l.type === 'user').map(l => l.name) : [])])].sort((a,b) => a.localeCompare(b));
}
function aiNote() {
  return `<p class="ai-note">Only when you click: your loaded filters, entered examples, and My rules go to ${state.settings.provider === 'anthropic' ? 'Anthropic' : 'OpenAI'} through your private connection. <button class="inline-link" data-action="settings">AI settings</button></p>`;
}
function renderSource() {
  $('source-heading').textContent = state.source === 'none' ? 'Start with your filters' : count(state.filters.length, 'filter') + ' ready to review';
  const label = {live:'Connected Gmail',xml:'Uploaded export',example:'Example data',none:''}[state.source];
  $('source-status').textContent = state.source === 'none' ? 'No filters loaded. You can still build a new one.' : `${label} · ${state.sourceName}`;
  $('connect').disabled = state.connecting;
  $('connect').textContent = state.connecting ? 'Connecting…' : state.expired ? 'Sign in again' : state.connection ? 'Reconnect Gmail' : 'Connect Gmail';
  const tools = $('source-tools'); tools.hidden = state.source === 'none' && !state.connection;
  tools.innerHTML = `<p>${state.source === 'live' ? 'Read-only access. Nothing changes in Gmail from this page.' : state.connection ? 'An export is active. Inbox scanning uses the connected Gmail only when you switch back.' : 'No sign-in needed. An AI review is optional.'}</p><div class="inline-actions">${state.source !== 'none' ? '<button class="quiet" data-action="backup">Download backup</button><button class="quiet" data-action="clear-source">Start fresh</button>' : ''}${state.connection ? `<button class="quiet" data-action="refresh">${state.source === 'live' ? 'Refresh filters' : 'Use connected Gmail'}</button><button class="quiet" data-action="signout">Disconnect</button>` : ''}</div>`;
}
function toggleSettings() {
  $('settings-panel').hidden = !$('settings-panel').hidden;
  $('settings-toggle').setAttribute('aria-expanded', String(!$('settings-panel').hidden));
  if (!$('settings-panel').hidden) { renderSettings(); $('settings-panel').scrollIntoView({block:'nearest'}); }
}
function renderSettings() {
  const s = state.settings;
  const providerMissing = provider => state.health && !state.health[provider] ? ' disabled' : '';
  $('settings-panel').innerHTML = `<div class="settings-head"><h2>Your connection & preferences</h2><button class="quiet" data-action="settings">Close</button></div><div class="settings-grid"><div><label for="provider">AI provider</label><select id="provider"><option value="openai"${s.provider === 'openai' ? ' selected' : ''}${providerMissing('openai')}>OpenAI${state.health && !state.health.openai ? ' — key not set' : ''}</option><option value="anthropic"${s.provider === 'anthropic' ? ' selected' : ''}${providerMissing('anthropic')}>Claude${state.health && !state.health.anthropic ? ' — key not set' : ''}</option></select><p class="field-hint">Your own API account. Subscriptions do not include API use.</p></div><div><label for="access-code">Access code</label><input id="access-code" type="password" autocomplete="off" value="${esc(s.accessCode)}" placeholder="Set in your Cloudflare connection"><p class="field-hint">Saved in this browser. Use a private browser profile.</p></div><div class="full"><label for="my-rules">My rules</label><textarea id="my-rules" rows="6">${esc(s.rules)}</textarea><p class="field-hint">Tell the AI what to keep, archive, label, or leave alone.</p></div></div><div class="status-line"><span>${state.health ? `Connection ready · ${state.health.openai ? 'OpenAI available' : 'OpenAI not configured'} · ${state.health.anthropic ? 'Claude available' : 'Claude not configured'}` : esc(state.healthError || 'AI connection has not been checked.')}</span><button class="quiet" data-action="health">Check connection</button></div><p class="field-hint">First setup? Follow the <a href="https://dash.cloudflare.com/" target="_blank" rel="noopener noreferrer">Cloudflare dashboard</a> steps in the local SETUP.md file. Work exports can be reviewed locally without AI.</p>`;
}
function emptyReview() {
  return `<div class="empty"><h3>A clearer picture starts here.</h3><p>Load a Gmail export or try the example to see duplicates, conflicts, and filters that could work together.</p><button class="secondary" data-action="example">Try the example</button></div>`;
}
function renderReview() {
  if (state.source === 'none') return emptyReview();
  const labels = knownLabels();
  const findings = reviewFindings();
  const issues = findings.filter(f => f.severity !== 'info');
  const actionCount = state.filters.filter(f => f.actions.trash).length;
  return `<div class="content-head"><div><h2>See what your filters are doing.</h2><p class="muted">These checks run in your browser. Ask AI for a closer review when you want suggested fixes.</p></div><button class="primary" data-action="analyze-review"${state.busy ? ' disabled' : ''}>${state.busy ? 'Reviewing…' : 'Suggest improvements'}</button></div>${aiNote()}<div class="stats"><div class="stat"><strong>${state.filters.length}</strong><span>filters loaded</span></div><div class="stat"><strong>${labels.length}</strong><span>labels used</span></div><div class="stat"><strong>${issues.length}</strong><span>things to check</span></div><div class="stat"><strong>${actionCount}</strong><span>delete rules</span></div></div><section class="panel"><h3>What stands out</h3>${findings.length ? findings.map(f => `<article class="finding"><span class="badge ${f.severity === 'error' ? 'error' : f.severity === 'warning' ? 'warning' : ''}">${esc(f.type.replaceAll('-', ' '))}</span><div><h3>${esc(f.title)}</h3><p>${esc(f.detail)}</p><p>Filter${f.positions.length === 1 ? '' : 's'} ${f.positions.slice(0,12).map(p => `#${p}`).join(', ')}${f.positions.length>12 ? ` and ${f.positions.length-12} more` : ''}</p></div>${canMerge(f) ? `<button class="secondary" data-action="merge" data-positions="${f.positions.join(',')}">Review merge</button>` : ''}</article>`).join('') : '<p class="muted spacer">No obvious rule problems found. AI can still check wording and suggest improvements.</p>'}</section>${renderFilterBrowser()}`;
}
function reviewFindings() {
  const groups=new Map();
  for(const finding of state.findings){
    if(finding.type==='sender-overlap')continue;
    const first=state.filters.find(f=>f.position===finding.positions[0]);
    const key=finding.type+(/merge|duplicate/.test(finding.type)?JSON.stringify([first?.actions,finding.type==='duplicate'?first?.criteria:null]):'');
    if(!groups.has(key))groups.set(key,{...finding,positions:[],details:[]});
    const group=groups.get(key);group.positions=[...new Set([...group.positions,...finding.positions])];
    if(!group.details.includes(finding.detail))group.details.push(finding.detail);
  }
  const list=[...groups.values()];
  return list.filter(group=>group.type!=='merge-candidate'||!list.some(other=>other.type==='duplicate'&&group.positions.every(p=>other.positions.includes(p)))).map(group=>({...group,positions:group.positions.sort((a,b)=>a-b),detail:group.details.slice(0,3).join(' ')+(group.details.length>3?' More observations are grouped here; browse the relevant filters below.':'')})).sort((a,b)=>(a.severity==='info')-(b.severity==='info'));
}
function canMerge(finding) {
  if (finding.positions.length < 2) return false;
  try { mergeFilters(state.filters.filter(f => finding.positions.includes(f.position))); return /merge|duplicate|consolidat/i.test(finding.type + finding.title); } catch { return false; }
}
function renderFilterBrowser() {
  const labels = knownLabels();
  const groups = labels.map(name => ({name,n:state.filters.filter(f => f.actions.label === name).length})).sort((a,b)=>b.n-a.n);
  return `<details class="filter-list panel" id="filter-browser"${state.showFilters ? ' open' : ''}><summary>Browse filters & labels</summary>${groups.length ? `<div class="label-bars">${groups.map(g=>`<div class="label-bar"><span title="${esc(g.name)}">${esc(g.name)}</span><meter min="0" max="${Math.max(...groups.map(g=>g.n))}" value="${g.n}" aria-label="${esc(g.name)}: ${count(g.n,'filter')}"></meter><span>${g.n}</span></div>`).join('')}</div>` : ''}<div class="toolbar"><label class="full" for="filter-search">Find a filter</label><input id="filter-search" type="search" value="${esc(state.filterSearch)}" placeholder="Search sender, query, or label"><label for="filter-view" hidden>Show actions</label><select id="filter-view"><option value="all">All filters</option><option value="trash"${state.filterView === 'trash' ? ' selected' : ''}>Delete rules</option><option value="archive"${state.filterView === 'archive' ? ' selected' : ''}>Archive rules</option><option value="unlabeled"${state.filterView === 'unlabeled' ? ' selected' : ''}>Without a label</option></select></div><div id="filter-rows">${filterRows()}</div></details>`;
}
function filterRows() {
  const list = state.filters.filter(f => (!state.filterSearch || `${buildQuery(f)} ${describeActions(f)}`.toLowerCase().includes(state.filterSearch.toLowerCase())) && (state.filterView === 'all' || state.filterView === 'unlabeled' ? state.filterView === 'all' || !f.actions.label : f.actions[state.filterView]));
  return list.length ? list.map(f => `<details class="filter-row"><summary><span>#${f.position} · ${esc(f.actions.label || (f.actions.trash ? 'Delete' : 'No label'))}</span><span class="muted">${esc(buildQuery(f).slice(0,85))}${buildQuery(f).length > 85 ? '…' : ''}</span></summary><code class="query">${esc(buildQuery(f)) || '(No criteria)'}</code><p>${esc(describeActions(f))}</p>${(f.warnings || []).map(w=>`<p class="proposal-warning">${esc(w)}</p>`).join('')}${queryLink(buildQuery(f))}</details>`).join('') : '<p class="muted spacer">No filters match that search.</p>';
}
function field(id, label, value='', placeholder='', full=false, type='text') {
  return `<div class="field${full ? ' full' : ''}"><label for="${id}">${label}</label><input id="${id}" type="${type}" value="${esc(value)}" placeholder="${esc(placeholder)}"></div>`;
}
function renderDiagnose() {
  return `<div class="content-head"><div><h2>Why did this email slip through?</h2><p class="muted">Bring one missed email, or check a small batch from your personal inbox. The result suggests changes to your existing filters first.</p></div></div><div class="mode-switch" aria-label="Email source"><button data-action="fix-mode" data-mode="paste" class="${state.fixMode === 'paste' ? 'active' : ''}">Enter an email</button><button data-action="fix-mode" data-mode="inbox" class="${state.fixMode === 'inbox' ? 'active' : ''}">Read inbox</button></div><div class="panel">${state.fixMode === 'paste' ? `<form id="diagnose-form"><div class="form-grid">${field('missed-from','Sender',state.missed.from,'billing@example.com')}${field('missed-subject','Subject',state.missed.subject,'The subject exactly as it arrived')}<div class="field full"><label for="missed-snippet">What happened? / Optional message excerpt</label><textarea id="missed-snippet" rows="3" placeholder="It stayed in the inbox instead of going to Bills…">${esc(state.missed.snippet)}</textarea></div></div><details><summary>Mailing-list header (optional)</summary>${field('missed-listId','List-Id',state.missed.listId,'Only if the email has a List-Id header')}</details><div class="form-buttons"><button class="primary" type="submit"${state.busy ? ' disabled' : ''}>${state.busy ? 'Finding the gap…' : 'Find the gap'}</button></div></form>` : renderInbox()}${aiNote()}</div>`;
}
function renderInbox() {
  if (state.connection && (state.expired || state.connection.expiresAt<=Date.now())) return `<div class="empty"><h3>Sign in again to read your inbox.</h3><p>Your Google session has expired. The filters already loaded are still available.</p><button class="secondary" data-action="connect">Sign in again</button></div>`;
  if (!isLive()) return `<div class="empty"><h3>Use your connected personal Gmail.</h3><p>${state.connection ? 'Switch the filter source back to Gmail first, so the inbox and filters belong to the same account.' : 'Connect Gmail to read inbox examples. You can always enter a missed email without signing in.'}</p><button class="secondary" data-action="${state.connection ? 'refresh' : 'connect'}">${state.connection ? 'Use connected Gmail' : 'Connect Gmail'}</button></div>`;
  return `<div class="toolbar"><div><label for="inbox-kind">Which messages?</label><select id="inbox-kind"><option value="unread">Unread inbox</option><option value="all">All inbox</option></select></div><div><label for="inbox-limit">How many?</label><select id="inbox-limit"><option>25</option><option selected>50</option><option>100</option></select></div><button class="secondary" data-action="scan"${state.scanning || state.busy ? ' disabled' : ''}>${state.scanning ? 'Reading…' : 'Read inbox'}</button></div><p class="field-hint">Reads senders, subjects, selected headers, and a short excerpt. Nothing is changed or sent to AI yet.</p><div id="scan-progress" class="progress-wrap" hidden><label id="scan-progress-label" for="scan-meter">Reading inbox</label><progress id="scan-meter" max="100" value="0"></progress></div>${state.emails.length ? `<div class="sample-list">${state.emails.map((e,i)=>`<article class="sample-email"><p><strong>${i+1}. ${esc(e.subject || '(No subject)')}</strong></p><p class="muted">${esc(e.from)}</p></article>`).join('')}</div><button class="primary" data-action="analyze-inbox"${state.busy ? ' disabled' : ''}>${state.busy ? 'Finding fixes…' : `Find fixes for these ${count(state.emails.length,'email')}`}</button>` : '<p class="muted spacer">Read a batch first, then review the examples before asking AI.</p>'}`;
}
const actionOptions = [['archive','Archive (skip inbox)'],['markRead','Mark as read'],['star','Star'],['alwaysImportant','Always important'],['neverImportant','Never important'],['neverSpam','Never send to spam'],['trash','Delete']];
function renderBuild() {
  const f = state.draft;
  return `<div class="content-head"><div><h2>A place for the next email.</h2><p class="muted">Build a filter yourself, or describe a few rules and let AI draft them. Existing filters help it avoid duplicates.</p></div></div><div class="mode-switch" aria-label="Build method"><button data-action="build-mode" data-mode="manual" class="${state.buildMode === 'manual' ? 'active' : ''}">Build it myself</button><button data-action="build-mode" data-mode="idea" class="${state.buildMode === 'idea' ? 'active' : ''}">Describe what I want</button></div><section class="panel">${state.buildMode === 'manual' ? `<form id="build-form"><div class="form-grid">${field('build-from','From',f.criteria.from,'Sender address or domain')}${field('build-subject','Subject includes',f.criteria.subject,'Optional subject words')}</div><details><summary>More matching options</summary><div class="form-grid spacer">${field('build-to','To / Cc / Bcc',f.criteria.to,'Recipient address')}${field('build-hasTheWord','Has words / Gmail search',f.criteria.hasTheWord,'Exact phrases or Gmail operators')}${field('build-doesNotHaveTheWord','Does not have',f.criteria.doesNotHaveTheWord,'Words or a search to exclude')}<div class="field"><label for="build-size">Message size in bytes</label><div class="toolbar"><select id="build-sizeComparison"><option value="larger"${f.criteria.sizeComparison === 'larger' ? ' selected' : ''}>Larger than</option><option value="smaller"${f.criteria.sizeComparison === 'smaller' ? ' selected' : ''}>Smaller than</option></select><input id="build-size" type="number" min="1" step="1" value="${f.criteria.size ?? ''}" placeholder="Optional"></div></div></div><div class="inline-actions"><label class="check-label"><input id="build-hasAttachment" type="checkbox"${f.criteria.hasAttachment ? ' checked' : ''}>Has an attachment</label><label class="check-label"><input id="build-excludeChats" type="checkbox"${f.criteria.excludeChats ? ' checked' : ''}>Exclude chats</label></div><p class="field-hint">Use OR inside a field for alternatives. Different fields must all match.</p></details><div class="form-section"><h3>Then do this</h3><label for="build-label">Apply label</label><input id="build-label" list="known-labels" value="${esc(f.actions.label)}" placeholder="Choose an existing label or enter a new one"><datalist id="known-labels">${knownLabels().map(l=>`<option value="${esc(l)}"></option>`).join('')}</datalist><div class="actions-grid">${actionOptions.map(([key,label])=>`<label class="check-label"><input id="build-action-${key}" type="checkbox"${f.actions[key] ? ' checked' : ''}>${label}</label>`).join('')}</div><details><summary>Forwarding & category</summary><div class="form-grid spacer">${field('build-forwardTo','Forward to',f.actions.forwardTo,'A forwarding address already verified in Gmail','', 'email')}<div class="field"><label for="build-category">Categorize as</label><select id="build-category"><option value="">Leave unchanged</option>${[['CATEGORY_PERSONAL','Primary'],['CATEGORY_SOCIAL','Social'],['CATEGORY_PROMOTIONS','Promotions'],['CATEGORY_UPDATES','Updates'],['CATEGORY_FORUMS','Forums']].map(([v,n])=>`<option value="${v}"${f.actions.category===v?' selected':''}>${n}</option>`).join('')}</select></div></div></details></div><div class="form-section"><h3>Your Gmail search</h3><code id="build-query" class="query">${esc(buildQuery(f)) || 'Add a sender, subject, or another matching rule.'}</code><p id="build-action-summary" class="action-summary">${esc(describeActions(f))}</p><div class="form-buttons"><button class="primary" type="submit">Review filter</button><span id="build-search-link">${queryLink(buildQuery(f))}</span></div></div></form>` : `<form id="idea-form"><div class="field"><label for="build-idea">What would you like your filters to do?</label><textarea id="build-idea" rows="4" placeholder="Archive receipts and label them Receipts. Star bills. Leave personal messages alone.">${esc(state.idea)}</textarea></div><div class="field"><label for="build-examples">Example emails (optional)</label><textarea id="build-examples" rows="3" placeholder="One per line: sender@example.com | subject line">${esc(state.examples)}</textarea></div><button class="primary" type="submit"${state.busy ? ' disabled' : ''}>${state.busy ? 'Drafting…' : 'Draft filters'}</button>${aiNote()}</form>`}</section>`;
}
function renderTask() {
  for (const task of ['review','diagnose','build']) {
    $(`tab-${task}`).classList.toggle('active',state.task === task);
    if (state.task === task) $(`tab-${task}`).setAttribute('aria-current','page'); else $(`tab-${task}`).removeAttribute('aria-current');
  }
  $('task-content').innerHTML = state.task === 'review' ? renderReview() : state.task === 'diagnose' ? renderDiagnose() : renderBuild();
}
function queryLink(query) {
  if (!query) return '';
  // XML/work exports use Gmail's account chooser instead of assuming personal account 0.
  const account = state.source === 'live' && state.connection?.email ? `/u/?authuser=${encodeURIComponent(state.connection.email)}` : '/u/';
  return `<a href="https://mail.google.com/mail${account}#search/${encodeURIComponent(query)}" target="_blank" rel="noopener noreferrer" class="small">Preview in Gmail ↗</a>`;
}
function readBuildDraft() {
  const f = state.draft;
  for (const name of ['from','subject','to','hasTheWord','doesNotHaveTheWord']) f.criteria[name] = $(`build-${name}`)?.value || '';
  for (const name of ['hasAttachment','excludeChats']) f.criteria[name] = $(`build-${name}`)?.checked || false;
  f.criteria.size = $('build-size')?.value ? Number($('build-size').value) : null;
  f.criteria.sizeComparison = f.criteria.size ? $('build-sizeComparison').value : '';
  f.actions.label = $('build-label')?.value || '';
  for (const [key] of actionOptions) f.actions[key] = $(`build-action-${key}`)?.checked || false;
  f.actions.forwardTo = $('build-forwardTo')?.value || '';
  f.actions.category = $('build-category')?.value || '';
  $('build-query').textContent = buildQuery(f) || 'Add a sender, subject, or another matching rule.';
  $('build-action-summary').textContent = describeActions(f);
  $('build-search-link').innerHTML = queryLink(buildQuery(f));
}
function addProposals(proposals, {summary='', findings=[], unmatched=[], append=false}={}) {
  const cards = proposals.map(raw => {
    const normalized=normalizeProposal(raw,state.filters);
    const p=normalized && typeof normalized==='object' ? {...normalized} : {};
    const warnings = validateProposal(p,state.filters,state.emails);
    const positions=Array.isArray(p.replacesPositions)?p.replacesPositions:[];
    const blocking = !['new','fix','extend','merge'].includes(p.kind) || !Array.isArray(p.replacesPositions) || positions.some(n=>!state.filters.some(f=>f.position===n)) || !p.criteria || !p.actions || !buildQuery(emptyFilter(p)) || state.filters.some(f=>positions.includes(f.position) && (f.preservation?.blockers?.length || f.preservation?.xmlProperties?.length));
    p.replacesPositions=positions;p.exampleEmailIndexes=Array.isArray(p.exampleEmailIndexes)?p.exampleEmailIndexes.filter(Number.isInteger):[];
    p.kind=typeof p.kind==='string'?p.kind:'invalid';p.why=typeof p.why==='string'?p.why:'';
    return {proposal:p,warnings,selected:!warnings.length && !blocking,override:false,blocking};
  });
  state.proposals = append ? [...state.proposals,...cards] : cards;
  state.aiSummary = typeof summary==='string'?summary:'';
  state.aiFindings = findings.filter(f=>f && typeof f.message==='string').map(f=>({...f,positions:Array.isArray(f.positions)?f.positions.filter(Number.isInteger):[]}));
  state.unmatched = unmatched.filter(e=>e && Number.isInteger(e.emailIndex) && e.emailIndex>=0 && e.emailIndex<state.emails.length && typeof e.reason==='string' && typeof e.suggestion==='string');
  state.download = null; $('download-panel').hidden = true; renderResults();
  $('results').scrollIntoView({block:'start'});
}
function renderResults() {
  const show = state.proposals.length || state.aiSummary || state.aiFindings.length || state.unmatched.length;
  $('results').hidden = !show; if (!show) return;
  const selected = state.proposals.filter(c=>c.selected && (!c.warnings.length || c.override) && !c.blocking);
  $('results').innerHTML = `<div class="results-head"><div><p class="eyebrow">03 / REVIEW CHANGES</p><h2>You have the final say.</h2></div><button class="quiet" data-action="dismiss-results">Dismiss</button></div>${state.aiSummary ? `<p class="results-summary">${esc(state.aiSummary)}</p>` : ''}${state.aiFindings.length ? `<div class="result-findings">${state.aiFindings.map(f=>`<p>${esc(f.message)}${f.positions?.length ? ` (Filters ${f.positions.map(p=>'#'+p).join(', ')})` : ''}</p>`).join('')}</div>` : ''}${state.proposals.map((c,i)=> {
    const p = c.proposal, before = state.filters.filter(f => p.replacesPositions?.includes(f.position));
    const f = emptyFilter({criteria:p.criteria,actions:p.actions,source:'new'});
    return `<article class="proposal${c.selected ? ' selected' : ''}"><div class="proposal-top"><input type="checkbox" data-select="${i}" id="proposal-${i}" aria-label="Select proposal ${i+1}"${c.selected ? ' checked' : ''}${c.blocking || c.warnings.length && !c.override ? ' disabled' : ''}><div><span class="badge">${esc(p.kind || 'proposal')}</span><h3><label for="proposal-${i}">${esc(f.actions.label || (f.actions.trash ? 'Delete matching mail' : 'Filter without a label'))}${before.length ? ` · replaces ${before.map(f=>'#'+f.position).join(', ')}` : ' · new filter'}</label></h3></div></div><div class="proposal-body"><p>${esc(p.why || '')}</p><div class="comparison">${before.length ? `<div class="before"><p>Before</p>${before.map(f=>`<code class="query">${esc(buildQuery(f))}</code><span class="action-summary">${esc(describeActions(f))}</span>`).join('')}</div>` : ''}<div><p>${before.length ? 'After' : 'Matches'}</p><code class="query">${esc(buildQuery(f)) || '(No criteria)'}</code><span class="action-summary">${esc(describeActions(f))}</span></div></div>${queryLink(buildQuery(f))}${p.exampleEmailIndexes?.length ? `<p class="field-hint">Examples: ${p.exampleEmailIndexes.map(n=>`#${n+1}`).join(', ')}</p>` : ''}${c.warnings.length || c.blocking ? `<div class="proposal-warning">${c.warnings.map(w=>`<p>${esc(w)}</p>`).join('')}${c.blocking ? '<p>This proposal is incomplete or would lose an unsupported setting. It cannot be included.</p>' : `<label class="check-label"><input type="checkbox" data-override="${i}"${c.override ? ' checked' : ''}>I have reviewed these warnings; allow me to select this change.</label>`}</div>` : ''}</div></article>`;
  }).join('')}${state.unmatched.length ? `<details class="panel spacer"><summary>${count(state.unmatched.length,'email')} left without a filter change</summary>${state.unmatched.map(e=>`<p class="muted">Example #${esc(e.emailIndex+1)}: ${esc(e.reason)} — ${esc(e.suggestion)}</p>`).join('')}</details>` : ''}${state.proposals.length ? `<div class="review-bar"><div><strong>${count(selected.length,'change')} selected</strong><p>Nothing has changed in Gmail.</p></div><div><label for="export-mode">Download</label><select id="export-mode"><option value="changes">Changed & new filters only</option><option value="complete">Complete revised set</option></select></div><button class="primary" data-action="review-download"${selected.length ? '' : ' disabled'}>Review download</button></div>` : ''}`;
}
function reviewDownload() {
  const cards = state.proposals.filter(c=>c.selected && (!c.warnings.length || c.override) && !c.blocking);
  if (!cards.length) throw new Error('Select a change first.');
  const positions = cards.flatMap(c=>c.proposal.replacesPositions);
  if (new Set(positions).size !== positions.length) throw new Error('Two selected changes replace the same filter. Choose one change for each old filter.');
  const mode = $('export-mode').value;
  const plan = getReplacementPlan(state.filters,cards.map(c=>c.proposal));
  const filters = mode === 'complete' ? plan.filters : plan.changed;
  const xml = toXml(filters);
  if(state.download?.url)URL.revokeObjectURL(state.download.url);
  state.download = {xml, url:URL.createObjectURL(new Blob([xml],{type:'application/xml;charset=utf-8'})),filters, replaced:mode === 'complete' ? state.filters : plan.replaced,mode};
  renderDownload(); $('download-panel').scrollIntoView({block:'start'});
}
function renderDownload() {
  const plan = state.download; if (!plan) return;
  const labels = [...new Set(plan.filters.map(f=>f.actions.label).filter(Boolean))];
  const missing = state.source === 'live' ? labels.filter(l=>!state.connection.labels.some(x=>x.name===l)) : labels;
  $('download-panel').hidden = false;
  $('download-panel').innerHTML = `<p class="eyebrow">READY WHEN YOU ARE</p><h2>${plan.mode === 'complete' ? `Complete set: ${state.filters.length} → ${count(plan.filters.length,'filter')}` : `${count(plan.filters.length,'filter')} to import`}</h2><p class="muted">Gmail imports add filters. They do not update or replace the old ones.</p>${plan.replaced.length ? `<div class="delete-list"><h3>${plan.mode === 'complete' ? 'Back up, then delete all existing filters first' : 'Delete these old filters first'}</h3><p class="muted">${plan.mode === 'complete' ? 'This file includes unchanged filters too. Keep a backup before replacing the set.' : 'Find each one by its matching criteria and actions in Gmail Settings.'}</p>${plan.replaced.map(f=>`<div class="filter-row"><p><strong>#${f.position} · ${esc(f.actions.label || 'No label')}</strong></p><code class="query">Matches: ${esc(buildQuery(f))}</code><p>${esc(describeActions(f))}</p></div>`).join('')}</div>` : '<p class="muted spacer">New filters only. No old filters need to be deleted.</p>'}<div class="labels-list">Labels used: ${labels.length ? labels.map(esc).join(', ') : 'none'}.${missing.length ? `<br>${state.source === 'live' ? 'Not currently in this Gmail account' : 'Check these labels in the destination account'}: ${missing.map(esc).join(', ')}. Create any missing labels before importing.` : ''}</div><ol><li>In the correct Gmail account, open <strong>Settings → See all settings → Filters and Blocked Addresses</strong>.</li>${plan.replaced.length ? '<li>Download a backup. Find the old filters listed above, tick them, and click <strong>Delete</strong>.</li>' : ''}<li>At the bottom, choose <strong>Import filters → Choose file → Open file</strong>.</li><li>Review the filters and optionally tick <strong>Apply new filters to existing email</strong>. Then click <strong>Create filters</strong>.</li></ol><p class="field-hint">For forwarding, verify the destination in Gmail first. Search previews use your browser's Gmail; check the account before making changes.</p><div class="form-buttons"><a class="button primary" download="gmail-filters-reviewed.xml" href="${esc(plan.url)}">Save import file</a>${state.filters.length ? '<button class="secondary" data-action="backup">Download current backup</button>' : ''}</div>`;
}
function downloadFile(text,name) {
  const url=URL.createObjectURL(new Blob([text],{type:'application/xml;charset=utf-8'}));
  const a=document.createElement('a'); a.href=url; a.download=name;document.body.appendChild(a);a.click();a.remove();setTimeout(()=>URL.revokeObjectURL(url),30000);
}
async function loadXml(text,name) {
  if (new TextEncoder().encode(text).length > 5*1024*1024) throw new Error('This export is larger than 5 MB. Please export a smaller set of filters.');
  const filters=parseXml(text); setSource(filters,'xml',name); notify(`Loaded ${count(filters.length,'filter')}. Local checks are ready.`, 'success');
}
async function loadExample() {
  const operation=beginSourceLoad();
  const response=await fetch('./tests/fixtures/example.xml');
  if (!response.ok) throw new Error('The example could not be loaded. Try uploading an export.');
  const filters=parseXml(await response.text());
  if(operation!==state.sourceOp)return;
  setSource(filters,'example','Invented filters · safe to explore');
}
async function connect() {
  if (state.connecting) return;
  const operation=beginSourceLoad();
  state.connecting=true; renderSource(); notify('');
  try { const result=await connectGoogle(); if(operation!==state.sourceOp)return; const filters=fromGmail(result.filters,result.labels);state.connection=result; state.expired=false; setSource(filters,'live',result.email);watchSessionExpiry(state.connection); }
  finally {state.connecting=false;renderSource();}
}
async function refresh() {
  if (!state.connection || state.expired || state.connection.expiresAt <= Date.now()) return connect();
  const operation=beginSourceLoad();
  const result=await readGoogleFilters(state.connection.token);
  if(operation!==state.sourceOp)return;
  const filters=fromGmail(result.filters,result.labels);
  state.connection={...state.connection,...result};
  setSource(filters,'live',state.connection.email);watchSessionExpiry(state.connection);
}
async function checkHealth({signal}={}) {
  try {
    state.health = await getHealth(AI_URL,{signal}); state.healthError='';
  } catch {state.health=null;state.healthError='AI connection unavailable. Local filter checks and downloads still work. Follow SETUP.md to connect AI.';}
  if (!$('settings-panel').hidden) renderSettings();
}
async function analyze(mode,emails=[],issue='') {
  if (state.busy || state.scanning) return;
  if (!state.settings.accessCode && !isLive()) { if ($('settings-panel').hidden) toggleSettings(); throw new Error('Enter your access code in Settings to use AI.'); }
  if (mode !== 'starter' && !state.filters.length) throw new Error('Load your filters first so the AI can compare them with the email.');
  const revision=state.revision; const controller=new AbortController(); state.controller=controller;
  const filters=structuredClone(state.filters), settings={...state.settings}, examples=structuredClone(emails);
  const token=isLive()?state.connection.token:'';
  state.busy=true; state.emails=emails; renderTask(); notify('');
  try {
    if (!state.health) await checkHealth({signal:controller.signal});
    if (revision !== state.revision || controller.signal.aborted) return;
    if (!state.health) {if ($('settings-panel').hidden) toggleSettings();throw new Error(state.healthError);}
    if (!state.health[settings.provider]) throw new Error('This provider is not configured. Choose an available provider in Settings.');
    const request=buildAnalysisRequest({mode,filters,emails:examples,rules:settings.rules,issue});
    const result=await callAI({baseUrl:AI_URL,provider:settings.provider,accessCode:settings.accessCode,token,...request,signal:controller.signal});
    if (revision !== state.revision) return;
    const data=result.data;
    if (!data || !Array.isArray(data.proposals) || !Array.isArray(data.findings) || !Array.isArray(data.unmatched) || typeof data.summary !== 'string') throw new Error('The AI returned an incomplete answer. Please try again.');
    addProposals(data.proposals,{summary:data.summary,findings:data.findings,unmatched:data.unmatched});
  } finally { if (revision===state.revision) {state.busy=false; state.controller=null;renderTask();} }
}
async function scanInbox() {
  if(state.scanning || state.busy)return;
  if (!isLive()) throw new Error('Sign in again to read your personal inbox.');
  const limit=Number($('inbox-limit').value); const unreadOnly=$('inbox-kind').value==='unread';
  const revision=state.revision; const controller=new AbortController(); state.controller=controller; state.scanning=true; state.emails=[];renderTask();
  $('scan-progress').hidden=false;
  try {
    const emails=await readInbox(state.connection.token,{unreadOnly,limit,signal:controller.signal,onProgress:(done,total)=> {
      if (revision!==state.revision || !$('scan-meter')) return;
      $('scan-meter').max=total||1;$('scan-meter').value=done;$('scan-progress-label').textContent=`Reading ${done} of ${total}`;
    }});
    if (revision!==state.revision) return;state.emails=emails;
    if (!emails.length) notify('No matching inbox messages found.','success');
  } finally {if(revision===state.revision){state.scanning=false;state.controller=null;renderTask();}}
}
async function handleAction(action,button) {
  if (action==='settings') return toggleSettings();
  if (action==='health') return checkHealth();
  if (action==='example') return loadExample();
  if (action==='connect') return connect();
  if (action==='refresh') return refresh();
  if (action==='clear-source') return setSource([],'none','');
  if (action==='signout') {
    const token=state.connection?.token;clearTimeout(expiryTimer);state.sourceOp++;state.connection=null;state.expired=false;state.emails=[];
    if (state.source==='live') setSource([],'none',''); else {clearResults();renderSource();renderTask();}
    return signOutGoogle(token);
  }
  if (action==='backup') {downloadFile(toXml(state.filters),'gmail-filters-backup.xml');return;}
  if (action==='fix-mode') {state.fixMode=button.dataset.mode;renderTask();return;}
  if (action==='build-mode') {state.buildMode=button.dataset.mode;renderTask();return;}
  if (action==='analyze-review') return analyze('review');
  if (action==='scan') return scanInbox();
  if (action==='analyze-inbox') return analyze('diagnose',state.emails,'These messages remained in the inbox. Prefer extending the existing rules.');
  if (action==='merge') {
    const positions=button.dataset.positions.split(',').map(Number);
    const merged=mergeFilters(state.filters.filter(f=>positions.includes(f.position)));
    addProposals([{kind:'merge',replacesPositions:positions,criteria:merged.criteria,actions:merged.actions,exampleEmailIndexes:[],gmailSearchQuery:buildQuery(merged),why:'Same actions, with each original filter kept together as an AND group. Review the combined search before importing.'}],{summary:'A merge you can check without AI.',append:true});return;
  }
  if(action==='dismiss-results'){clearResults();return;}
  if(action==='review-download')return reviewDownload();
}
document.addEventListener('click',event=> {
  const button=event.target.closest('[data-action]');if(!button || button.disabled)return;
  Promise.resolve().then(()=>handleAction(button.dataset.action,button)).catch(report);
});
for(const task of ['review','diagnose','build']) $(`tab-${task}`).addEventListener('click',()=>{state.task=task;renderTask();});
$('settings-toggle').addEventListener('click',toggleSettings);
$('load-paste').addEventListener('click',()=>loadXml($('xml-paste').value,'Pasted export').catch(report));
$('connect').addEventListener('click',()=>connect().catch(report));
$('example').addEventListener('click',()=>loadExample().catch(report));
$('xml-file').addEventListener('change',async event=> {
  const file=event.target.files[0];if(!file)return;
  const operation=beginSourceLoad();
  try{if(file.size>5*1024*1024)throw new Error('Please choose an XML export under 5 MB.');const text=await file.text();if(operation===state.sourceOp)await loadXml(text,file.name);}catch(error){report(error);}finally{event.target.value='';}
});
document.addEventListener('input',event=> {
  const id=event.target.id;
  if(id==='provider'){state.settings.provider=event.target.value;saveSettings();renderTask();}
  if(id==='access-code'){state.settings.accessCode=event.target.value;saveSettings();}
  if(id==='my-rules'){state.settings.rules=event.target.value;saveSettings();}
  if(id==='filter-search'){state.filterSearch=event.target.value;$('filter-rows').innerHTML=filterRows();}
  if(id==='filter-view'){state.filterView=event.target.value;$('filter-rows').innerHTML=filterRows();}
  if(id.startsWith('build-') && $('build-form'))readBuildDraft();
  if(id==='build-idea')state.idea=event.target.value;
  if(id==='build-examples')state.examples=event.target.value;
  if(id.startsWith('missed-'))state.missed[id.slice(7)]=event.target.value;
});
document.addEventListener('change',event=> {
  const input=event.target;
  if(input.dataset.select!==undefined){state.proposals[Number(input.dataset.select)].selected=input.checked;renderResults();$('download-panel').hidden=true;state.download=null;}
  if(input.dataset.override!==undefined){const card=state.proposals[Number(input.dataset.override)];card.override=input.checked;if(!input.checked)card.selected=false;renderResults();$('download-panel').hidden=true;state.download=null;}
});
document.addEventListener('toggle',event=>{if(event.target.id==='filter-browser')state.showFilters=event.target.open;},true);
document.addEventListener('submit',event=> {
  event.preventDefault();notify('');
  Promise.resolve().then(async()=> {
    if(event.target.id==='build-form'){
      readBuildDraft();
      const f=state.draft;if(!buildQuery(f))throw new Error('Add at least one matching rule first.');
      if(!Object.values(f.actions).some(Boolean))throw new Error('Choose a label or at least one action.');
      addProposals([{kind:'new',replacesPositions:[],criteria:{...f.criteria},actions:{...f.actions},exampleEmailIndexes:[],gmailSearchQuery:buildQuery(f),why:'Built by you. Preview the matching messages before importing.'}]);
    }
    if(event.target.id==='diagnose-form'){
      const e={...state.missed};if(!e.from.trim()&&!e.subject.trim())throw new Error('Enter a sender or subject first.');
      await analyze('diagnose',[e],e.snippet);
    }
    if(event.target.id==='idea-form'){
      if(!state.idea.trim())throw new Error('Describe the filter rules you want first.');
      const emails=state.examples.split('\n').filter(x=>x.trim()).map(line=>{const [from,...rest]=line.split('|');return {from:from.trim(),subject:rest.join('|').trim(),listId:'',snippet:''};});
      await analyze('starter',emails,state.idea);
    }
  }).catch(report);
});
window.addEventListener('pagehide',()=>{
  clearTimeout(expiryTimer);state.connection=null;state.missed={from:'',subject:'',listId:'',snippet:''};state.idea='';state.examples='';state.draft=emptyFilter({source:'new'});$('xml-paste').value='';setSource([],'none','');
});
window.addEventListener('pageshow',event=>{if(event.persisted){renderSource();renderTask();}});
renderSource();renderTask();
