# Morpheus M-01 PoC: dry funding account bricks session closes

Proof of concept for a Morpheus bug bounty report. The target is the
deployed LumerinDiamond on Base (`0x6aBE1d282f72B474E54527D93b979A4f64d3030a`),
which is in scope in the program's Appendix A.

## What it proves

`closeSession` pays the provider from the funding account in the same
transaction as the user refund (`SessionRouter._claimForProvider` calls
`safeTransferFrom(fundingAccount, provider, amount)` for non-direct
sessions, and the refund follows in the same `closeSession` call). If the
funding account cannot pay, the whole close reverts and the user's
escrowed stake stays locked in the diamond.

- `test_DryFundingBricksLateClose`: with the funding account at 0 MOR, a
  late close reverts, the session stays active, the user balance is
  unchanged and the diamond keeps the escrow. After the funding account is
  refilled, the same close succeeds and the user is refunded.
- `test_DisputeEscapeOnlySameDayEarlyClose`: the only escape is a
  same-day early dispute close. Late and multi-day closes have no escape.

The dry funding account is simulated with `deal` (state setup, not an
attack step). No privileged accounts are used: every actor is a fresh
test wallet.

## Run it

Requires [Foundry](https://getfoundry.sh). One command, from a clean
clone, no setup beyond an internet connection (the test forks Base
mainnet from the public RPC):

```
forge test
```

Expected output: 2 tests passed, 0 failed.

The fork is pinned to Base block **58521896** (2026-11-17) inside
`test/MorpheusM01.t.sol`. The SessionRouter facet tested is
`0x3a3952F0e57B343F00B31f7da039Ef16389B7260`, the facet listed in the
program's Appendix A.

## Numbers at the pinned block

- Diamond MOR balance (user escrow): **258,713 MOR** (about $181,100 at
  $0.70/MOR)
- Funding account MOR balance: **85,131 MOR** (about $59,600 at $0.70/MOR)
- MOR price: about $0.70 (DexScreener, Base Aerodrome/Uniswap pools,
  2026-11-17)

## Layout

- `test/MorpheusM01.t.sol` - the PoC (two Foundry fork tests)
- `lib/forge-std/` - vendored Foundry standard library, so the repo builds
  from a plain clone with no extra install step
- `foundry.toml` - Foundry config (solc 0.8.28)
