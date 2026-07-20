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
