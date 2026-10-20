---
published: false
---

# Filters setup

The main flow updates the filters you already use: upload a Gmail XML export, choose a filter, extend its sender list or configure its fields, and copy the revised values into that existing filter in Gmail. This happens in your browser without signing in or using AI. New-filter building, AI reviews and import-file downloads remain under **Other tools**. Direct Gmail connection can wait.

## Update an existing filter

Once this version is published:

1. Open [www.spiiira.com/filters/](https://www.spiiira.com/filters/) on any laptop. No local server, installation or access code is needed for editing.
2. Choose **Open filter export** and load your current Gmail filter export. To get one in Gmail, open **Settings > See all settings > Filters and Blocked Addresses**, select the filters, and choose **Export**.
3. Find and select the existing filter by label or sender, such as Jira or Confluence.
4. Enter new senders or domains in **Add a sender or domain**, then click **Add sender**. New senders are marked **Added**. Open **Matching details** or **Actions** below to make other changes.
5. Choose **Copy for Gmail’s From field** (or the other changed field named on the button). In Gmail, find the same filter under **Filters and Blocked Addresses** and click **Edit**. Replace the matching field values, click **Continue**, check the actions, then click **Update filter**. [Google's editing instructions](https://support.google.com/mail/answer/6579).

This edits the existing Gmail filter rather than creating another one. The tool keeps other matching fields and actions in place as you add senders. If sender rules are embedded in a complex search, it asks you to edit that field directly rather than silently changing its meaning. Use **Preview matching mail** to check matching mail; paste individual field values when editing the filter.

Drafts stay in this tab as you switch between filters. Refreshing or closing it clears them. Nothing changes in Gmail until you apply the copied values yourself.

The **Dark / Light** button at the top changes the appearance without clearing your edits. It follows your computer's appearance on the first visit, then remembers your choice in this browser.

## Other tools and optional AI

**Other tools** contains **Build a new filter**, **Review filters** and **Fix missed mail**. New filters and AI proposals can still be reviewed and downloaded as Gmail import files; importing adds filters, so use the edit-and-copy flow above when expanding an existing rule.

For AI help, open **Settings** and enter the private access code used for the Cloudflare service. Claude is the default provider. The code is saved separately in each browser and does not transfer from this Mac. API keys stay in Cloudflare. AI and direct Gmail connection are optional for the main editing flow.

## What runs where

- **Your browser:** reads an uploaded export, edits copies of existing filters, prepares values to copy, checks rules, creates downloads and holds filters and email examples in memory. Refreshing clears those filters and examples. Settings save your AI provider, access code and written rules; your appearance preference is saved separately in that browser.
- **Google:** after you explicitly connect Gmail, the browser reads filters, label names and the inbox sample you request. The token stays in memory. This version does not create or delete filters in Gmail.
- **Cloudflare:** when you request AI analysis, the browser sends the loaded filter criteria/actions, your written rules and any supplied email details to the Worker. It checks your access code or validates an allowed Google token. It forwards the analysis text to the chosen AI provider. The Worker has no database, and its source does not log prompts or email content.
- **OpenAI or Anthropic:** receives the analysis text and returns proposed changes. Provider account retention and billing settings still apply. API credentials and Google tokens are never part of the model's prompt.

An uploaded work export can include company domains and filter text. AI sends that information to the provider you choose; use the local checks if you cannot send it. Inbox samples include sender, subject, date, List-Id, List-Unsubscribe and at most 200 characters of preview text per email, not full message bodies or attachments.

## 1. Get an API key

You only need **one** provider to start. API use is billed separately from a ChatGPT or Claude subscription.

1. For OpenAI, paste `https://platform.openai.com/api-keys` into your browser to open the API keys page. For Claude, open the [Claude Console](https://console.anthropic.com/).
2. Create an API key. Save it in your password manager.
3. Set the provider account's available spending controls and usage alerts. An alert may not be a hard cap, so check its wording.

The code currently uses **GPT-6 Luna** and **Claude Haiku 5.5**, efficient models supporting structured results. Their names are fixed in `worker.js`; a website visitor cannot select a more expensive model. The OpenAI request uses the Responses API with `store: false`. Native structured output is used for both providers. [OpenAI model](https://developers.openai.com/api/docs/models/gpt-6-luna), [OpenAI structured outputs](https://developers.openai.com/api/docs/guides/structured-outputs), [Claude model](https://platform.claude.com/docs/en/models/haiku-5-5/overview), [Claude structured outputs](https://platform.claude.com/docs/en/build-with-claude/structured-outputs).

## 2. Create the new Cloudflare service

1. Paste `https://dash.cloudflare.com/` into your browser to open the Cloudflare dashboard, then select **Workers & Pages**.
2. Choose **Create application**, then the Worker / starter option. Name the Worker **spiiira-filters-ai** and deploy the starter.
3. Open **Edit code**. Replace the starter code with the entire contents of `filters/worker.js`, then click **Deploy**.
4. Open the Worker's **Settings > Variables and Secrets > Add**. Select **Secret** for each value below.
5. Click **Deploy** to apply the secrets.

| Name | Value |
|---|---|
| `ACCESS_CODE` | A long random password from your password manager. Enter this later in the tool, never in the source code. |
| `OPENAI_API_KEY` | Your OpenAI API key; leave unset if only using Claude. |
| `ANTHROPIC_API_KEY` | Your Claude API key; leave unset if only using OpenAI. |
| `ALLOWED_EMAILS` | Optional: the personal Google account addresses that may use AI after connecting, separated by commas. A valid access code works without this. |

Keep these values in Cloudflare secrets. Do not paste them into this repository, screenshots or chat. [Cloudflare dashboard deployment](https://developers.cloudflare.com/workers/get-started/dashboard/), [Cloudflare secret instructions](https://developers.cloudflare.com/workers/configuration/secrets/).

Copy the Worker's actual address from its dashboard. The page expects:

`https://spiiira-filters-ai.jonas-spira.workers.dev`

If Cloudflare gives you a different address, have Codex update the single `AI_URL` constant in `filters/app.js` to match before publishing.

Open that address with `/health` added. A successful setup looks like:

```json
{"build":"2026-10-19.2","anthropic":true,"openai":true,"accessCode":true,"allowedEmails":1}
```

`false` for an unused provider is fine. This endpoint confirms configuration only; it does not spend API credits or validate the provider keys. The first analysis tests the actual provider connection. The page disables a provider when its key is absent.

The `build` value confirms which source version was deployed. If it is absent or differs from `2026-10-19.2`, deploy the latest `worker.js` before diagnosing a connection problem. This build uses Cloudflare's supported manual redirect mode and rejects redirects; no provider key or Google token follows a redirect.

## 3. Optional later: connect personal Gmail

Skip this section for building filters on another laptop. Direct Gmail connection can be finished separately.

1. Open the [Google Cloud Console](https://console.cloud.google.com/), and select the project containing the existing Filters OAuth client.
2. Under **APIs & Services > Library**, confirm **Gmail API** is enabled.
3. Open **Google Auth platform > Clients** (older navigation: **APIs & Services > Credentials**). Select the existing Web application client.
4. Under **Authorized JavaScript origins**, add `https://www.spiiira.com`. For the local preview, add `http://localhost:8000`. Save. The port must match the local preview's port.
5. Under **Google Auth platform > Audience**, if the app is in Testing, add your personal Google account as a test user.
6. Return to Filters and choose **Connect Gmail**. Grant the requested read permissions. If you grant only part of them, reconnect and grant the remaining permissions before using the affected feature.

The public client ID already in the page is also in `worker.js`. If you replace the OAuth client, update both, or set the Worker's `GOOGLE_CLIENT_ID` variable to the new ID. This ID is public configuration, not a secret.

The page uses Google's supported Identity Services token client for short, interactive browser sessions. Tokens expire; reconnect when requested. A longer lived background connection would need a different server sign-in flow. [Google token model](https://developers.google.com/identity/oauth2/web/guides/use-token-model).

Gmail classifies some read scopes as restricted. Google may show an unverified-app message for a private test app, and a work administrator may block access. The exported XML path still works without that connection. [Google Gmail scope reference](https://developers.google.com/workspace/gmail/api/auth/scopes).

## 4. Try it before publishing

From Terminal:

```sh
cd ~/Projects/"SPIIIRA Tools"/jonasspira.github.io
python3 -m http.server 8000
```

Paste `http://localhost:8000/filters/` into your browser to open the local Filters page. XML editing and copying work immediately. For optional AI, open **Settings**, select your configured provider and enter the access code. The access code is saved in that browser; keep it private and use a separate browser profile on a shared machine.

1. Load an invented XML export, choose a filter, add a sender, and confirm that the copied field retains the old sender rules and other matching fields. Switch filters and back to verify both drafts stay separate.
2. Under **Other tools > Build a new filter**, build a harmless filter from `nobody@example.com`, label it `zz-test`, and download its import file. Reopen that file in the tool and check its matching rules and actions.
3. Optional: run the existing example review or ask AI to draft a rule with an invented sender. No personal data is needed for these checks.

Importing a harmless filter into Gmail remains a separate manual acceptance check. When ready, create `zz-test` in Gmail first, import the file, and check its criteria and actions. Direct Gmail loading, inbox sampling and token-expiry checks can wait until connection work resumes. No real filter export or inbox data belongs in this public repository.

## Import a reviewed change

Gmail imports **add** filters. An import does not replace an existing filter automatically. [Gmail's import/export instructions](https://support.google.com/mail/answer/6579).

1. In Gmail, open **Settings > See all settings > Filters and Blocked Addresses**.
2. Export a backup and save it somewhere private.
3. Create any new labels named by your selected changes. Google's help does not promise automatic label creation on import; creating them first avoids depending on that behavior.
4. Delete only the old filters explicitly listed beside the changes you selected. Match their shown criteria and actions before deleting.
5. At the bottom, choose **Import filters > Choose file > Open file**. Review the filters, then **Create filters**. Applying them to existing messages is optional.

The tool's 1,500-character merge ceiling is a conservative application limit, not a claimed published Gmail maximum. It preserves every original filter's AND conditions when joining filters with OR, and blocks unsafe output before download.

## Publish and retire the old service

After the local XML editing and copy checks pass, ask Codex to publish. Verify that the public page loads an export and prepares updated field values without a Gmail connection. If using AI, verify a draft on the live site too. Finishing the direct Gmail connection is not a publishing prerequisite.

Only after the new live service works, retire the old `spiiira-claude-proxy` Worker in Cloudflare. It is the old service described in the handoff; this rebuild does not change or delete it. Keep its retirement separate from publishing so a failed setup does not take away the current service prematurely.

## Troubleshooting

| What you see | What to do |
|---|---|
| AI service cannot be reached | Check that the service address matches the deployed Worker, then open its `/health` address. |
| Provider unavailable | Add that provider's API key as a Cloudflare Secret and deploy, or choose the configured provider. |
| Enter access code | Check the saved code. Connecting Google only authorizes AI when its verified address is in `ALLOWED_EMAILS`. |
| Provider rejects API key | Check the API account, key and billing. `/health` does not validate keys. |
| API key contains invalid characters | Replace that provider's Cloudflare Secret with the original single-line key. The Worker trims surrounding whitespace and rejects internal whitespace or non-ASCII characters without showing the value. |
| Provider could not be reached | The failure happened before a provider HTTP response. Check Cloudflare connectivity and deployment; an included stage/type marker contains no prompt, token or key. |
| Provider returned an unexpected redirect | The Worker rejected it without following the destination. Check the deployed source and provider availability. |
| A message includes `stage:...` and `type:...` | Share only that marker with Codex. It identifies a fixed processing step and error class; never share your secrets, raw request or email content. |
| Result too long / request too large | Use fewer sample emails or a smaller export. Requests are capped at 300 KB and output at 16,000 tokens. |
| Google origin error | Add the exact page origin, including the local port, to the OAuth client. |
| Sign in again | The temporary Google token expired. Reconnect; tokens are never stored. |

For a developer check, run `node --test filters/tests/*.test.mjs` from the repository root. Worker tests use invented data and mock provider/Google responses; they never use live keys. Setup documentation and API shapes were checked against official documentation on 2026-10-19. Live provider analysis, Cloudflare deployment and a real Gmail import still require the account setup above.
