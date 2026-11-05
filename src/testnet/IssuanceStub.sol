// SPDX-License-Identifier: MIT
pragma solidity 0.6.11;

/// Phase-0 stand-in for Liquity's CommunityIssuance (LQTY emissions to the Stability Pool).
/// Issues nothing. STACK emissions are a separate peripheral in the LegacyStack design.
contract IssuanceStub {
    function issueLQTY() external returns (uint) { return 0; }
    function sendLQTY(address, uint) external {}
}
