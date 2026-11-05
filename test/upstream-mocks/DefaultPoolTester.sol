// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../../src/upstream/DefaultPool.sol";

contract DefaultPoolTester is DefaultPool {
    
    function unprotectedIncreaseLUSDDebt(uint _amount) external {
        LUSDDebt  = LUSDDebt.add(_amount);
    }

    function unprotectedPayable() external payable {
        ETH = ETH.add(msg.value);
    }
}
