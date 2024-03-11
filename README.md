
# M^ZERO contest details

- Join [Sherlock Discord](https://discord.gg/MABEWyASkp)
- Submit findings using the issue page in your private contest repo (label issues as med or high)
- [Read for more details](https://docs.sherlock.xyz/audits/watsons)

# Q&A

### Q: On what chains are the smart contracts going to be deployed?
Mainnet
___

### Q: Which ERC20 tokens do you expect will interact with the smart contracts? 
WETH, $M (native token of the system)
___

### Q: Which ERC721 tokens do you expect will interact with the smart contracts? 
None
___

### Q: Do you plan to support ERC1155?
No
___

### Q: Which ERC777 tokens do you expect will interact with the smart contracts? 
None
___

### Q: Are there any FEE-ON-TRANSFER tokens interacting with the smart contracts?

None
___

### Q: Are there any REBASING tokens interacting with the smart contracts?

*Note: $POWER token has inflation and $M token is yield-bearing token, so those 2 can be considered REBASING tokens (native token of the system).
___

### Q: Are the admins of the protocols your contracts integrate with (if any) TRUSTED or RESTRICTED?
No specific admins. 
Protocol managed by governance.
___

### Q: Is the admin/owner of the protocol/contracts TRUSTED or RESTRICTED?
No specific admins. 
Protocol managed by governance.
___

### Q: Are there any additional protocol roles? If yes, please explain in detail:
Protocol has 3 specific roles - 
1. Minters - actors that are allowed to mint $M and pay fee for that.
2. Validators - actors that verify validity of collateral value of minters, and retrievals of collateral (offchain). Validators are able to freeze any minter for some period of time and cancel any minting request (onchain).
3. Earners - actors that receive $M yield by holding $M.
___

### Q: Is the code/contract expected to comply with any EIPs? Are there specific assumptions around adhering to those EIPs that Watsons should be aware of?
1. $M is an ERC20Extended token which is ERC20 token extended with EIP-2612 permits for signed approvals (via EIP-712 and with EIP-1271
and EIP-5267 compatibility), and extended with EIP-3009 transfer with authorization (via EIP-712).
2. $POWER token is ERC5805, ERC6372, ERC20Extended (see $M) with custom epoch-based snapshotting and inflation functionality.
3. $ZERO token is ERC5805, ERC6372, ERC20Extended (see $M) with custom epoch-based snapshotting functionality.
4. StandardGovernor, EmergencyGovernor, ZeroGovernor - OpenZeppelin-style governors, ERC6372, ERC712 compatible.

___

### Q: Please list any known issues/acceptable risks that should not result in a valid finding.
!!! These and other already described by Auditors issues with responded and acknowledged status. Especially INFO issues from Audit review document. [See doc Audit review document.] !!!

1. Issues related to offchain economics and relationships of actors. 
2. Trust assumptions in the system, offchain collusions between actors.
3. Validators superpower in blocking minter's requests or freezing minters.
4. Governance setting unrealistic values for protocol parameters. Time-delayed activation, deactivation of minters in Protocol comparing to change in TTG.
5. Dilution of small actors via RESETs.
6. Rounding imprecisions that caused by rounding in favor of protocol.
7. Unavoidable dust accumulation in Distribution vault.
8. Risks related to supplying $M, $POWER and/or $ZERO tokens into third party protocols.
9. Risk of buying portion of $ZERO, $POWER tokens at the end of epoch to sell them a few blocks later.
10. Invalidity of invariants with parameters outside of specified range.
11. Risk of fraction of `INITIAL_SUPPLY` will be unallocated after `resetToPowerHolders` if it happened during Transfer epoch
12. $POWER totalSupply not being equal to sum of balances during Voting epoch.
___

### Q: Please provide links to previous audits (if any).
All audits reports - https://github.com/MZero-Labs/sherlock-contest-docs

Joint audit review report - https://docs.google.com/document/d/1_q6pQSx9X3nXQJ66TreNJmFfj--c7IFuy9GQ-mU0eJo/edit?usp=sharing

Please check individual reports and joint Audit review document to see how issues were addressed or if some of them are design choices.
___

### Q: Are there any off-chain mechanisms or off-chain procedures for the protocol (keeper bots, input validation expectations, etc)?
- We expect valid collateral amounts and timestamp values provided by validators. 
- Periodic collateral updates will guarantee the bare minimum adequate use of protocol and update of Minter's and Earner's indices at least one per update collateral interval. [See engineering specs invariants section for more details].
- We implicitly trust SPV operators. [See https://docs.m0.org/portal].
___

### Q: In case of external protocol integrations, are the risks of external contracts pausing or executing an emergency withdrawal acceptable? If not, Watsons will submit issues related to these situations that can harm your protocol's functionality.
Not applicable
___

### Q: Do you expect to use any of the following tokens with non-standard behaviour with the smart contracts?
Note* Our own tokens - $POWER and $M have built-in inflation and earning mechanisms (rebasing) themselves.
___

### Q: Add links to relevant protocol resources
https://docs.m0.org/portal

https://github.com/MZero-Labs/sherlock-contest-docs

Joint audit review report https://docs.google.com/document/d/1_q6pQSx9X3nXQJ66TreNJmFfj--c7IFuy9GQ-mU0eJo




___



# Audit scope


[ttg @ 0d2761f8db14b390e923f59bdae9799fbf9adf2c](https://github.com/MZero-Labs/ttg/tree/0d2761f8db14b390e923f59bdae9799fbf9adf2c)
- [ttg/src/DistributionVault.sol](ttg/src/DistributionVault.sol)
- [ttg/src/EmergencyGovernor.sol](ttg/src/EmergencyGovernor.sol)
- [ttg/src/EmergencyGovernorDeployer.sol](ttg/src/EmergencyGovernorDeployer.sol)
- [ttg/src/PowerBootstrapToken.sol](ttg/src/PowerBootstrapToken.sol)
- [ttg/src/PowerToken.sol](ttg/src/PowerToken.sol)
- [ttg/src/PowerTokenDeployer.sol](ttg/src/PowerTokenDeployer.sol)
- [ttg/src/Registrar.sol](ttg/src/Registrar.sol)
- [ttg/src/StandardGovernor.sol](ttg/src/StandardGovernor.sol)
- [ttg/src/StandardGovernorDeployer.sol](ttg/src/StandardGovernorDeployer.sol)
- [ttg/src/ZeroGovernor.sol](ttg/src/ZeroGovernor.sol)
- [ttg/src/ZeroToken.sol](ttg/src/ZeroToken.sol)
- [ttg/src/abstract/BatchGovernor.sol](ttg/src/abstract/BatchGovernor.sol)
- [ttg/src/abstract/ERC5805.sol](ttg/src/abstract/ERC5805.sol)
- [ttg/src/abstract/EpochBasedInflationaryVoteToken.sol](ttg/src/abstract/EpochBasedInflationaryVoteToken.sol)
- [ttg/src/abstract/EpochBasedVoteToken.sol](ttg/src/abstract/EpochBasedVoteToken.sol)
- [ttg/src/abstract/ThresholdGovernor.sol](ttg/src/abstract/ThresholdGovernor.sol)
- [ttg/src/libs/PureEpochs.sol](ttg/src/libs/PureEpochs.sol)

[protocol @ 3382fb7336bbc7276e0c3f51da451c9fa6e0016f](https://github.com/MZero-Labs/protocol/tree/3382fb7336bbc7276e0c3f51da451c9fa6e0016f)
- [protocol/src/MToken.sol](protocol/src/MToken.sol)
- [protocol/src/MinterGateway.sol](protocol/src/MinterGateway.sol)
- [protocol/src/abstract/ContinuousIndexing.sol](protocol/src/abstract/ContinuousIndexing.sol)
- [protocol/src/libs/ContinuousIndexingMath.sol](protocol/src/libs/ContinuousIndexingMath.sol)
- [protocol/src/libs/TTGRegistrarReader.sol](protocol/src/libs/TTGRegistrarReader.sol)
- [protocol/src/rateModels/MinterRateModel.sol](protocol/src/rateModels/MinterRateModel.sol)
- [protocol/src/rateModels/StableEarnerRateModel.sol](protocol/src/rateModels/StableEarnerRateModel.sol)

[common @ 9da96e78d24aadd41ee6f776b7b028203782b632](https://github.com/MZero-Labs/common/tree/9da96e78d24aadd41ee6f776b7b028203782b632)
- [common/src/ContractHelper.sol](common/src/ContractHelper.sol)
- [common/src/ERC20Extended.sol](common/src/ERC20Extended.sol)
- [common/src/ERC3009.sol](common/src/ERC3009.sol)
- [common/src/ERC712Extended.sol](common/src/ERC712Extended.sol)
- [common/src/StatefulERC712.sol](common/src/StatefulERC712.sol)
- [common/src/libs/SignatureChecker.sol](common/src/libs/SignatureChecker.sol)
- [common/src/libs/UIntMath.sol](common/src/libs/UIntMath.sol)
