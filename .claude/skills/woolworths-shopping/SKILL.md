---
name: woolworths-shopping
description: Do the Woolworths online shop - search the live catalogue, compare by unit cost, judge, and build the trolley. Use when the user says "put X in the cart", "add X to the shop", "do the woolies shop", "what's cheapest for X", "order groceries", or names groceries to buy.
---

# Woolworths Shopping

The user doesn't use the Woolworths site ("too hard"). We do the shopping; he
follows along and pays.

> **This repo is mirrored to public GitHub.** Keep personal details out of this
> file - no name, address, suburb, store ID, or account data. Those live in
> `PREFERENCES.md` in the private `git.ablz.au/abl030/woolies` repo, alongside
> the tool. **Read that file at the start of every shopping session**; it is the
> real standing brief and the place to append anything new we learn.

## The deal

He says what he wants in plain English. We search, **judge**, and put it in.

> **User:** put in six litres of full cream milk
>
> **Us:** compare → 3L is $1.72/L, 2L is $1.78/L, 1L is $1.85/L. Two 3L bottles
> is exactly 6L for $10.30, cheaper than 3x2L ($10.65) or 6x1L ($11.10).
> → `set <3L stockcode>=2`, then report what went in and why.

**The judgement is ours, not the tool's.** `compare` returns facts and picks
nothing. Don't reach for `add`'s fuzzy name matching when the choice matters -
an earlier scoring heuristic put a $46.20 Tim Tam share box in the trolley for
"tim tam original 200g".

Default rule: **cheapest unit cost that satisfies the request.** Biggest pack is
usually cheapest per unit but not always - one brand's 3L can be worse per litre
than the house-brand 2L. Check per item.

State the comparison when it's interesting, not for every trivial line. Always
report what actually landed in the cart.

## Keep the brief current

He asked for this explicitly: **when something is hard, slow, or surprising,
write it down before moving on.** Method and tool lessons go in this file;
anything about him or his products goes in `PREFERENCES.md`. A shop that
teaches nothing new is the goal, and it only gets there if each one records
what it learned.

## Comparing when the units don't match

Woolworths prices some lines per kg and others "each", which makes them
uncomparable as listed - a 3-bulb garlic bag priced Each can't be read against
loose garlic priced per kg. `compare` folds `CupMeasure` variants to a common
**$/kg** and infers weight from `PackageSize` when the site states one.

- `~` before a $/kg figure means we inferred it, the site didn't publish it.
- `?` means count-based with no stated weight - genuinely not comparable by
  weight. Say so rather than inventing a number.

When a `?` matters, fall back to **price per unit of the thing he actually
wants** (per bulb, per egg, per roll) and state the assumption. Watch for pack
size differing from loose size: pre-packed produce is often smaller, so cheaper
per-item is not automatically cheaper per kilo.

## Search broad, then narrow yourself

**A precise query is a filtered query, and the filter is not yours.** Searching
the exact phrase `"whole peeled tomatoes"` returned **4** products, no house
brand among them, and made a $3.50/kg tin look like the cheapest available.
Searching `"canned tomatoes"` returned **36**, including a Woolworths tin at
$2.75/kg - **21% cheaper**. He caught it, not us: *"really, those toms are
cheaper than woolies home brand?"*

So: **search the category, not the product.** "canned tomatoes" not "whole
peeled tomatoes"; "celery" not "celery sticks"; "milk" or "full cream milk"
rather than a brand and size. Then filter by reading, where the rejects are
visible and countable.

If the house brand is absent from a result set for a staple, the query is too
narrow - Woolworths almost always has one, and it is usually the LUC winner.
Treat its absence as a bug in the search, not a fact about the shelf.

Woolworths names variants predictably, which helps once the set is wide enough:
`Diced ...` vs `... Peeled ...` is the diced/whole pair.

## The search returns things that are not the thing

Search matches names, so a query returns adjacent products, processed versions,
and Everyday Market marketplace junk. Real examples, all top-of-list:

