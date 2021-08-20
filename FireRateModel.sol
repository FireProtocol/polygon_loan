pragma solidity ^0.5.16;

import "./InterestRateModel.sol";
import "./SafeMath.sol";

/**
 * @title RateModel
 * @author Fire
 */
contract FireRateModel is InterestRateModel {
    using SafeMath for uint;

    uint public constant blocksPerYear = 10512000;
    uint public multiplierPerBlock;
    uint public baseRatePerBlock;

    event NewInterestParams(uint multiplierPerBlock, uint baseRatePerBlock);

    /**
     * @notice FireRateModel constructor
     * @param _multiplierPerYear _multiplierPerYear
     * @param _baseRatePerYear _baseRatePerYear
     */
    constructor (uint _multiplierPerYear, uint _baseRatePerYear) public {
        multiplierPerBlock = _multiplierPerYear.div(blocksPerYear);
        baseRatePerBlock = _baseRatePerYear.div(blocksPerYear);
        emit NewInterestParams(multiplierPerBlock, baseRatePerBlock);
    }

    /**
     * @notice Calculates the current borrow rate per block, with the error code expected by the market
     * @param _cash _cash
     * @param _borrows _borrows
     * @param _reserves _reserves
     * @return uint
     */
    function getBorrowRate(uint _cash, uint _borrows, uint _reserves) public view returns (uint) {
        return utilizationRate(_cash, _borrows, _reserves).mul(multiplierPerBlock).div(1e18).add(baseRatePerBlock);
    }

    /**
     * @notice Calculates the current supply rate per block
     * @param _cash _cash
     * @param _borrows _borrows
     * @param _reserves _reserves
     * @param _reserveFactorMantissa _reserveFactorMantissa
     * @return uint
     */
    function getSupplyRate(uint _cash, uint _borrows, uint _reserves, uint _reserveFactorMantissa) public view returns (uint) {
        uint oneMinusReserveFactor = uint(1e18).sub(_reserveFactorMantissa);
        uint borrowRate = getBorrowRate(_cash, _borrows, _reserves);
        uint rateToPool = borrowRate.mul(oneMinusReserveFactor).div(1e18);
        return utilizationRate(_cash, _borrows, _reserves).mul(rateToPool).div(1e18);
    }

    /**
     * @notice Calculates the utilization rate of the market
     * @dev borrows / (cash + borrows - reserves)
     * @param _cash _cash
     * @param _borrows _borrows
     * @param _reserves _reserves
     * @return uint
     */
    function utilizationRate(uint _cash, uint _borrows, uint _reserves) public pure returns (uint) {
        if (_borrows == 0) {
            return 0;
        }
        return _borrows.mul(1e18).div(_cash.add(_borrows).sub(_reserves));
    }
}