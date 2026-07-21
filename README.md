# Cardano Lotto Hello World

This is a small first Cardano/Plinth smart-contract project.

It is based on the Plinth template project, so the development setup starts
from a known working structure instead of requiring you to assemble the tooling
from scratch.

It is not meant to be a perfect or production-ready lottery. It is a playful
"hello world" for learning how the Cardano smart-contract world fits together:
the project structure, validator code, local environment, checks, generated
artifacts, and the general path from idea to something deployable.

The contract is a simple decentralized lotto: users buy tickets, the pot grows,
and a draw later selects winners using external randomness.

The point is to learn by touching the whole shape of a real application without
pretending it is already a serious protocol. A lottery is small enough to reason
about, but still exposes useful Cardano questions: where state lives, who is
allowed to change it, how money is checked, and how off-chain code must prepare
transactions that the on-chain validator will accept.

It is also a good way to notice smart-contract limits. A validator can check
rules, signatures, values, deadlines, and transaction structure. It cannot run a
website, call the internet, privately generate randomness, or fix a vague
business rule. Those parts have to be designed around the contract.

The main on-chain lotto code lives in [src/LottoValidator.hs](src/LottoValidator.hs).
For the local test setup and how to add new validator tests, read the
[smart contract testing guide](docs/test/testing-guide.md).

Read the docs by depth:

Intro-level docs:

1. [Business overview](docs/overview/business-overview.md) explains the lottery idea, the actors, and the business rules without requiring Cardano or Plutus knowledge.
2. [Product overview](docs/overview/product-overview.md) describes the user-facing application flow and what the product needs to make the protocol usable.

More detailed architecture:

1. [Protocol architecture](docs/technical/protocol-architecture.md) explains how the lottery state, tickets, draw lifecycle, funds, and transaction responsibilities fit together across the system.

Very technical docs:

1. [Plutus architecture](docs/technical/plutus-architecutre.md) explains the on-chain validator shape, datum/redeemer/context handling, and how Plinth code enforces the protocol rules.
2. [Randomness/oracle architecture](docs/oracle/randomness-architecture.md) explains why randomness must come from outside the validator and how oracle data is expected to enter the draw process.
3. [Backend role overview](docs/technical/backend-role-overview.md) explains what the off-chain backend prepares, watches, and submits so users can interact with the on-chain contract safely.

Use this as a small warm-up before building a larger, more mature Cardano
application.
