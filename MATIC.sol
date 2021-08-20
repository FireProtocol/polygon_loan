pragma solidity ^0.5.16;

import "./FToken.sol";

/**
 * @notice MATIC contract
 * @author Fire
 */
contract MATIC is FToken {

    /**
     * @notice init MATIC contract
     * @param _comptroller comptroller
     * @param _interestRateModel interestRate
     * @param _initialExchangeRateMantissa exchangeRate
     * @param _name name
     * @param _symbol symbol
     * @param _decimals decimals
     * @param _admin owner address
     * @param _reserveFactorMantissa reserveFactorMantissa
     */
    constructor (FireComptrollerInterface _comptroller, InterestRateModel _interestRateModel, uint _initialExchangeRateMantissa, string memory _name,
            string memory _symbol, uint8 _decimals, address payable _admin, uint _reserveFactorMantissa) public {
        admin = msg.sender;
        initialize(_name, _symbol, _decimals, _comptroller, _interestRateModel, _initialExchangeRateMantissa, _reserveFactorMantissa);
        admin = _admin;
    }

    function () external payable {
        (uint err,) = mintInternal(msg.value);
        require(err == uint(Error.SUCCESS), "Matic::mint failure");
    }

    function mint() external payable {
        (uint err,) = mintInternal(msg.value);
        require(err == uint(Error.SUCCESS), "Matic::mint failure");
    }
    
    function redeem(uint _redeemTokens) external returns (uint) {
        return redeemInternal(_redeemTokens);
    }
    
    function redeemUnderlying(uint _redeemAmount) external returns (uint) {
        return redeemUnderlyingInternal(_redeemAmount);
    }
    
    function borrow(uint _borrowAmount) external returns (uint) {
        return borrowInternal(_borrowAmount);
    }

    function repayBorrow() external payable {
        (uint err,) = repayBorrowInternal(msg.value);
        require(err == uint(Error.SUCCESS), "Matic::repayBorrow failure");
    }

    function liquidateBorrow(address _borrower, FToken _fTokenCollateral) external payable {
        (uint err,) = liquidateBorrowInternal(_borrower, msg.value, _fTokenCollateral);
        require(err == uint(Error.SUCCESS), "Matic::liquidateBorrow failure");
    }

    function getCashPrior() internal view returns (uint) {
        (MathError err, uint startingBalance) = subUInt(address(this).balance, msg.value);
        require(err == MathError.NO_ERROR);
        return startingBalance;
    }

    function doTransferIn(address _from, uint _amount) internal returns (uint) {
        require(msg.sender == _from, "Matic::doTransferIn sender failure");
        require(msg.value == _amount, "Matic::doTransferIn value failure");
        return _amount;
    }

    function doTransferOut(address payable _to, uint _amount) internal {
        _to.transfer(_amount);
    }
}