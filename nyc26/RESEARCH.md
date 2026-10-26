---
# Keeps this file off www.spiiira.com. Jekyll skips pages marked unpublished.
published: false
---

# Research sub-page

www.spiiira.com/nyc26/research/ — behind the same PIN as the trip hub.

It collects candidate places found by whichever AI tool did the searching, so
several tools can contribute without any of them needing access to this
repository or to the database. You paste; the page parses, de-duplicates, and
holds them until you keep, skip, or push one onto the trip map.

## Using it

1. Run the travel framework prompt (below) in Claude, Muse, ChatGPT, or anything
   else.
2. Copy its whole answer.
3. Open the research page, put the tool's name in **Which tool found these?**,
   paste the answer, and press **Add these finds**.
4. Work through them: **Keep**, **Skip**, or **Add to map**.

**Add to map** looks the place up and, if the map search returns a real New York
match, pins it on the trip. If it finds nothing, the place goes on by name with
no pin, exactly as the trip page does. It never invents a coordinate. The
section decides the category: Shopping becomes Shops, Food & Drink becomes Food,
Experiences becomes Other.

Names already on the list are skipped, so running several tools on the same
question is safe. The check ignores case, punctuation, leading "the", and treats
`&` and `and` as the same, so one tool's "Russ & Daughters" will not be added
twice as another's "Russ and Daughters".

## The format to ask tools for

Any answer is accepted, but the page reads this one exactly, so it is worth
adding to the end of your prompt:

```
Return one line per place, in this format, with no other text:
Section | Name | Neighborhood | Why it is worth it | Address

Section must be exactly one of: Shopping, Food & Drink, Experiences
```

A JSON array also works, with `name`, `section`, `neighborhood`, `why` and
`address` keys. So does an ordinary Markdown answer with `## Shopping` style
headings and bulleted places — the page will read it, but expect to tidy the
results up by hand.

What the parser does with a loose answer:

- `## Shopping`, `**Food & Drink:**` and similar headings set the section for
  everything beneath them.
- A bullet like `- **Name** — why (Neighborhood)` is split into name, reason and
  neighborhood. So is `Name: why`.
- Anything it cannot split becomes a name on its own, under the current section.
- An empty answer produces nothing. It never invents a place.

## The travel framework prompt

Jonas's canonical version lives in `~/Downloads/travel-framework.md`. For this
trip, [CITY] is New York and [DATES] are October 26–29, 2026. The framework asks
for things that cannot be done in Grand Rapids, in the three sections above, and
says to skip anything with a West Michigan location, to confirm each place is
currently open, and to give its neighborhood.

## A tool adding places by itself

A tool that can make HTTP requests does not need Jonas to paste anything. See
the intake endpoint in `AGENTS.md`: one POST per place, with its own key, going
either straight onto the map or into this list. It can only add; it cannot read
or change the trip.

Set or rotate the key with:

```
npx wrangler secret put INTAKE_KEY --config worker/wrangler.toml
```

Rotating it immediately stops any tool that has the old one.

## Rules

- The research list is a separate document in the same database, under the id
  `research`. It never touches the trip document except when you press
  **Add to map**, which writes one place through the ordinary trip save,
  revision check and all.
- `validateResearch()` in `worker/worker.js` is the only authority on what may be
  stored. The three sections and the three verdicts (`new`, `keep`, `skip`) are
  fixed there; the browser repeats none of it.
- Nothing from research is ever published. The page is `noindex`, it holds no
  content until the PIN is accepted, and no find is written into this
  repository.
- Do not paste anything private in here. It is a list of shops and restaurants.
