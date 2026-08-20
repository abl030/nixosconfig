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
node woolies.mjs compare "full cream milk"   # every in-stock option by unit cost
node woolies.mjs set 151548=2 151547=0       # exact stockcodes; qty 0 removes
node woolies.mjs cart                        # show trolley
node woolies.mjs clear                       # empty trolley
```

Each run costs ~11s of Akamai warm-up, so batch several `set` pairs into one
call rather than one call per item.

## Gotchas

- **Stockcodes are store-specific.** The same product has a different stockcode
  on an anonymous session than on his store. Always resolve while logged in;
  never reuse a stockcode captured anonymously.
- Endpoints are undocumented and drift. If a call starts failing, check the
  repo README's endpoint table first.
- Search `PageSize` above 36 returns HTTP 400.
- Removals (qty 0) don't echo in `UpdatedItems` - trust a cart read instead.
