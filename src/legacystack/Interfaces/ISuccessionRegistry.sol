// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

/*
* Succession Registry (LegacyStack LS_06 #129, #135, #136; LS_22 rows 12-14).
*
* One liveness record per owner, not per vault. The owner names up to ten heirs by basis points and a
* fallback heir. Setting the plan starts the clock; afterwards ONLY proveLife() resets it (#160): no vault
* action, pool action or third-party action counts, so routine automation can never look like a living
* owner and a bot cannot keep a dead owner's vault alive. After PROOF_PERIOD without a proof the plan is
* due; after RETURN_WINDOW more it is executable by anyone: the vault's debt is settled at par (buffer
* inventory first, then Stability Pool), the vault is closed, and collateral, Stability Pool deposit and
* gains are PUSHED to the heirs. A push that cannot be delivered is held in escrow for that heir. The
* executor is paid a small reward from the estate. No death oracle, no admin, no third party.
*/
interface ISuccessionRegistry {

    event PlanSet(address indexed _owner, uint _heirCount, address _fallbackHeir);
    event PlanCleared(address indexed _owner);
    event LifeProven(address indexed _owner, uint _timestamp);
    event SuccessionSettled(address indexed _owner, uint _debtSettled, bool _closed);
    event SuccessionExecuted(address indexed _owner, address indexed _executor, uint _collDistributed, uint _octDistributed, uint _reward);
    event Pushed(address indexed _owner, address indexed _heir, address _token, uint _amount);
    event Escrowed(address indexed _heir, address _token, uint _amount);
    event EscrowClaimed(address indexed _heir, address _token, uint _amount);

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _collSurplusPoolAddress,
        address _octTokenAddress,
        address _collateralTokenAddress
    ) external;

    // --- Owner actions ---
    // _accounts[i] receives _bps[i] / 10000 of everything; shares must total 10000; at most 10 heirs.
    // setPlan starts (or restarts) the clock; proveLife is the only other action that resets it.
    function setPlan(address[] calldata _accounts, uint16[] calldata _bps, address _fallbackHeir) external;
    function clearPlan() external;
    function proveLife() external;

    // --- Views ---
    function getHeirs(address _owner) external view returns (address[] memory accounts, uint16[] memory bps);
    function getFallbackHeir(address _owner) external view returns (address);
    function lastProof(address _owner) external view returns (uint);
    function hasPlan(address _owner) external view returns (bool);
    // 0 = no plan, 1 = active, 2 = due (owner-return window), 3 = executable, 4 = executed
    function successionState(address _owner) external view returns (uint8 state, uint dueAt, uint executableAt);
    function escrowOf(address _heir, address _token) external view returns (uint);

    // --- Permissionless ---
    function execute(address _owner) external;
    function claimEscrow(address _token) external;
}
