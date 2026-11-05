// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

// The one Lido view the core reads: stETH per wstETH, 18 decimals. It only moves with Lido's
// accounting oracle report (daily, bounded), never with a market trade. LegacyStack SR-1.
interface IWstETH {
    function stEthPerToken() external view returns (uint256);
}
