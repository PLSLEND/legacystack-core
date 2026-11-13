// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

/*
* Redemption Buffer (LegacyStack LS_06 #100-#105).
*
* A wstETH pot inside the core that serves every redemption first, until it is empty. It is the
* recipient of all protocol revenue: OCT mint fees, OCT interest and wstETH redemption fees. OCT it
* receives (fees, interest, redemptions it served) is held as inventory and sold back through a
* standing offer at oracle par plus a fixed premium, which turns revenue into more wstETH in the pot.
* Anyone may add to the pot without a claim (fill) or as a reserve deposit that stays theirs (deposit:
* 180-day lock, withdrawable while the pot stays at target, time-served points for STACK emissions paid by
* a periphery contract). No admin.
*/
interface IRedemptionBuffer {

    event RedemptionServed(address indexed _redeemer, uint _octIn, uint _collOut, uint _collFee);
    event InventorySold(address indexed _buyer, uint _octOut, uint _collIn);
    event Filled(address indexed _from, uint _collAmount);
    event SurplusReleased(address indexed _to, uint _collAmount);
    event SkimServed(address indexed _owner, uint _octOut, uint _collIn, uint _cut, uint _rest);
    event Deposited(address indexed _depositor, uint _collAmount, uint _lockedUntil);
    event Withdrawn(address indexed _depositor, uint _collAmount);
    event FeeShared(uint _fee, uint _toDepositors);
    event FeesClaimed(address indexed _depositor, uint _collAmount);
    event DepositInherited(address indexed _owner, address indexed _heir, uint _collAmount, uint _fees);
    event DepositPaidOut(address indexed _owner, uint _collOut, uint _octOut, uint _left);

    function setAddresses(
        address _troveManagerAddress,
        address _borrowerOperationsAddress,
        address _priceFeedAddress,
        address _octTokenAddress,
        address _collateralTokenAddress,
        address _surplusSink,
        address _successionRegistryAddress
    ) external;

    // --- Views ---

    function pot() external view returns (uint);                    // wstETH held
    function inventory() external view returns (uint);              // OCT held
    function potValue(uint _price) external view returns (uint);    // pot in USD (18 decimals) at _price
    function circulatingSupply() external view returns (uint);      // OCT supply minus inventory
    function target() external view returns (uint);                 // USD value the pot aims for
    function redeemCapacity(uint _price) external view returns (uint); // OCT the buffer can take now
    function debtCeiling(uint _price) external view returns (uint); // $1M + $100 per $1 in the pot
    function quoteInventory(uint _octAmount, uint _price) external view returns (uint collIn);
    function offerPrice() external returns (uint);                  // the price the standing offer uses right now (refreshes the feed)
    function OFFER_PREMIUM() external view returns (uint);
    function ownPot() external view returns (uint);                 // wstETH that is the protocol's own
    function totalDeposits() external view returns (uint);          // depositors' principal, in wstETH
    function depositOf(address _depositor) external view returns (uint);
    function lockedUntil(address _depositor) external view returns (uint);
    function pointsOf(address _depositor) external view returns (uint); // wstETH-seconds served
    function feesOf(address _depositor) external view returns (uint);   // wstETH of shared fees claimable now
    function depositorsShareBps() external view returns (uint);         // the depositors' part of the next fee
    function feesOwed() external view returns (uint);                   // wstETH set aside for depositors, unclaimed
    function totalFeesShared() external view returns (uint);
    function releasable(uint _price) external view returns (uint);  // what the waterfall could release, before the daily cap

    // --- Actions ---

    // TroveManager only: the redeemer's OCT has already been moved into the buffer by the TroveManager;
    // send the collateral net of the redemption fee. Returns the collateral sent.
    function serveRedemption(address _redeemer, uint _octAmount, uint _price, uint _redemptionRate) external returns (uint);

    // TroveManager only: the fee of a redemption served by the vaults has arrived in the pot; share it (#171).
    function shareRedemptionFee(uint _fee) external;

    // Anyone: buy OCT from the inventory at oracle par + premium, paying wstETH.
    function buyInventory(uint _octAmount, uint _maxCollIn) external returns (uint collIn);

    // BorrowerOperations only (auto-repay, #160/#161): a vault's staking yield has been moved from the Active
    // Pool into the pot; sell _octAmount of inventory for it at the standing offer. _cut goes to the keeper,
    // _rest to the vault owner, and the remainder is burned by BorrowerOperations against the vault's debt.
    function serveSkim(address _owner, uint _octAmount, uint _collIn, address _cutTo, uint _cut, uint _rest) external;

    // Anyone: add wstETH to the pot. No claim is created.
    function fill(uint _collAmount) external;

    // Anyone: a reserve deposit. The wstETH stays the depositor's, serves redemptions like the rest of the
    // pot, is locked 180 days from the last deposit and withdrawable afterwards whenever the pot stays at or
    // above target after the withdrawal. Points (wstETH-seconds) accrue for the time served.
    function deposit(uint _collAmount) external;
    function withdraw(uint _collAmount) external;
    function checkpoint(address _depositor) external;

    // Anyone: take the shared fees earned so far, in wstETH (#171).
    function claimFees() external returns (uint);

    // SuccessionRegistry only: a dead depositor's deposit is paid out for the heirs, wstETH as far as the pot
    // stays at target, then OCT from the inventory; what is left stays a deposit (#172).
    function payoutForSuccession(address _owner, address _to) external returns (uint collOut, uint octOut, uint left);

    // SuccessionRegistry only: what payoutForSuccession could not pay passes to an heir as a deposit (#171).
    function transferDepositForSuccession(address _owner, address _heir, uint _collAmount) external;

    // Anyone: release what the waterfall allows today to the surplus sink.
    function releaseSurplus() external returns (uint);
}
