# Decentralized Stablecoin (DSC)

A minimal, overcollateralized, exogenous stablecoin protocol built from scratch in Solidity and Foundry.

The system is designed to maintain a 1 DSC == $1 peg at all times, backed exclusively by WETH and WBTC collateral. It is similar to DAI if DAI had no governance, no fees, and was backed by only two assets.

> **Note:** This is a learning project, not production-ready code. It has known limitations and has not been audited.

---

## Architecture

| Contract | Responsibility |
|---|---|
| `DecentralizedStableCoin.sol` | ERC-20 token. `mint` and `burn` are gated to the engine (owner). |
| `DSCEngine.sol` | Core protocol logic. Handles deposits, mints, redemptions, burns, and liquidations. |
| `OracleLib.sol` | Wraps Chainlink price feeds with a staleness check. Reverts if prices are older than 3 hours. |
| `Handler.t.sol` | Fuzz testing harness. Curates valid inputs for the invariant suite. |
| `Invariants.t.sol` | Stateful fuzz tests asserting protocol-wide invariants. |

### System properties

- **Exogenously collateralized** — collateral comes from outside the protocol (WETH, WBTC).
- **Dollar pegged** — target is $1 per DSC.
- **Algorithmically stable** — minting and burning are controlled by code, not a human.
- **Overcollateralized** — total collateral value must always exceed total DSC supply.

---

## How it works

### Depositing collateral

Users deposit WETH or WBTC into the engine. The engine tracks each user's deposit in `s_collateralDeposited`.

### Minting DSC

Users mint DSC against their deposited collateral. The engine enforces a **50% liquidation threshold**, meaning a user can only borrow up to 50% of their collateral's USD value. This creates a 200% collateralization requirement.

### Health factor

Each position has a health factor:

Health Factor = (Collateral Value × Liquidation Threshold) / Total DSC Minted


- `>= 1.0` → healthy
- `< 1.0` → liquidatable

### Redeeming and burning

Users can redeem collateral (as long as it doesn't break their health factor) and burn DSC to reduce their debt.

### Liquidation

If a user's health factor drops below 1.0, anyone can liquidate them:

1. The liquidator burns DSC to cover part of the user's debt.
2. The liquidator receives the equivalent collateral, plus a **10% bonus**.
3. The user's health factor must improve after the liquidation.

The bonus is the incentive that keeps the protocol solvent.

---

## Oracle safety

All price reads go through `OracleLib.staleCheckLatestRoundData()`, which reverts if the Chainlink feed hasn't updated in 3 hours. If prices go stale, the entire protocol freezes. This is by design — operating on stale prices is more dangerous than halting.

---

## Testing

The test suite covers three levels:

### Unit tests (`test/unit/`)

- Constructor validation
- Price conversion math
- Deposit / mint / redeem / burn success and revert paths
- Health factor calculations
- Liquidation mechanics

### Fuzz tests (`test/fuzz/`)

The handler curates valid inputs for the fuzzer:

- `depositCollateral` — picks a valid token, mints and approves, deposits
- `mintDsc` — picks an actor with collateral, bounds the amount to stay healthy
- `redeemCollateral` — bounds to the actor's balance
- `updateCollateralPrice` — simulates price volatility

### Invariant tests

The core invariant:

collateralValue >= totalDscSupply


The fuzzer explores random sequences of valid actions and asserts this invariant after each one.

Run everything:

```bash
forge test
```

Run only invariants:
```bash
forge test --mt invariant
```

Check coverage:

```bash
forge coverage
```
## Setup

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Install

```bash
git clone https://github.com/ven01z/foundry-defi-stablecoin.git
cd foundry-defi-stablecoin
forge install
forge build
```

## Security notes

All external calls follow Checks-Effects-Interactions where possible.

nonReentrant guards on state-changing functions.

Custom errors throughout for gas efficiency and clarity.

NatSpec on all public functions.

Oracle staleness protection via OracleLib.

## Credits
Built while following the Cyfrin Updraft Advanced Foundry course, Section 3: Develop a DeFi Protocol.

Based on the MakerDAO DSS system.


