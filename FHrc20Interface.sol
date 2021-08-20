pragma solidity ^0.5.16;

import "./FTokenInterface.sol";

contract FHrc20Common {
    address public underlying;
}

/**
 * @title FHrc20Interface
 * @author Fire
 */
contract FHrc20Interface is FHrc20Common {
    function mint(uint _mintAmount) external returns (uint);
    function redeem(uint _redeemTokens) external returns (uint);
    function redeemUnderlying(uint _redeemAmount) external returns (uint);
    function borrow(uint _borrowAmount) external returns (uint);
    function repayBorrow(uint _repayAmount) external returns (uint);

    function _addReserves(uint addAmount) external returns (uint);
}