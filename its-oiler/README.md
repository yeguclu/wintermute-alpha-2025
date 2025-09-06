It's Oiler

Oi, you’re enjoying your cuppa tea and scrolling Twitter, where you noticed the post that Euler was exploited an hour ago (it’s block 16818350 now). Realizing that you have exposure to it by depositing ETH previously and holding 4.7k eWETH at the moment, you want to save as much out as you can.

Withdraw as much as you can from Euler markets with supply still left in them. With a hack of this size, you think it’s over. Dump all tokens you gathered into USDC and end with at least 2.5M USDC in your wallet.

We ended with 4M USDC, let us know if you beat it.

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
