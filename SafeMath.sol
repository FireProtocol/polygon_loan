pragma solidity ^0.5.16;

/**
 * @title Fire safe math, derived from OpenZeppelin's SafeMath library
 * @author Fire
 */
library SafeMath {

    function add(uint256 _a, uint256 _b) internal pure returns (uint256) {
        uint256 c = _a + _b;
        require(c >= _a, "SafeMath: addition overflow");
        return c;
    }

    function sub(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return sub(_a, _b, "SafeMath: subtraction overflow");
    }

    function sub(uint256 _a, uint256 _b, string memory _errorMessage) internal pure returns (uint256) {
        require(_b <= _a, _errorMessage);
        uint256 c = _a - _b;
        return c;
    }

    function mul(uint256 _a, uint256 _b) internal pure returns (uint256) {
        if (_a == 0) {
            return 0;
        }
        uint256 c = _a * _b;
        require(c / _a == _b, "SafeMath: multiplication overflow");
        return c;
    }

    function div(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return div(_a, _b, "SafeMath: division by zero");
    }

    function div(uint256 _a, uint256 _b, string memory _errorMessage) internal pure returns (uint256) {
        require(_b > 0, _errorMessage);
        uint256 c = _a / _b;
        return c;
    }

    function mod(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return mod(_a, _b, "SafeMath: modulo by zero");
    }

    function mod(uint256 _a, uint256 _b, string memory _errorMessage) internal pure returns (uint256) {
        require(_b != 0, _errorMessage);
        return _a % _b;
    }
}