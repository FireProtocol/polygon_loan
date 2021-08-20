pragma solidity ^0.5.16;

import "./FToken.sol";
import "./FHrc20Interface.sol";
import "./FireComptrollerInterface.sol";
import "./InterestRateModel.sol";
import "./EIP20NonStandardInterface.sol";
import "./EIP20Interface.sol";

/**
 * @title HRC-20 Token
 * @author Fire
 */
contract FHrc20 is FToken, FHrc20Interface {

    /**
     * @notice init Fire Comptroller HRC-20 Token
     * @param _underlying token underlying address
     * @param _comptroller comptroller address
     * @param _interestRateModel interestRateModel address
     * @param _initialExchangeRateMantissa exchangeRate
     * @param _name name
     * @param _symbol symbol
     * @param _decimals decimals
     * @param _admin owner address
     * @param _reserveFactorMantissa reserveFactorMantissa
     */
    function initialize(address _underlying, FireComptrollerInterface _comptroller, InterestRateModel _interestRateModel, uint _initialExchangeRateMantissa,
            string memory _name, string memory _symbol, uint8 _decimals, address payable _admin, uint _reserveFactorMantissa) public {
        admin = msg.sender;
        super.initialize(_name, _symbol, _decimals, _comptroller, _interestRateModel, _initialExchangeRateMantissa, _reserveFactorMantissa);
        underlying = _underlying;
        admin = _admin;
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @param _mintAmount The amount of the underlying asset to supply
     * @return uint ERROR
     */
    function mint(uint _mintAmount) external returns (uint) {
        (uint err,) = mintInternal(_mintAmount);
        return err;
    }

    /**
     * @notice Sender redeems cTokens in exchange for the underlying asset
     * @param _redeemTokens The number of cTokens to redeem into underlying
     * @return uint ERROR
     */
    function redeem(uint _redeemTokens) external returns (uint) {
        return redeemInternal(_redeemTokens);
    }

    /**
     * @notice Sender redeems cTokens in exchange for a specified amount of underlying asset
     * @param _redeemAmount The amount of underlying to redeem
     * @return uint ERROR
     */
    function redeemUnderlying(uint _redeemAmount) external returns (uint) {
        return redeemUnderlyingInternal(_redeemAmount);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param _borrowerAmount The amount of the underlying asset to borrow
     * @return uint ERROR
     */
    function borrow(uint _borrowerAmount) external returns (uint) {
        return borrowInternal(_borrowerAmount);
    }

    /**
     * @notice Sender repays their own borrow
     * @param _repayAmount The amount to repay
     * @return uint ERROR
     */
    function repayBorrow(uint _repayAmount) external returns (uint) {
        (uint err,) = repayBorrowInternal(_repayAmount);
        return err;
    }

    /**
     * @notice The sender liquidates the borrowers collateral, The collateral seized is transferred to the liquidator
     * @param _borrower The borrower of this fToken to be liquidated
     * @param _repayAmount The amount of the underlying borrowed asset to repay
     * @param _fTokenInterface which to seize collateral from the borrower
     * @return SUCCESS
     */
    function liquidateBorrow(address _borrower, uint _repayAmount, FTokenInterface _fTokenInterface) external returns (uint) {
        require(_repayAmount != 0 && _repayAmount != uint(-1), "liquidateBorrow _repayAmount liquidate_close_amount failure");
        (uint err,) = liquidateBorrowInternal(_borrower, _repayAmount, _fTokenInterface);
        return err;
    }

    /**
     * @notice The sender adds to reserves
     * @param _addAmount The amount fo underlying token to add as reserves
     * @return uint ERROR
     */
    function _addReserves(uint _addAmount) external returns (uint) {
        return _addResevesInternal(_addAmount);
    }

    /**
     * @notice Gets balance of this contract in terms of the underlying
     * @return uint ERROR
     */
    function getCashPrior() internal view returns (uint) {
        EIP20Interface token = EIP20Interface(underlying);
        return token.balanceOf(address(this));
    }

    function doTransferIn(address _from, uint _amount) internal returns (uint) {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        uint balanceBefore = EIP20Interface(underlying).balanceOf(address(this));
        token.transferFrom(_from, address(this), _amount);
        bool success;
        assembly {
            switch returndatasize()
                case 0 {
                    success := not(0)
                }
                case 32 {
                    returndatacopy(0, 0, 32)
                    success := mload(0)
                }
                default {
                    revert(0, 0)
                }
        }
        require(success, "doTransferIn failure");

        uint balanceAfter = EIP20Interface(underlying).balanceOf(address(this));
        require(balanceAfter >= balanceBefore, "doTransferIn::balanceAfter >= balanceBefore failure");
        return balanceAfter - balanceBefore;
    }

    function doTransferOut(address payable _to, uint _amount) internal {
        EIP20NonStandardInterface token = EIP20NonStandardInterface(underlying);
        token.transfer(_to, _amount);
        bool success;
        assembly {
            switch returndatasize()
                case 0 {
                    success := not(0)
                }
                case 32 {
                    returndatacopy(0, 0, 32)
                    success := mload(0)
                }
                default {
                    revert(0, 0)
                }
        }
        require(success, "dotransferOut failure");
    }
}