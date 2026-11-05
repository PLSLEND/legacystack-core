// SPDX-License-Identifier: MIT

pragma solidity 0.6.11;

/*
* Redemption Buffer (LegacyStack LS_06 #100-#105).
*
* A wstETH pot inside the core that serves every redemption first, until it is empty. It is the
* recipient of all protocol revenue: OCT mint fees, OCT interest and wstETH redemption fees. OCT it
* receives (fees, interest, redemptions it served) is held as inventory and sold back through a
* standing offer at oracle par plus a fixed premium, which turns revenue into more wstETH in the pot.
* Anyone may add to the pot; nobody has a claim on it. No admin.
*/
interface IRedemptionBuffer {

    event RedemptionServed(address indexed _redeemer, uint _octIn, uint _collOut, uint _collFee);
    event InventorySold(address indexed _buyer, uint _octOut, uint _collIn);
    event Filled(address indexed _from, uint _collAmount);
    event SurplusReleased(address indexed _to, uint _collAmount);

    function setAddresses(
        address _troveManagerAddress,
        address _priceFeedAddress,
        address _octTokenAddress,
        address _collateralTokenAddress
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

    // --- Actions ---

    // TroveManager only: the redeemer's OCT has already been moved into the buffer by the TroveManager;
    // send the collateral net of the redemption fee. Returns the collateral sent.
    function serveRedemption(address _redeemer, uint _octAmount, uint _price, uint _redemptionRate) external returns (uint);

    // Anyone: buy OCT from the inventory at oracle par + premium, paying wstETH.
    function buyInventory(uint _octAmount, uint _maxCollIn) external returns (uint collIn);

    // Anyone: add wstETH to the pot. No claim is created.
    function fill(uint _collAmount) external;

    // Anyone: when the pot is far above target, release a bounded slice to the surplus sink.
    function releaseSurplus() external returns (uint);
}
