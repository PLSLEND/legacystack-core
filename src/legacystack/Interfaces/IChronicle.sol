// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;
// The one Chronicle view the core reads: the ETH/USD value (18 decimals) and the timestamp it was set.
// Chronicle (Maker's oracle network since 2017): no token, no DEX, reads gated by a toll the deployment
// is admitted to once (SelfKisser on mainnet). LegacyStack LS_06 #160.
interface IChronicle {
    function readWithAge() external view returns (uint256 value, uint256 age);
}