- "celery" → Campbell's *Cream of Celery soup* ($1.95) and *celery salt* were
  cheaper than any actual celery.
- "ice cream cake" → silicone cake *moulds*, decorating spoons, birthday cards.
- "brisket" → BBQ rub, potato chips, protein bars, wood pellets.
- "Woolworths Ice Cream Mud Cake" is a **tub of ice cream**, not a cake.

**The SAP category is the reliable discriminator**, and `detail` prints it:

| Looks similar | Category tells you |
|---|---|
| ice cream cake vs tub | `ICE CREAM DESSERTS` vs `ICE CREAM / TAKE HOME` |
| pre-packed vs loose produce | `GARLIC P/P` vs `GARLIC LOOSE` |
| slow-cook cut vs roasting cut | `BEEF SLOW COOK CASE READY` vs `ROAST CASE READY` |
| whole piece vs pre-cut | name carries "Steak"; check `detail` |

When the cheapest row looks too cheap, it is usually not the product. Check
before adding, not after.

## Filter by category, not by hoping the name is clean

`--cat=<category>` matches `sapcategoryname` **exactly**. Fresh fruit is
`FRUIT`, so `--cat=fruit` gives fruit and not fruit straps. Without it,
"berries" and "grapes" return Fanta, Gatorade, Roll-Ups and bin deodoriser.

Match exactly, not by substring: substring-matching the segment name too still
caught `FRUIT SNACKS` and `FRUIT STRAPS`. Use `detail` to learn a category name
before filtering on it.

## Price is not the price: multibuys and per-kilo units

Two things make the `Price` field a liar. Both change which product is cheapest.

**Multibuys are invisible.** A "2 for $5" never touches `Price`, `WasPrice` or
`IsOnSpecial`. It lives in `CentreTag.MultibuyData` as
`{Quantity, Price, CupTag}`. `compare` now prints
`[MULTIBUY 2 for $5.00 = $2.50 ea, -29%]` per row and counts them in the footer.
Say so when one applies and whether taking it is worth it — buying two of
something he wanted one of is only a saving if he'll use both.

**Loose produce is priced per kilo, not per pack.** Check `unit` and
`minQty` in `detail`:

| | unit | minQty | listed | what 200g costs |
|---|---|---|---|---|
| Mushrooms Cups **Loose** | `KG` | 0.2 | $11.50 | **$2.30** |
| Mushrooms Button **Punnet** 200g | `Each` | 1 | $4.50 | $4.50 |

The loose row's $11.50 is a **per-kilo** rate, so reading it as a pack price
makes it look eight times dearer when it is actually half. `unit=KG` items take
fractional quantities: `set 143109=0.2` is 200g.

Loose is routinely far cheaper than the punnet. Always compare both, and if the
loose version is a slightly different variety (cups vs button), flag it rather
than silently substituting.

## Specials: the API flag lies

The search request takes `IsSpecial: true`, and it is a **hint, not a filter**.
It cheerfully returns full-price items - Woolworths Onion Brown Bag and Cherry
Tomatoes both came back with no special on them.

`--specials` therefore filters client-side on each product's `IsOnSpecial`
field, which is authoritative.

**Before reporting "nothing is on special", run a control.** Sixteen fruit
queries returned zero, which looks exactly like a broken filter. Re-running
against `tomatoes`, `chocolate` and `beef` returned rows that all carried real
was-prices, proving the mechanism worked and the fruit result was real. A
negative finding needs a positive control or it is just a bug you have not
noticed yet.

## Don't waste his time

Every run pays **~11s of Akamai warm-up** plus browser start. Six separate
`compare` calls is minutes of waiting.

- Batch searches with `multi "beef chuck" "beef blade roast" "beef brisket"` -
  one session, one warm-up.
- Batch writes: `set 141203=1 120847=1 151548=2` in a single call.
- Use `detail <code> <code>` for several products at once.

## The session expires silently — this is the dangerous one

