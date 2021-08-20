pragma solidity ^0.5.16;

import "./FToken.sol";

/**
 * @title Fire Price Oracle
 * @author Fire
 */
contract PriceOracle {
    address public owner;
    mapping(address => uint) prices;
    event PriceAccept(address _fToken, uint _oldPrice, uint _acceptPrice);

    constructor (address _admin) public {
        owner = _admin;
    }

    function getUnderlyingPrice(address _fToken) external view returns (uint) {
        return prices[_fToken];
    }

    function postUnderlyingPrice(address _fToken, uint _price) external {
        require(msg.sender == owner, "PriceOracle::postUnderlyingPrice owner failure");
        uint old = prices[_fToken];
        prices[_fToken] = _price;
        emit PriceAccept(_fToken, old, _price);
    }
}