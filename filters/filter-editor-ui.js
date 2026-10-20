import { describeActions, buildQuery } from './filter-model.js';
import { cloneForEditing, applyCriteriaEdit, getGmailFieldValues, getSenderTarget, extendFilterSenders, getSenderTerms, getEditorChanges } from './filter-editor.js';

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
  const canReset = () => changed(selected) || Boolean((additions.get(selected)||'').trim()) || errors.has(selected) || invalidSizes.has(selected);
  function setFilters(filters) {
    originals = filters.map(cloneForEditing); drafts.clear(); additions.clear(); errors.clear(); invalidSizes.clear();
    for (const filter of originals) drafts.set(filter.key,cloneForEditing(filter));
    selected = originals[0]?.key || ''; search = '';
  }
  function matchingFilters() {
    const term = search.trim().toLowerCase();
    return originals.filter(f => !term || `${f.position} ${describeActions(f)} ${describeActions(drafts.get(f.key))} ${Object.values(f.criteria).join(' ')} ${Object.values(drafts.get(f.key).criteria).join(' ')}`.toLowerCase().includes(term));
  }
  function renderList() {
    const matches = matchingFilters();
    return matches.length ? matches.map(f => {
      const current=drafts.get(f.key), terms=getSenderTerms(current);
      const name=f.actions.label || (f.actions.trash?'Delete matching mail':'Unlabeled filter');
      const meta=terms===null?'Combined matching rule':terms.length?`${terms.length} sender${terms.length===1?'':'s'}`:'Any sender';
      return `<button type="button" class="editor-filter${selected===f.key?' active':''}" data-editor-action="select" data-editor-key="${esc(f.key)}" aria-pressed="${selected===f.key}"><span class="editor-filter-mark" aria-hidden="true">${esc(name[0].toUpperCase())}</span><span class="editor-filter-text"><span class="editor-filter-name">${esc(name)}${changed(f.key)?'<small>Edited</small>':''}</span><span class="editor-filter-meta">${meta} <span aria-hidden="true">·</span> #${f.position}</span></span></button>`;
    }).join('') : '<p class="muted spacer">No filters found. Try a label or sender.</p>';
  }
  function renderSenders() {
    const terms=getSenderTerms(draft()), change=getEditorChanges(original(),draft());
    if (terms===null) return `<p class="sender-expression-note">This filter uses a combined search. <button type="button" class="inline-link" data-editor-action="matching">View matching details</button></p>`;
    if (!terms.length) return '<p class="sender-expression-note">This rule currently matches any sender. Adding one will limit it to those senders.</p>';
    return terms.map(term=>`<span class="sender-chip${change.addedSenders?.includes(term)?' is-new':''}"><span class="sender-chip-label">${esc(term)}</span>${change.addedSenders?.includes(term)?'<small class="sender-chip-note">Added</small>':''}</span>`).join('');
  }
  function changeSummary() {
    const f=draft(), change=getEditorChanges(original(),f), target=getSenderTarget(f), baselineTarget=getSenderTarget(original());
    if (!changed(selected)) return target.field ? 'Your current rule. Add a sender when you need one.' : 'Your current rule. Use Matching details below to update this search.';
    const bits=[];
    if (change.addedSenders?.length) bits.push(`${change.addedSenders.length} sender${change.addedSenders.length===1?'':'s'} added`);
    if (change.removedSenders?.length) bits.push(`${change.removedSenders.length} sender${change.removedSenders.length===1?'':'s'} removed`);
    const senderOnly=target.field && target.field===baselineTarget.field && change.changedCriteria.every(key=>key===target.field);
    if (!bits.length && change.changedCriteria.length) bits.push(senderOnly?'Sender rule updated':'Matching details updated');
    else if (bits.length && !senderOnly && change.changedCriteria.length) bits.push('matching details updated');
    if (change.actionsChanged) bits.push('actions updated');
    const status=bits.length?bits.join('. ')+'.':'Rule updated.';
    return status+(senderOnly&&!change.actionsChanged?' Other conditions and actions unchanged.':!change.actionsChanged?' Actions unchanged.':!change.changedCriteria.length?' Matching conditions unchanged.':'');
  }
  function renderCriterion(key,label,{rows=2}={}) {
    return `<div class="field"><label for="edit-${key}">${esc(label)}</label><textarea id="edit-${key}" rows="${rows}" data-editor-criterion="${key}" spellcheck="false">${esc(draft().criteria[key])}</textarea></div>`;
  }
  function renderActions() {
    const a = draft().actions;
    const known = categories.some(([key])=>key===a.category);
    return `<details class="editor-actions"><summary>Actions · <span id="editor-action-summary">${esc(describeActions(draft()))}</span></summary><p class="field-hint">These stay as they are unless you change them. Check them on Gmail's next screen.</p><div class="form-grid spacer"><div class="field"><label for="edit-label">Apply the label</label><input id="edit-label" data-editor-action-field="label" value="${esc(a.label)}"></div><div class="field"><label for="edit-forwardTo">Forward to</label><input id="edit-forwardTo" data-editor-action-field="forwardTo" value="${esc(a.forwardTo)}"></div></div><div class="actions-grid">${actions.map(([key,label])=>`<label class="check-label"><input type="checkbox" data-editor-action-field="${key}"${a[key]?' checked':''}>${label}</label>`).join('')}</div><label for="edit-category">Categorize as</label><select id="edit-category" data-editor-action-field="category"><option value="">No category action</option>${a.category&&!known?`<option value="${esc(a.category)}" selected>${esc(a.category)}</option>`:''}${categories.map(([key,label])=>`<option value="${key}"${a.category===key?' selected':''}>${label}</option>`).join('')}</select></details>`;
  }
  const senderHint = target => target.field==='hasTheWord' ? 'Adds to Has the words. Separate multiple senders with commas or new lines.' : target.field ? 'Separate multiple senders with commas or new lines.' : target.reason;
  function renderForm() {
    const f=draft(), target=getSenderTarget(f), c=f.criteria;
    const otherCount=textFields.filter(([key])=>key!==target.field&&c[key]).length+Number(c.hasAttachment)+Number(c.excludeChats)+Number(c.size!=null);
    return `<div class="editor-heading"><div><p class="editor-filter-meta">Filter #${f.position}</p><h2>${esc(original().actions.label || 'Unlabeled filter')}</h2><p class="editor-context">${esc(describeActions(f))}</p></div><button type="button" class="quiet" data-editor-action="reset"${canReset()?'':' disabled'}>Reset</button></div>
      <section class="editor-sender-section" aria-labelledby="editor-sender-heading"><div class="editor-sender-heading"><h3 id="editor-sender-heading">Senders</h3><button type="button" class="inline-link" data-editor-action="matching">Edit details</button></div><div id="editor-senders" class="editor-senders">${renderSenders()}</div></section>
      <section class="editor-add"><label for="edit-additions">Add a sender or domain</label><textarea id="edit-additions" rows="2" placeholder="alerts@example.com or updates.example.com" spellcheck="false">${esc(additions.get(selected)||'')}</textarea><div class="editor-add-row"><button type="button" class="secondary" data-editor-action="add"${target.field?'':' disabled'}>Add sender</button><span id="editor-add-hint" class="field-hint">${esc(senderHint(target))}</span></div><p id="editor-feedback" class="editor-feedback" role="status"></p></section>
      <section class="editor-copy" aria-label="Copy updated filter"><div id="editor-copy-area">${renderOutput()}</div></section>
      <details id="editor-matching" class="editor-advanced editor-match-details"${!target.field || errors.has(selected)?' open':''}><summary>Matching details${otherCount?` <span class="field-hint">· ${otherCount} other condition${otherCount===1?'':'s'}</span>`:''}</summary><p class="field-hint">These are the matching fields from your existing filter. Change only what you need.</p>${renderCriterion('from','From')}<div class="form-grid">${renderCriterion('to','To')}${renderCriterion('subject','Subject')}</div>${renderCriterion('hasTheWord','Has the words')}${renderCriterion('doesNotHaveTheWord',"Doesn't have")}<div class="inline-actions"><label class="check-label"><input type="checkbox" data-editor-criterion="hasAttachment"${c.hasAttachment?' checked':''}>Has attachment</label><label class="check-label"><input type="checkbox" data-editor-criterion="excludeChats"${c.excludeChats?' checked':''}>Don't include chats</label></div><div class="editor-size spacer"><label for="edit-size">Size</label><select id="edit-sizeComparison" data-editor-criterion="sizeComparison"><option value="larger"${c.sizeComparison!=='smaller'?' selected':''}>Greater than</option><option value="smaller"${c.sizeComparison==='smaller'?' selected':''}>Less than</option></select><input id="edit-size" type="number" min="0" step="1" placeholder="Any size" value="${esc(invalidSizes.has(selected)?invalidSizes.get(selected):c.size??'')}" data-editor-criterion="size"><span class="muted">bytes</span></div></details>
      ${renderActions()}
      <details class="editor-copy-help"><summary>Where do I paste this?</summary><ol><li>In Gmail, open <strong>Settings → See all settings → Filters and Blocked Addresses</strong>.</li><li>Find this filter and choose <strong>Edit</strong>. Paste into the matching field.</li><li>Choose <strong>Continue</strong>, check the actions, then <strong>Update filter</strong>.</li></ol><p class="field-hint">You're updating this filter, so there's no need to import another one.</p></details>`;
  }
  function renderOutput() {
    const f=draft(), baseline=original(), values=getGmailFieldValues(f);
    const pending=Boolean((additions.get(selected)||'').trim()), invalid=errors.get(selected), target=getSenderTarget(f);
    const changedKeys=textFields.filter(([key])=>f.criteria[key]!==baseline.criteria[key]).map(([key])=>key);
    const keys=changedKeys.length?changedKeys:[target.field||textFields.find(([key])=>f.criteria[key])?.[0]||'from'];
    const primary=keys[0];
    const row=([key,label])=> {
      const copyLabel=`Copy for Gmail’s ${label} field`;
      return `<div class="editor-copy-row"><button type="button" class="${key===primary?'primary editor-copy-primary':'secondary'}" data-editor-action="copy" data-editor-copy="${key}" data-copy-label="${esc(copyLabel)}"${invalid||pending?' disabled':''}>${esc(copyLabel)}</button><details class="editor-field-value"><summary>View ${esc(label)} value${f.criteria[key]!==baseline.criteria[key]?' · changed':''}</summary><label class="visually-hidden" for="copy-${key}">${esc(label)} value for Gmail</label><textarea id="copy-${key}" rows="2" readonly spellcheck="false">${esc(values[key])}</textarea>${!values[key]?'<p class="field-hint">Clear this field in Gmail.</p>':''}</details></div>`;
    };
    const flags=[];
    if (f.criteria.hasAttachment!==baseline.criteria.hasAttachment) flags.push(`Has attachment: ${f.criteria.hasAttachment?'on':'off'}`);
    if (f.criteria.excludeChats!==baseline.criteria.excludeChats) flags.push(`Don’t include chats: ${f.criteria.excludeChats?'on':'off'}`);
    if (f.criteria.size!==baseline.criteria.size||f.criteria.sizeComparison!==baseline.criteria.sizeComparison) flags.push(f.criteria.size==null?'Remove the size restriction':`Size: ${f.criteria.sizeComparison==='smaller'?'less':'greater'} than ${f.criteria.size} bytes`);
    return `<p class="editor-status${changed(selected)?' changed':''}" role="status">${esc(invalid || (pending?'Add the new senders before copying.':changeSummary()))}</p>
      ${values.warnings.length?`<details class="editor-preservation-note"><summary>Other settings to keep</summary>${values.warnings.map(w=>`<p class="field-hint">${esc(w)}</p>`).join('')}</details>`:''}
      ${textFields.filter(([key])=>keys.includes(key)).map(row).join('')}
      ${flags.length?`<p class="field-hint">Also update in Gmail: ${esc(flags.join(' · '))}.</p>`:''}
      ${JSON.stringify(f.actions)!==JSON.stringify(baseline.actions)?`<p class="editor-action-change">On the next Gmail screen: ${esc(describeActions(f))}. Clear any actions you removed.</p>`:''}
      <details class="editor-other-copy"><summary>Copy other fields</summary>${textFields.filter(([key])=>!keys.includes(key)).map(row).join('')}</details>
      ${values.queryAvailable?`<details class="editor-search"><summary>Preview matching mail</summary><p class="field-hint">Use this complete search in Gmail's search bar. When editing the filter, copy the individual fields above.</p><code class="query">${esc(values.query)}</code><div class="inline-actions"><button type="button" class="secondary" data-editor-action="copy" data-editor-copy="query" data-copy-label="Copy search"${invalid||pending?' disabled':''}>Copy search</button>${queryLink(values.query)}</div></details>`:''}`;
  }
  function render() {
    if (!originals.length) return '<p class="editor-empty-note">Your filters stay in this browser. Nothing changes in Gmail until you paste it there.</p>';
    return `<div class="editor-workspace"><aside class="editor-picker panel" aria-label="Choose an existing filter"><div class="editor-sender-heading"><h2>Your filters</h2><span class="editor-filter-meta">${originals.length}</span></div><label class="visually-hidden" for="editor-search">Find a filter</label><input id="editor-search" type="search" value="${esc(search)}" placeholder="Find a label or sender"><div id="editor-list" class="editor-list">${renderList()}</div><p class="field-hint">Drafts stay here while you switch filters. Refreshing clears them.</p></aside><section class="editor-detail panel" id="editor-detail" aria-label="Configure existing filter">${renderForm()}</section></div>`;
  }
  function refreshOutput() {
    if (!$('editor-copy-area') || !draft()) return;
    $('editor-copy-area').innerHTML = renderOutput();
    $('editor-list').innerHTML = renderList();
    $('editor-action-summary').textContent = describeActions(draft());
    $('editor-senders').innerHTML=renderSenders();
    $('editor-detail').querySelector('[data-editor-action="reset"]').disabled=!canReset();
    $('editor-detail').querySelector('.editor-context').textContent=describeActions(draft());
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
      button.textContent = 'Copied to clipboard';
      setTimeout(()=>{if(button.isConnected)button.textContent=button.dataset.copyLabel||'Copy';},1800);
    } catch {
      const output = key==='query' ? null : $(`copy-${key}`);
      if (output) {output.closest('details').open=true;output.focus();output.select();}
      notify('Copy is blocked by this browser. Select the text and press Ctrl+C (Command+C on a Mac).');
    }
  }
  document.addEventListener('input',event=> {
    const input = event.target;
    if (input.id==='editor-search') {search=input.value;$('editor-list').innerHTML=renderList();return;}
    if (!draft() || !$('editor-detail')) return;
    if (input.id==='edit-additions') {additions.set(selected,input.value);$('editor-feedback').textContent='';refreshOutput();return;}
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
      if (action==='matching') {const details=$('editor-matching');details.open=true;const key=getSenderTarget(draft()).field||textFields.find(([key])=>draft().criteria[key])?.[0]||'from';$(`edit-${key}`).focus();}
      if (action==='reset') {drafts.set(selected,cloneForEditing(original()));additions.delete(selected);errors.delete(selected);invalidSizes.delete(selected);$('editor-detail').innerHTML=renderForm();$('editor-list').innerHTML=renderList();}
      if (action==='add') {
        if (!(additions.get(selected)||'').trim()) throw new Error('Enter a sender address or domain to add.');
        const before=JSON.stringify(draft().criteria);
        drafts.set(selected,extendFilterSenders(draft(),additions.get(selected)));
        additions.delete(selected);
        $('editor-detail').innerHTML=renderForm();$('editor-list').innerHTML=renderList();
        $('editor-feedback').textContent=before===JSON.stringify(draft().criteria)?'Those senders are already in this rule.':'';
      }
      if (action==='copy') await copyField(button.dataset.editorCopy,button);
    }).catch(error=>{if($('editor-feedback'))$('editor-feedback').textContent=error.message;else notify(error.message);});
  });
  return { setFilters, render };
}
