import { describeActions, buildQuery } from './filter-model.js';
import { cloneForEditing, applyCriteriaEdit, getGmailFieldValues, getSenderTarget, extendFilterSenders } from './filter-editor.js';

const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
const textFields = [['from','From'],['to','To'],['subject','Subject'],['hasTheWord','Has the words'],['doesNotHaveTheWord',"Doesn't have"]];
const actions = [['archive','Skip the Inbox (Archive it)'],['markRead','Mark as read'],['star','Star it'],['trash','Delete it'],['neverSpam','Never send it to Spam'],['alwaysImportant','Always mark it as important'],['neverImportant','Never mark it as important']];
const categories = [['CATEGORY_PERSONAL','Primary'],['CATEGORY_SOCIAL','Social'],['CATEGORY_PROMOTIONS','Promotions'],['CATEGORY_UPDATES','Updates'],['CATEGORY_FORUMS','Forums']];

export function createFilterEditor({ notify, queryLink }) {
  let originals = [], selected = '', search = '';
  const drafts = new Map(), additions = new Map(), errors = new Map(), invalidSizes = new Map();
  const $ = id => document.getElementById(id);
  const original = () => originals.find(f => f.key === selected);
  const draft = () => drafts.get(selected);
  const changed = key => {
    const before = originals.find(f => f.key === key), after = drafts.get(key);
    return before && after && JSON.stringify([before.criteria,before.actions]) !== JSON.stringify([after.criteria,after.actions]);
  };
  function setFilters(filters) {
    originals = filters.map(cloneForEditing); drafts.clear(); additions.clear(); errors.clear(); invalidSizes.clear();
    for (const filter of originals) drafts.set(filter.key,cloneForEditing(filter));
    selected = originals[0]?.key || ''; search = '';
  }
  function matchingFilters() {
    const term = search.trim().toLowerCase();
    return originals.filter(f => !term || `${f.position} ${describeActions(f)} ${Object.values(f.criteria).join(' ')}`.toLowerCase().includes(term));
  }
  function renderList() {
    const matches = matchingFilters();
    return matches.length ? matches.map(f => `<button type="button" class="editor-filter${selected===f.key?' active':''}" data-editor-action="select" data-editor-key="${esc(f.key)}" aria-pressed="${selected===f.key}"><span class="editor-filter-name">${esc(f.actions.label || (f.actions.trash?'Delete matching mail':'Filter without a label'))}<small>#${f.position}${changed(f.key)?' · Edited':''}</small></span><span class="editor-filter-rule">${esc(f.criteria.from || f.criteria.hasTheWord || buildQuery(f))}</span></button>`).join('') : '<p class="muted spacer">No matching filters.</p>';
  }
  function renderCriterion(key,label,{rows=2}={}) {
    return `<div class="field"><label for="edit-${key}">${esc(label)}</label><textarea id="edit-${key}" rows="${rows}" data-editor-criterion="${key}" spellcheck="false">${esc(draft().criteria[key])}</textarea></div>`;
  }
  function renderActions() {
    const a = draft().actions;
    const known = categories.some(([key])=>key===a.category);
    return `<details class="editor-actions"><summary>Actions · <span id="editor-action-summary">${esc(describeActions(draft()))}</span></summary><p class="field-hint">These stay as they are unless you change them. Check them on Gmail's next screen.</p><div class="form-grid spacer"><div class="field"><label for="edit-label">Apply the label</label><input id="edit-label" data-editor-action-field="label" value="${esc(a.label)}"></div><div class="field"><label for="edit-forwardTo">Forward to</label><input id="edit-forwardTo" data-editor-action-field="forwardTo" value="${esc(a.forwardTo)}"></div></div><div class="actions-grid">${actions.map(([key,label])=>`<label class="check-label"><input type="checkbox" data-editor-action-field="${key}"${a[key]?' checked':''}>${label}</label>`).join('')}</div><label for="edit-category">Categorize as</label><select id="edit-category" data-editor-action-field="category"><option value="">No category action</option>${a.category&&!known?`<option value="${esc(a.category)}" selected>${esc(a.category)}</option>`:''}${categories.map(([key,label])=>`<option value="${key}"${a.category===key?' selected':''}>${label}</option>`).join('')}</select></details>`;
  }
  const senderHint = target => target.field==='hasTheWord' ? 'Adds to the sender rule in Has the words.' : target.field ? 'Adds alternatives using OR. Other fields stay in place.' : target.reason;
  function renderForm() {
    const f = draft(), target = getSenderTarget(f), c = f.criteria;
    return `<div class="editor-heading"><div><p class="eyebrow">02 / CONFIGURE</p><h2>${esc(original().actions.label || 'Edit this filter')} <span class="muted">#${f.position}</span></h2></div><button type="button" class="quiet" data-editor-action="reset">Reset changes</button></div>
      <section class="editor-add"><label for="edit-additions">Add senders or domains</label><p class="muted">Keep this filter growing as new senders appear. Add one per line, or separate them with commas.</p><textarea id="edit-additions" rows="2" placeholder="jira.example.com, alerts@example.net" spellcheck="false">${esc(additions.get(selected)||'')}</textarea><div class="inline-actions"><button type="button" class="primary" data-editor-action="add"${target.field?'':' disabled'}>Add to this filter</button><span id="editor-add-hint" class="field-hint">${esc(senderHint(target))}</span></div><p id="editor-feedback" class="editor-feedback" role="status"></p></section>
      ${renderCriterion('from','From')}
      <details class="editor-fields"${!target.field || errors.has(selected)?' open':''}><summary>Other matching fields${(() => {const n=textFields.slice(1).filter(([key])=>c[key]).length+Number(c.hasAttachment)+Number(c.excludeChats)+Number(c.size!=null);return n?` · ${n} set`:'';})()}</summary><div class="form-grid spacer">${renderCriterion('to','To')}${renderCriterion('subject','Subject')}</div>${renderCriterion('hasTheWord','Has the words')}${renderCriterion('doesNotHaveTheWord',"Doesn't have")}<div class="inline-actions"><label class="check-label"><input type="checkbox" data-editor-criterion="hasAttachment"${c.hasAttachment?' checked':''}>Has attachment</label><label class="check-label"><input type="checkbox" data-editor-criterion="excludeChats"${c.excludeChats?' checked':''}>Don't include chats</label></div><div class="editor-size spacer"><label for="edit-size">Size</label><select id="edit-sizeComparison" data-editor-criterion="sizeComparison"><option value="larger"${c.sizeComparison!=='smaller'?' selected':''}>Greater than</option><option value="smaller"${c.sizeComparison==='smaller'?' selected':''}>Less than</option></select><input id="edit-size" type="number" min="0" step="1" placeholder="Any size" value="${esc(invalidSizes.has(selected)?invalidSizes.get(selected):c.size??'')}" data-editor-criterion="size"><span class="muted">bytes</span></div></details>
      ${renderActions()}
      <section class="editor-copy" aria-labelledby="editor-copy-heading"><p class="eyebrow">03 / COPY BACK</p><h3 id="editor-copy-heading">Update this filter in Gmail</h3><p class="muted">Settings → See all settings → Filters and Blocked Addresses → <strong>Edit</strong> this filter. Paste each changed value into its matching field, then Continue → Update filter.</p><div id="editor-copy-area">${renderOutput()}</div></section>`;
  }
  function renderOutput() {
    const f = draft(), baseline = original(), values = getGmailFieldValues(f);
    const pending = Boolean((additions.get(selected)||'').trim());
    const invalid = errors.get(selected);
    const target = getSenderTarget(f);
    const changedKeys = textFields.filter(([key])=>f.criteria[key]!==baseline.criteria[key]).map(([key])=>key);
    const keys = changedKeys.length ? changedKeys : [target.field || 'from'];
    const primary = keys[0];
    const row = ([key,label]) => `<div class="editor-copy-row"><div class="editor-copy-label"><label for="copy-${key}">${esc(label)}${f.criteria[key]!==baseline.criteria[key]?' · changed':''}</label><button type="button" class="${key===primary?'primary':'secondary'}" data-editor-action="copy" data-editor-copy="${key}"${invalid||pending?' disabled':''}>Copy ${esc(label)}</button></div><textarea id="copy-${key}" rows="2" readonly spellcheck="false">${esc(values[key])}</textarea>${!values[key]?'<p class="field-hint">Leave this field empty in Gmail.</p>':''}</div>`;
    const criterionFlags = ['hasAttachment','excludeChats','size','sizeComparison'].filter(key=>f.criteria[key]!==baseline.criteria[key]);
    return `${pending?'<p class="editor-feedback">The new senders are not included yet. Click Add to this filter first.</p>':''}${invalid?`<p class="editor-feedback error">${esc(invalid)}</p>`:''}${values.warnings.map(w=>`<p class="field-hint">${esc(w)}</p>`).join('')}
      ${textFields.filter(([key])=>keys.includes(key)).map(row).join('')}
      <details class="editor-other-copy"><summary>Other field values</summary>${textFields.filter(([key])=>!keys.includes(key)).map(row).join('')}</details>
      ${criterionFlags.length?`<p class="field-hint">Also set: Has attachment ${f.criteria.hasAttachment?'on':'off'} · Don't include chats ${f.criteria.excludeChats?'on':'off'} · ${f.criteria.size==null?'no size restriction':`${esc(f.criteria.sizeComparison)} than ${f.criteria.size} bytes`}.</p>`:''}
      ${JSON.stringify(f.actions)!==JSON.stringify(baseline.actions)?`<p class="editor-action-change">On the next Gmail screen, set: ${esc(describeActions(f))}. Clear any old actions you removed above.</p>`:'<p class="field-hint">Keep this filter\'s existing actions on the next Gmail screen.</p>'}
      ${values.queryAvailable?`<details class="editor-search"><summary>Full search preview</summary><p class="field-hint">Use this in Gmail's search bar to check matches. The field values above are for editing the filter.</p><code class="query">${esc(values.query)}</code><div class="inline-actions"><button type="button" class="secondary" data-editor-action="copy" data-editor-copy="query"${invalid||pending?' disabled':''}>Copy search</button>${queryLink(values.query)}</div></details>`:''}`;
  }
  function render() {
    if (!originals.length) return `<section class="empty editor-empty"><h2>Keep the filters you already use.</h2><p>Upload your current Gmail XML above, then choose a filter to extend or adjust. Add Jira senders to Jira, Confluence senders to Confluence, and copy the updated fields back to Gmail.</p><p class="field-hint">No sign-in, AI request, or XML import back into Gmail is needed for an edit.</p></section>`;
    return `<div class="editor-workspace"><aside class="editor-picker panel" aria-label="Choose an existing filter"><p class="eyebrow">01 / CHOOSE A FILTER</p><label for="editor-search">Find a filter</label><input id="editor-search" type="search" value="${esc(search)}" placeholder="Jira, Confluence, label or sender"><div id="editor-list" class="editor-list">${renderList()}</div><p class="field-hint">Edits stay in this tab as you switch filters. Refreshing clears them.</p></aside><section class="editor-detail panel" id="editor-detail" aria-label="Configure existing filter">${renderForm()}</section></div>`;
  }
  function refreshOutput() {
    if (!$('editor-copy-area') || !draft()) return;
    $('editor-copy-area').innerHTML = renderOutput();
    $('editor-list').innerHTML = renderList();
    $('editor-action-summary').textContent = describeActions(draft());
    const target=getSenderTarget(draft());
    $('editor-add-hint').textContent=senderHint(target);
    $('editor-detail').querySelector('[data-editor-action="add"]').disabled=!target.field;
  }
  async function copyField(key, button) {
    const values = getGmailFieldValues(draft());
    if (errors.get(selected)) throw new Error(errors.get(selected));
    if ((additions.get(selected)||'').trim()) throw new Error('Add the new senders to this filter before copying.');
    if (key==='query'&&!values.queryAvailable) throw new Error('Copy the individual fields instead; this filter has other settings to keep in Gmail.');
    const text = values[key];
    if (typeof text !== 'string') return;
    try {
      await navigator.clipboard.writeText(text);
      button.textContent = 'Copied';
      setTimeout(()=>{if(button.isConnected)button.textContent=key==='query'?'Copy search':`Copy ${textFields.find(([name])=>name===key)?.[1]||key}`;},1800);
    } catch {
      const output = key==='query' ? null : $(`copy-${key}`);
      if (output) { output.focus(); output.select(); }
      notify('Copy is blocked by this browser. Select the text and press Ctrl+C (Command+C on a Mac).');
    }
  }
  document.addEventListener('input',event=> {
    const input = event.target;
    if (input.id==='editor-search') {search=input.value;$('editor-list').innerHTML=renderList();return;}
    if (!draft() || !$('editor-detail')) return;
    if (input.id==='edit-additions') {additions.set(selected,input.value);refreshOutput();return;}
    const criterion = input.dataset.editorCriterion, action = input.dataset.editorActionField;
    if (!criterion && !action) return;
    try {
      if (criterion) {
        let value = input.type==='checkbox' ? input.checked : input.value;
        let patch = {[criterion]:value};
        if (criterion==='size') {
          if (input.validity.badInput || input.value && !input.validity.valid) throw new Error('Enter a whole, non-negative size in bytes.');
          patch = {size:input.value===''?null:Number(input.value),sizeComparison:input.value===''?'':$('edit-sizeComparison').value};
        }
        if (criterion==='sizeComparison' && draft().criteria.size==null) return;
        drafts.set(selected,applyCriteriaEdit(draft(),patch));
      }
      if (action) draft().actions[action] = input.type==='checkbox' ? input.checked : input.value;
      if (criterion==='size') {errors.delete(selected);invalidSizes.delete(selected);}
      refreshOutput();
    } catch (error) { errors.set(selected,error.message);if(criterion==='size')invalidSizes.set(selected,input.value);refreshOutput(); }
  });
  document.addEventListener('click',event=> {
    const button = event.target.closest('[data-editor-action]');
    if (!button || button.disabled) return;
    Promise.resolve().then(async()=> {
      const action = button.dataset.editorAction;
      if (action==='select') {
        selected=button.dataset.editorKey;
        $('editor-detail').innerHTML=renderForm();$('editor-list').innerHTML=renderList();
        if (window.matchMedia('(max-width: 760px)').matches) $('editor-detail').scrollIntoView({block:'start'});
      }
      if (action==='reset') {drafts.set(selected,cloneForEditing(original()));additions.delete(selected);errors.delete(selected);invalidSizes.delete(selected);$('editor-detail').innerHTML=renderForm();$('editor-list').innerHTML=renderList();}
      if (action==='add') {
        if (!(additions.get(selected)||'').trim()) throw new Error('Enter a sender address or domain to add.');
        const before=JSON.stringify(draft().criteria);
        drafts.set(selected,extendFilterSenders(draft(),additions.get(selected)));
        additions.delete(selected);
        $('editor-detail').innerHTML=renderForm();$('editor-list').innerHTML=renderList();
        $('editor-feedback').textContent=before===JSON.stringify(draft().criteria)?'Those senders are already included.':'Added. Copy the changed field below.';
      }
      if (action==='copy') await copyField(button.dataset.editorCopy,button);
    }).catch(error=>{if($('editor-feedback'))$('editor-feedback').textContent=error.message;else notify(error.message);});
  });
  return { setFilters, render };
}
