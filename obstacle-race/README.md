# Obstacle Race - MEV Bot Frontrun Simulation

## Challenge Description

You're an operator of one of the most successful generalized MEV bots and often prevent exploits before they even happen. But when the CRV/ETH hack happened, your setup wasn't capable of performing a whitehat. You decided to take the [contract deployment transaction](https://etherscan.io/tx/0x09f97e8053ba1b557dd9811d6572328a2cddc7d8576fc048af0a64c644d67edd), modify the bytecode (to learn how to handle similar situations in the future), and test it in a forked environment.

**Goal**: Execute the frontrun with this modified contract and then withdraw all saved funds to your wallet.

## Strategy Details

### 1. Hash Bypass Mechanism
- The original exploit had a double keccak hash check to prevent unauthorized execution
- By generating a hash from our own address, we can bypass this protection

### 2. Bytecode Modification
- Takes the original exploit bytecode as a template
- Replaces hash verification in bytecode
- Maintains all original functionality while bypassing access controls

### 3. Execution Sequence
- **Deploy**: Deploy the modified contract to the blockchain
- **Execute**: Call the exploit function with the same parameters the original exploiter used
- **Withdraw**: Extract all captured funds to our wallet