The auth cookies stay in the jar and the site just stops honouring them. Nothing
errors. Every command keeps working, against an **anonymous trolley at a
different store**, with different stockcodes *and different prices*.

It has already bitten once: three items went into a throwaway cart while the
real trolley sat untouched, and the store price difference (Odd Bunch carrots
$1.60/kg vs $1.33, navel oranges $3.17/kg vs $2.63) looked exactly like a
mid-session price drop and was nearly reported as one.

The tool now checks identity before every command, **refuses writes** when
logged out, and warns on reads. Do not work around that guard.

**Recovery — do it yourself, don't hand him a chore.** The login window can be
put on his desktop from doc1 over SSH:

```bash
scp woolies.mjs framework:~/woolies-poc/
ssh framework 'cd ~/woolies-poc && WAYLAND_DISPLAY=wayland-0 \
  XDG_RUNTIME_DIR=/run/user/1000 nohup node woolies.mjs login > login.log 2>&1 &'
# tell him the window is up; poll login.log for "Detected sign-in"
rm -rf ~/.cache/woolies-profile
rsync -a framework:~/.cache/woolies-profile/ ~/.cache/woolies-profile/
```

Two things make that work:

- **Wayland, not X.** `--ozone-platform=wayland` is set automatically for headed
  launches when `WAYLAND_DISPLAY` is set. X11/XWayland rejects an SSH session
  with *"Authorization required, but no authorization protocol specified"* -
  no Xauthority cookie. Wayland authorises by socket ownership instead.
- **`login` polls** for a detected sign-in rather than waiting on stdin, since
  there's no TTY at the SSH end. It closes cleanly on success, which is what
  flushes cookies to disk.

He only has to type his password. Delete the local profile before rsyncing so
stale files can't survive.

His real trolley is **server-side on the account** and survives the logout, so
reassure him rather than rebuilding it from scratch. Confirm with `cart` after
re-login before assuming anything was lost.

If prices look like they moved mid-session, suspect the session before
believing the prices.

## Hard rules

- **Never check out.** Building the trolley is where it stops. He pays.
- Always show the basket after changing it.
- Don't add things he didn't ask for. Suggest, don't assume.
- Flag when a chosen item is on special, and when stock is short.
- Watch the order minimum for his fulfilment method before declaring the shop
  done - the figure is in `PREFERENCES.md`.

## Where it runs

Tool lives on **doc1** at `~/woolies-poc`, from the private repo
`git.ablz.au/abl030/woolies`. He follows along from framework, which has a copy.

The session is a persistent Chromium profile at `~/.cache/woolies-profile`,
already logged in. If it logs out, `login` must run on a machine with a display
(framework), then rsync the profile to doc1 - see the repo README.

```bash
cd ~/woolies-poc
node woolies.mjs compare "full cream milk"        # in-stock options, cheapest $/kg first
node woolies.mjs multi "beef chuck" "brisket"     # several searches, ONE warm-up
node woolies.mjs detail 141203 764567             # whole piece or steaks? real weight range?
node woolies.mjs set 151548=2 151547=0            # exact stockcodes; qty 0 removes
node woolies.mjs cart                             # show trolley
node woolies.mjs clear                            # empty trolley
```

`detail` is worth a call before committing to anything where the search row is
ambiguous - it exposes the description, the SAP category, the real weight range
and whether a cut is a whole piece or pre-cut.

`cart` prints Woolworths' own `Totals` block alongside our line sum. If the two
disagree, ours is wrong - `SalePrice` is a line total, not a unit price, and
multiplying it by quantity once reported $47.60 on a $37.30 trolley.

## Gotchas

- **Stockcodes are store-specific.** The same product has a different stockcode
  on an anonymous session than on his store. Always resolve while logged in;
  never reuse a stockcode captured anonymously.
- Endpoints are undocumented and drift. If a call starts failing, check the
  repo README's endpoint table first.
- Search `PageSize` above 36 returns HTTP 400.
- Removals (qty 0) don't echo in `UpdatedItems` - trust a cart read instead.
