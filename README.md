# Challenge-Aware Finality (CAF) — prototype

CAF lets an authorized challenger contest an illicit ERC-20 transfer: the
contested value is escrowed on-chain, a validator committee reviews a recovery
proof, and the funds end either recovered to a victim address or released back
to the recipient.

## Architecture

The deployable application is exactly three contracts (`src/`):

| Contract | Role |
| --- | --- |
| `CAFToken` | ERC-20 with per-transfer state machine, LIFO attribution lots and real escrow |
| `ChallengeRegistry` | Immutable challenger set; one evidence commitment per challenge |
| `ValidatorCommittee` | Immutable validator set; one supermajority ballot per proof |

`CAFToken` deploys the other two in its constructor. A transfer moves through:

```text
Pending → Valid → Challenged → Released | Recovered
        ↘ Challenged (pre-challenge of a predicted transfer id)
```

All entry points (`submitTransfer`, ERC-20 `transfer`/`transferFrom`) route
through the same state machine. Positive incoming transfers create attribution
lots consumed newest-first (LIFO); a challenge before the deadline escrows only
the still-attributable residual. A pre-challenge targets a predicted transfer
id: `submitTransfer` intercepts it into escrow, while a pre-challenged standard
`transfer`/`transferFrom` reverts — `true` always means the recipient was
credited (strict ERC-20). A deployment-time supermajority quorum of validators
decides a proof; review-window expiry without an Accept decision makes release
possible.

## Deploying

`script/Deploy.s.sol` deploys the whole application — `CAFToken` (which creates
`ChallengeRegistry` and `ValidatorCommittee`) plus an optional `ReferenceERC20`
baseline — from environment configuration, and prints the deployed addresses.

Set the parameters, then run the script. The broadcasting account is supplied by
Forge (`--account <name>`, `--private-key <key>`, or `--ledger`):

```bash
export CAF_INITIAL_HOLDER=0x...          # credited with the whole initial supply
export CAF_INITIAL_SUPPLY=1000000000000000000000000
export CAF_CHALLENGE_WINDOW=604800       # seconds (0 < w ≤ 3650 days)
export CAF_REVIEW_WINDOW=172800          # seconds (0 < w ≤ 3650 days)
export CAF_CHALLENGERS=0xC1,0xC2         # comma-separated authorised challengers
export CAF_VALIDATORS=0xD1,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7
export CAF_QUORUM=5                       # 3·quorum > 2·validators
# optional: CAF_NAME, CAF_SYMBOL, CAF_DEPLOY_REFERENCE=true

forge script script/Deploy.s.sol:Deploy \
  --rpc-url "$RPC_URL" --account deployer --broadcast
```

Drop `--broadcast` for a local simulation. The `CAFToken` constructor validates
every parameter — non-zero holder, bounded windows, non-empty distinct
membership sets, supermajority quorum — and reverts with a precise error.
