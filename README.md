# BondingCurve — StrongMoon

`BondingCurve` is the core meme-token launch contract for epow.io ecosystem.

It sells a newly created ERC-20 token along a bonding curve, accrues ETHW inside the contract, and when the curve reaches a configured threshold it automatically seeds a **full-range Uniswap V3 position** (WETHW pair), sends the LP-NFT to a collector (locker / multisig), and then allows the protocol owner to withdraw residual platform escrow for that token.

This repo assumes ETHW mainnet (chainId 10001) with a WETHW wrapper and a Uniswap V3 factory + position manager deployed.

---

## Deployed contract (ETHW mainnet)

- BondingCurve contract address:  
  `0x9618602879D026c706796329Cd153DE3617cCCa1`

- Verified on OKLink (EthereumPoW):  
  https://www.oklink.com/ethereum-pow/address/0x9618602879d026c706796329cd153de3617ccca1/contract

---

## Key properties

- **No-code token creation**
  - `createToken(name, symbol)` deploys a minimal ERC-20 (`Token.sol`) bound to this bonding curve.
  - Enforces an exact `creationFeeWei` (default `0.1 ETHW`), credited as platform escrow for that token.

- **Linear bonding curve**
  - Price in wei per whole token:
    - `P(n) = INITIAL_PRICE_WEI + n * INCREMENT_WEI`
  - Buy cost for `amount` tokens is the arithmetic series sum from current supply.
  - Hard caps:
    - `MAX_SUPPLY` — absolute supply ceiling.
    - `CURVE_CAP` — maximum tokens sellable via bonding curve.
    - `LP_CAP_INITIAL` — crossing this triggers V3 LP seeding.
    - `LP_CAP` — base number of tokens minted into LP.

- **ETHW accounting**
  - Each buy:
    - 1% buy tax to `feeCollector`.
    - Principal (`cost`) stays inside the contract as `tokenFunds[token]`.
  - Each sell (before LP seeded):
    - 1% sell tax to `feeCollector`.
   

- **Uniswap V3 auto-LP (WETHW pair)**
  - When total curve supply for a token reaches `LP_CAP_INITIAL`:
    - Compute remaining tokens to `CURVE_CAP`.
    - Mint `LP_CAP + remainingToCap` tokens to the contract.
    - Wrap all `tokenFunds[token]` ETHW into WETHW.
    - Compute an initial price and encode `sqrtPriceX96`.
    - Ensure a V3 pool exists and is initialized.
    - Mint a **full-range** V3 position, send the LP-NFT to `lpCollector`.
    - Send leftover token/WETHW dust and free ETHW (above global escrow) to `lpCollector`.
    - Reset `tokenFunds[token]` to `0` for that token.
  - One-shot per token:
    - `lpCreated[token]` / `lpSeeded[token]` flags prevent reseeding.

- **Escrow + residual withdrawal**
  - Per-token escrow:
    - `platformEscrow[token]` accumulates:
      - Creation fee for that token.
      - Any external top-ups via `topUpEscrow`.
      - Reductions when platform tax is paid out of escrow.
  - Global escrow:
    - `totalEscrow` tracks sum of all per-token escrows.
  - After LP is seeded for a token:
    - Contract owner can call `withdrawResidualAfterBonding(token, to)` to withdraw remaining escrow **only for that token**.
    - This is blocked until `lpSeeded[token] == true`.

---

## Contracts

### `contracts/BondingCurve.sol`

Main launchpad contract.

**Constructor**

```solidity
constructor(
    address payable _contractCreator,
    address _WETHW,
    address _v3Factory,
    address _posm
)
