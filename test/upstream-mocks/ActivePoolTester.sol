// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "../../src/upstream/ActivePool.sol";

contract ActivePoolTester is ActivePool {
    
    function unprotectedIncreaseLUSDDebt(uint _amount) external {
        LUSDDebt  = LUSDDebt.add(_amount);
    }

    function unprotectedPayable() external payable {
        ETH = ETH.add(msg.value);
    }
}
