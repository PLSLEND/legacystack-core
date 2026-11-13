// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

import "./Interfaces/ISuccessionRegistry.sol";
import "../upstream/Interfaces/ITroveManager.sol";
import "../upstream/Interfaces/IStabilityPool.sol";
import "../upstream/Interfaces/ICollSurplusPool.sol";
import "../upstream/Interfaces/IBorrowerOperations.sol";
import "../upstream/Interfaces/ILUSDToken.sol";
import "./Interfaces/IRedemptionBuffer.sol";
import "../upstream/Dependencies/IERC20.sol";
import "../upstream/Dependencies/SafeMath.sol";
import "../upstream/Dependencies/BaseMath.sol";
import "../upstream/Dependencies/Ownable.sol";
import "../upstream/Dependencies/CheckContract.sol";
import "../upstream/Dependencies/LiquityMath.sol";

/*
* Succession Registry. See ISuccessionRegistry for the rules. Ownable only for setAddresses, then renounced.
*
* Liveness: setPlan() starts the clock and proveLife() is the only call that resets it. Nothing the owner
* does in the vault or the Stability Pool counts, and nothing anyone else does ever counts, so a keeper, an
* agent or a bot cannot keep a dead owner's vault alive, and an owner is never kept alive by accident.
*
* Execution is idempotent and retryable: each call does as much as the available liquidity allows,
* records what it holds for the estate, and finishes with the push once the vault is closed.
*/
contract SuccessionRegistry is BaseMath, Ownable, CheckContract, ISuccessionRegistry {
    using SafeMath for uint256;

    string constant public NAME = "SuccessionRegistry";

    uint constant public PROOF_PERIOD = 365 days;     // one year without a proof of life: the plan is due
    uint constant public RETURN_WINDOW = 30 days;     // then 30 days in which the owner's proof still cancels
    uint constant public MAX_HEIRS = 10;
    uint constant public BPS = 10000;
    uint public immutable REWARD_BPS;                 // executor reward, share of the collateral released
    uint public immutable REWARD_CAP;                 // executor reward cap, in collateral units

    IBorrowerOperations public borrowerOperations;
    ITroveManager public troveManager;
    IStabilityPool public stabilityPool;
    ICollSurplusPool public collSurplusPool;
    ILUSDToken public octToken;
    IERC20 public collateralToken;
    IRedemptionBuffer public redemptionBuffer;

    struct Heir {
        address account;
        uint16 bps;
    }

    struct Plan {
        Heir[] heirs;
        address fallbackHeir;
        uint lastProof;
        bool executed;
    }

    // What the registry holds for an estate between the settlement steps of one execution.
    struct Estate {
        uint oct;
        uint coll;
        bool spWithdrawn;
    }

    mapping(address => Plan) internal plans;
    mapping(address => Estate) internal estates;
    mapping(address => mapping(address => uint)) internal escrow; // heir => token => amount

    constructor(uint _rewardBps, uint _rewardCap) public {
        require(_rewardBps <= 100, "SuccessionRegistry: reward above 1%");
        REWARD_BPS = _rewardBps;
        REWARD_CAP = _rewardCap;
    }

    // --- Setup ---

    function setAddresses(
        address _borrowerOperationsAddress,
        address _troveManagerAddress,
        address _stabilityPoolAddress,
        address _collSurplusPoolAddress,
        address _octTokenAddress,
        address _collateralTokenAddress,
        address _redemptionBufferAddress
    )
        external
        override
        onlyOwner
    {
        checkContract(_borrowerOperationsAddress);
        checkContract(_troveManagerAddress);
        checkContract(_stabilityPoolAddress);
        checkContract(_collSurplusPoolAddress);
        checkContract(_octTokenAddress);
        checkContract(_collateralTokenAddress);
        checkContract(_redemptionBufferAddress);

        borrowerOperations = IBorrowerOperations(_borrowerOperationsAddress);
        troveManager = ITroveManager(_troveManagerAddress);
        stabilityPool = IStabilityPool(_stabilityPoolAddress);
        collSurplusPool = ICollSurplusPool(_collSurplusPoolAddress);
        octToken = ILUSDToken(_octTokenAddress);
        collateralToken = IERC20(_collateralTokenAddress);
        redemptionBuffer = IRedemptionBuffer(_redemptionBufferAddress);

        _renounceOwnership();
    }

    // --- Owner actions ---

    function setPlan(address[] calldata _accounts, uint16[] calldata _bps, address _fallbackHeir) external override {
        require(_accounts.length > 0 && _accounts.length <= MAX_HEIRS, "SuccessionRegistry: 1 to 10 heirs");
        require(_accounts.length == _bps.length, "SuccessionRegistry: length mismatch");
        require(_fallbackHeir != msg.sender, "SuccessionRegistry: fallback heir is the owner");
        Plan storage plan = plans[msg.sender];
        delete plan.heirs;
        uint totalBps;
        for (uint i = 0; i < _accounts.length; i++) {
            require(_accounts[i] != address(0), "SuccessionRegistry: zero heir");
            require(_accounts[i] != msg.sender, "SuccessionRegistry: heir is the owner");
            require(_accounts[i] != address(this), "SuccessionRegistry: heir is the registry");
            require(_bps[i] > 0, "SuccessionRegistry: zero share");
            for (uint j = 0; j < i; j++) {
                require(_accounts[j] != _accounts[i], "SuccessionRegistry: duplicate heir");
            }
            totalBps = totalBps.add(_bps[i]);
            plan.heirs.push(Heir(_accounts[i], _bps[i]));
        }
        require(totalBps == BPS, "SuccessionRegistry: shares must total 100%");
        plan.fallbackHeir = _fallbackHeir;
        plan.executed = false;
        _returnEstate(msg.sender);
        _prove(msg.sender);
        emit PlanSet(msg.sender, _accounts.length, _fallbackHeir);
    }

    function clearPlan() external override {
        Plan storage plan = plans[msg.sender];
        require(plan.heirs.length > 0, "SuccessionRegistry: no plan");
        _returnEstate(msg.sender);
        delete plans[msg.sender];
        emit PlanCleared(msg.sender);
    }

    function proveLife() external override {
        require(plans[msg.sender].heirs.length > 0, "SuccessionRegistry: no plan");
        _returnEstate(msg.sender);
        _prove(msg.sender);
    }

    // --- Views ---

    function getHeirs(address _owner) external view override returns (address[] memory accounts, uint16[] memory bps) {
        Heir[] storage heirs = plans[_owner].heirs;
        accounts = new address[](heirs.length);
        bps = new uint16[](heirs.length);
        for (uint i = 0; i < heirs.length; i++) {
            accounts[i] = heirs[i].account;
            bps[i] = heirs[i].bps;
        }
    }

    function getFallbackHeir(address _owner) external view override returns (address) {
        return plans[_owner].fallbackHeir;
    }

    function lastProof(address _owner) external view override returns (uint) {
        return plans[_owner].lastProof;
    }

    function hasPlan(address _owner) external view override returns (bool) {
        return plans[_owner].heirs.length > 0;
    }

    function successionState(address _owner) public view override returns (uint8 state, uint dueAt, uint executableAt) {
        Plan storage plan = plans[_owner];
        if (plan.heirs.length == 0) { return (0, 0, 0); }
        dueAt = plan.lastProof.add(PROOF_PERIOD);
        executableAt = dueAt.add(RETURN_WINDOW);
        if (plan.executed) { return (4, dueAt, executableAt); }
        if (block.timestamp < dueAt) { return (1, dueAt, executableAt); }
        if (block.timestamp < executableAt) { return (2, dueAt, executableAt); }
        return (3, dueAt, executableAt);
    }

    function escrowOf(address _heir, address _token) external view override returns (uint) {
        return escrow[_heir][_token];
    }

    function estateOf(address _owner) external view returns (uint oct, uint coll, bool spWithdrawn) {
        Estate storage e = estates[_owner];
        return (e.oct, e.coll, e.spWithdrawn);
    }

    // --- Execution (permissionless) ---

    function execute(address _owner) external override {
        (uint8 state,,) = successionState(_owner);
        require(state == 3, "SuccessionRegistry: not executable");
        Estate storage estate = estates[_owner];

        // 1. The estate's own Stability Pool deposit and gains come to the registry first.
        if (!estate.spWithdrawn) {
            (uint octOut, uint collOut) = stabilityPool.withdrawForSuccession(_owner, address(this));
            estate.oct = estate.oct.add(octOut);
            estate.coll = estate.coll.add(collOut);
            estate.spWithdrawn = true;
        }

        // 2. The vault: debt settled at par with the estate's OCT, then buffer inventory, then the Stability Pool.
        if (troveManager.getTroveStatus(_owner) == 1) {
            (uint octUsed, bool closed, uint collReleased) = borrowerOperations.settleForSuccession(_owner, estate.oct);
            estate.oct = estate.oct.sub(octUsed);
            estate.coll = estate.coll.add(collReleased);
            emit SuccessionSettled(_owner, octUsed, closed);
            if (!closed) { return; } // not enough settlement liquidity today; anyone can call again later
        }

        // 3. Collateral left behind by an earlier full redemption or a Recovery Mode liquidation.
        uint surplus = collSurplusPool.getCollateral(_owner);
        if (surplus > 0) {
            borrowerOperations.claimCollateralForSuccession(_owner, address(this));
            estate.coll = estate.coll.add(surplus);
        }

        // 4. The reserve deposit, paid out for the heirs: wstETH as far as the reserve stays at target, then OCT
        //    from its inventory; what neither covers passes as deposits below (#172).
        uint left;
        if (redemptionBuffer.depositOf(_owner) > 0 || redemptionBuffer.feesOf(_owner) > 0) {
            (uint collPaid, uint octPaid, uint rest) = redemptionBuffer.payoutForSuccession(_owner, address(this));
            estate.coll = estate.coll.add(collPaid);
            estate.oct = estate.oct.add(octPaid);
            left = rest;
        }

        // 5. Reward the executor from the estate, then push everything to the heirs.
        uint coll = estate.coll;
        uint oct = estate.oct;
        uint reward = LiquityMath._min(coll.mul(REWARD_BPS).div(BPS), REWARD_CAP);
        if (reward > 0) {
            coll = coll.sub(reward);
            require(collateralToken.transfer(msg.sender, reward), "SuccessionRegistry: reward transfer failed");
        }
        delete estates[_owner];
        plans[_owner].executed = true;

        Plan storage plan = plans[_owner];
        _distribute(_owner, plan, address(collateralToken), coll);
        _distribute(_owner, plan, address(octToken), oct);

        // 6. Whatever the reserve could not pay out today passes as deposits, by the same shares (#171).
        if (left > 0) { _passDeposit(_owner, plan); }

        emit SuccessionExecuted(_owner, msg.sender, coll, oct, reward);
    }

    function claimEscrow(address _token) external override {
        uint amount = escrow[msg.sender][_token];
        require(amount > 0, "SuccessionRegistry: nothing in escrow");
        escrow[msg.sender][_token] = 0;
        require(IERC20(_token).transfer(msg.sender, amount), "SuccessionRegistry: transfer failed");
        emit EscrowClaimed(msg.sender, _token, amount);
    }

    // --- Internal ---

    function _prove(address _owner) internal {
        plans[_owner].lastProof = block.timestamp;
        emit LifeProven(_owner, block.timestamp);
    }

    // An owner who acts while a partial settlement is in progress is alive: hand back what the registry holds.
    function _returnEstate(address _owner) internal {
        Estate storage e = estates[_owner];
        if (e.oct == 0 && e.coll == 0 && !e.spWithdrawn) { return; }
        uint oct = e.oct;
        uint coll = e.coll;
        delete estates[_owner];
        if (oct > 0) { require(octToken.transfer(_owner, oct), "SuccessionRegistry: OCT return failed"); }
        if (coll > 0) { require(collateralToken.transfer(_owner, coll), "SuccessionRegistry: collateral return failed"); }
    }

    function _passDeposit(address _owner, Plan storage _plan) internal {
        uint amount = redemptionBuffer.depositOf(_owner);
        if (amount == 0) { return; }
        uint n = _plan.heirs.length;
        uint remaining = amount;
        for (uint i = 0; i < n; i++) {
            Heir storage heir = _plan.heirs[i];
            uint share = (i == n - 1) ? remaining : amount.mul(heir.bps).div(BPS);
            remaining = remaining.sub(share);
            if (share == 0) { continue; }
            redemptionBuffer.transferDepositForSuccession(_owner, heir.account, share);
            emit DepositPassed(_owner, heir.account, share);
        }
    }

    function _distribute(address _owner, Plan storage _plan, address _token, uint _amount) internal {
        if (_amount == 0) { return; }
        uint n = _plan.heirs.length;
        uint remaining = _amount;
        for (uint i = 0; i < n; i++) {
            Heir storage heir = _plan.heirs[i];
            uint share = (i == n - 1) ? remaining : _amount.mul(heir.bps).div(BPS);
            remaining = remaining.sub(share);
            _push(_owner, _plan, heir.account, _token, share);
        }
    }

    function _push(address _owner, Plan storage _plan, address _heir, address _token, uint _amount) internal {
        if (_amount == 0) { return; }
        if (_tryTransfer(_token, _heir, _amount)) { emit Pushed(_owner, _heir, _token, _amount); return; }
        address fallbackHeir = _plan.fallbackHeir;
        if (fallbackHeir != address(0) && _tryTransfer(_token, fallbackHeir, _amount)) {
            emit Pushed(_owner, fallbackHeir, _token, _amount);
            return;
        }
        escrow[_heir][_token] = escrow[_heir][_token].add(_amount);
        emit Escrowed(_heir, _token, _amount);
    }

    function _tryTransfer(address _token, address _to, uint _amount) internal returns (bool) {
        try IERC20(_token).transfer(_to, _amount) returns (bool ok) {
            return ok;
        } catch {
            return false;
        }
    }
}
