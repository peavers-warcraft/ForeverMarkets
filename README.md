# ForeverMarkets

A World of Warcraft addon for the [Forever Markets](https://wow-gold-markets.parses-web.workers.dev) website. It records what you see and trade at the auction house, and carries out the buy and sell plan the website sends back, one key press at a time. It works in WoW: Forever and in retail.

## What it records

- Your gold, the stacks in your bags and character bank, and your own listings.
- Every auction house book you open: prices, quantities and the auction ids Blizzard gives them, which is how the website knows which auction house you were at.
- Every purchase, listing and sale you make, and the auction house mail you collect.
- What vendors pay for the items you sell to them.

It never reads chat, and it never acts on its own.

## How it reaches the website

Everything stays in your saved variables until the Courier app uploads it, after each `/reload` or logout, once you have signed in with Battle.net and shared ForeverMarkets with Forever Markets in the app. The website's plan comes back the same way, through Courier, as the data addon `ForeverMarkets_Data`, which the game loads at your next `/reload`.

## Carrying out a plan

Open the auction house and the plan panel appears beside it. Each press of its button, or of the "Do the next plan step" key binding, does one thing: search for an item, buy what is at or under the plan's price, confirm, or list what you bought. Buys are sized to the gold you have at that moment, keeping back what listing will cost. A separate key binding works through vendor flips: listings priced under what a vendor pays.

## Commands

- `/fm` says how many books and trades are waiting for the Courier app, and what plan is loaded.

## Development

Lint and tests, with [wow-api](https://github.com/peavers-code/wow-api) checked out beside this repo:

```sh
WOW_FLAVOR=mainline WOW_BUILD=120105 luacheck .
lua tests/run.lua
```

`tests/run.lua` drives the addon through a fake client, since the game itself can't run in CI. Every push to `master` releases a new version, packaged without the development files.
