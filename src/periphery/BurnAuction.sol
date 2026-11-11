// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/*
* Burn auction (LS_06 #160): the STACK sink that needs no venue. It holds the wstETH the reserve's waterfall
* releases to it and sells it, lot by lot, in rolling Dutch auctions paid in STACK; the STACK is burned, the
* wstETH goes to the buyer. The price in STACK per wstETH starts high and falls over 48 hours to a tenth of
* its start, then holds there until someone buys; the next lot starts at twice the last clearing price. No
* pool, no router, no keys, no oracle: two tokens and a clock, so it works in any decade and the buyers bring
* the market to the protocol. Periphery: holds only what is on offer, has no owner, changes no rule.
*/
interface IAuctionERC20 { function balanceOf(address) external view returns (uint); function transfer(address, uint) external returns (bool); function transferFrom(address, address, uint) external returns (bool); }
interface IAuctionStack is IAuctionERC20 { function burn(uint) external; }

contract BurnAuction {
    IAuctionStack public immutable stack;
    IAuctionERC20 public immutable collateralToken;
    uint public immutable lotSize;                  // wstETH per lot; the last lot is whatever is left
    uint public constant DECAY = 48 hours;          // the price falls over this window ...
    uint public constant FLOOR_BPS = 1000;          // ... to 10% of the lot's start price, then holds

    uint public startPrice;                         // STACK per wstETH (18 decimals) at the start of the lot
    uint public lotStart;                           // when the current lot opened
    bool public empty;                              // nothing on offer since the last sale
    uint public totalSold;                          // wstETH sold so far
    uint public totalBurned;                        // STACK burned so far

    event Sold(address indexed buyer, uint collOut, uint stackBurned, uint price, uint nextStartPrice);
    event LotOpened(uint startPrice, uint onOffer);

    constructor(address _stack, address _collateralToken, uint _lotSize, uint _firstStartPrice) {
        require(_stack != address(0) && _collateralToken != address(0), "BurnAuction: zero address");
        require(_lotSize > 0 && _firstStartPrice > 0, "BurnAuction: zero parameter");
        stack = IAuctionStack(_stack);
        collateralToken = IAuctionERC20(_collateralToken);
        lotSize = _lotSize;
        startPrice = _firstStartPrice;
        lotStart = block.timestamp;
        empty = true;
    }

    /// wstETH on offer in the current lot
    function lot() public view returns (uint) {
        uint balance = collateralToken.balanceOf(address(this));
        return balance < lotSize ? balance : lotSize;
    }

    /// STACK per wstETH right now: linear from the start price to its floor over DECAY, then flat
    function price() public view returns (uint) {
        uint elapsed = block.timestamp - lotStart;
        if (elapsed > DECAY) elapsed = DECAY;
        uint floor = startPrice * FLOOR_BPS / 10000;
        return startPrice - (startPrice - floor) * elapsed / DECAY;
    }

    /// STACK the whole current lot costs right now
    function cost() public view returns (uint) {
        return lot() * price() / 1e18;
    }

    /// Called after wstETH arrives (by the splitter or anyone): a lot that follows an empty spell starts
    /// its clock now, so the first buyer does not get the floor price for free.
    function notify() external {
        if (empty && collateralToken.balanceOf(address(this)) > 0) {
            empty = false;
            lotStart = block.timestamp;
            emit LotOpened(startPrice, lot());
        }
    }

    /// Buy the current lot: pay its STACK cost (burned), receive the wstETH. The next lot starts at twice
    /// the price just paid.
    function buy(uint _maxStack) external {
        require(!empty, "BurnAuction: nothing on offer");
        uint amount = lot();
        require(amount > 0, "BurnAuction: nothing on offer");
        uint p = price();
        uint pay = amount * p / 1e18;
        require(pay <= _maxStack, "BurnAuction: price above max");
        require(pay > 0, "BurnAuction: dust lot");
        require(stack.transferFrom(msg.sender, address(this), pay), "BurnAuction: STACK transferFrom failed");
        stack.burn(pay);
        require(collateralToken.transfer(msg.sender, amount), "BurnAuction: collateral transfer failed");
        totalSold += amount;
        totalBurned += pay;
        startPrice = p * 2;
        lotStart = block.timestamp;
        empty = collateralToken.balanceOf(address(this)) == 0;
        emit Sold(msg.sender, amount, pay, p, startPrice);
        if (!empty) emit LotOpened(startPrice, lot());
    }
}
