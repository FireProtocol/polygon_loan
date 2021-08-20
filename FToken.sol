pragma solidity ^0.5.16;

import "./FireComptrollerInterface.sol";
import "./FTokenInterface.sol";
import "./BaseReporter.sol";
import "./Exponential.sol";
import "./FireTokenCommon.sol";

/**
 * @title HRC-20 Token
 * @author Fire
 */
contract FToken is FTokenInterface, BaseReporter, Exponential {
    modifier nonReentrant() {
        require(reentrant, "re-entered");
        reentrant = false;
        _;
        reentrant = true;
    }
    function getCashPrior() internal view returns (uint);
    function doTransferIn(address _from, uint _amount) internal returns (uint);
    function doTransferOut(address payable _to, uint _amount) internal;

    /**
     * @notice init Fire Comptroller HRC-20 Token
     * @param _name fToken name
     * @param _symbol fToken symbol
     * @param _decimals fToken decimals
     * @param _comptroller fToken fireComptrollerInterface
     * @param _interestRateModel fToken interestRateModel
     * @param _initialExchangeRateMantissa fToken initExchangrRate
     * @param _reserveFactorMantissa _reserveFactorMantissa
     */
    function initialize(string memory _name, string memory _symbol, uint8 _decimals,
            FireComptrollerInterface _comptroller, InterestRateModel _interestRateModel, uint _initialExchangeRateMantissa, uint _reserveFactorMantissa) public {
        require(msg.sender == admin, "Fire FToken::initialize, no operation authority");
        reserveFactorMantissa = _reserveFactorMantissa;
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        reentrant = true;

        require(borrowIndex==0 && accrualBlockNumber==0, "Fire FToken::initialize, only init once");
        initialExchangeRateMantissa = _initialExchangeRateMantissa;
        require(initialExchangeRateMantissa > 0, "Fire FToken::initialize, initial exchange rate must be greater than zero");
        uint _i = _setComptroller(_comptroller);
        require(_i == uint(Error.SUCCESS), "Fire FToken::initialize, _setComptroller failure");
        accrualBlockNumber = block.number;
        borrowIndex = 1e18;
        _i = _setInterestRateModelFresh(_interestRateModel);
        require(_i == uint(Error.SUCCESS), "Fire FToken::initialize, _setInterestRateModelFresh failure");
    }

    // Transfer `number` tokens from `msg.sender` to `dst`
    function transfer(address _dst, uint256 _number) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, msg.sender, _dst, _number) == uint(Error.SUCCESS);
    }
    // Transfer `number` tokens from `src` to `dst`
    function transferFrom(address _src, address _dst, uint256 _number) external nonReentrant returns (bool) {
        return transferTokens(msg.sender, _src, _dst, _number) == uint(Error.SUCCESS);
    }

    /**
     * @notice authorize source account to transfer tokens
     * @param _spender Agent authorized transfer address
     * @param _src src address
     * @param _dst dst address
     * @param _tokens token number
     * @return SUCCESS
     */
    function transferTokens(address _spender, address _src, address _dst, uint _tokens) internal returns (uint) {
        if(_src == _dst){
            return fail(Error.ERROR, ErrorRemarks.ALLOW_SELF_TRANSFERS, 0);
        }
        uint _i = comptroller.transferAllowed(address(this), _src, _tokens);
        if(_i != 0){
            return fail(Error.ERROR, ErrorRemarks.COMPTROLLER_TRANSFER_ALLOWED, _i);
        }

        uint allowance = 0;
        if(_spender == _src) {
            allowance = uint(-1);
        }else {
            allowance = transferAllowances[_src][_spender];
        }

        MathError mathError;
        uint allowanceNew;
        uint srcTokensNew;
        uint dstTokensNew;
        (mathError, allowanceNew) = subUInt(allowance, _tokens);
        if (mathError != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.TRANSFER_NOT_ALLOWED, uint(Error.ERROR));
        }

        (mathError, srcTokensNew) = subUInt(accountTokens[_src], _tokens);
        if (mathError != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.TRANSFER_NOT_ENOUGH, uint(Error.ERROR));
        }

        (mathError, dstTokensNew) = addUInt(accountTokens[_dst], _tokens);
        if (mathError != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.TRANSFER_TOO_MUCH, uint(Error.ERROR));
        }
        
        accountTokens[_src] = srcTokensNew;
        accountTokens[_dst] = dstTokensNew;

        if (allowance != uint(-1)) {
            transferAllowances[_src][_spender] = allowanceNew;
        }
        
        emit Transfer(_src, _dst, _tokens);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Approve `spender` to transfer up to `amount` from `src`
     * @param _spender address spender
     * @param _amount approve amount
     * @return bool
     */
    function approve(address _spender, uint256 _amount) external returns (bool) {
        address src = msg.sender;
        transferAllowances[src][_spender] = _amount;
        emit Approval(src, _spender, _amount);
        return true;
    }

    /**
     * @notice Get the current allowance from `owner` for `spender`
     * @param _owner address owner
     * @param _spender address spender
     * @return SUCCESS
     */
    function allowance(address _owner, address _spender) external view returns (uint256) {
        return transferAllowances[_owner][_spender];
    }

    /**
     * @notice Get the token balance of the `owner`
     * @param _owner address owner
     * @return SUCCESS
     */
    function balanceOf(address _owner) external view returns (uint256) {
        return accountTokens[_owner];
    }

    /**
     * @notice Get the underlying balance of the `owner`
     * @param _owner address owner
     * @return balance
     */
    function balanceOfUnderlying(address _owner) external returns (uint) {
        Exp memory exchangeRate = Exp({mantissa: exchangeRateCurrent()});
        (MathError mErr, uint balance) = mulScalarTruncate(exchangeRate, accountTokens[_owner]);
        require(mErr == MathError.NO_ERROR, "balanceOfUnderlying failure");
        return balance;
    }

    /**
     * @notice Current exchangeRate from the underlying to the FToken
     * @return uint exchangeRate
     */
    function exchangeRateCurrent() public nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.SUCCESS), "exchangeRateCurrent::accrueInterest failure");
        return exchangeRateStored();
    }

    /**
     * @notice Sender supplies assets into the market and receives cTokens in exchange
     * @param _mintAmount mint number
     * @return SUCCESS, number
     */
    function mintInternal(uint _mintAmount) internal nonReentrant returns (uint, uint) {
        uint error = accrueInterest();
        require(error == uint(Error.SUCCESS), "MINT_ACCRUE_INTEREST_FAILED");
        return mintFresh(msg.sender, _mintAmount);
    }

    /**
     * @notice Applies accrued interest to total borrows and reserves
     * @return SUCCESS
     */
    function accrueInterest() public returns (uint) {
        uint currentBlockNumber = block.number;
        uint accrualBlockNumberPrior = accrualBlockNumber;
        if(currentBlockNumber == accrualBlockNumberPrior){
            return uint(Error.SUCCESS);
        }

        // pull memory
        uint cashPrior = getCashPrior();
        uint borrowsPrior = totalBorrows;
        uint reservesPrior = totalReserves;
        uint borrowIndexPrior = borrowIndex;

        uint borrowRateMantissa = interestRateModel.getBorrowRate(cashPrior, borrowsPrior, reservesPrior);
        require(borrowRateMantissa <= borrowRateMaxMantissa, "accrueInterest::interestRateModel.getBorrowRate, borrow rate high");

        (MathError mathErr, uint blockDelta) = subUInt(currentBlockNumber, accrualBlockNumberPrior);
        require(mathErr == MathError.NO_ERROR, "accrueInterest::subUInt, block delta failure");

        Exp memory simpleInterestFactor;
        uint interestAccumulated;
        uint totalBorrowsNew;
        uint totalReservesNew;
        uint borrowIndexNew;

        (mathErr, simpleInterestFactor) = mulScalar(Exp({mantissa: borrowRateMantissa}), blockDelta);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.ACCRUE_INTEREST_SIMPLE_INTEREST_FACTOR_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, interestAccumulated) = mulScalarTruncate(simpleInterestFactor, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.ACCRUE_INTEREST_ACCUMULATED_INTEREST_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, totalBorrowsNew) = addUInt(interestAccumulated, borrowsPrior);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.ACCRUE_INTEREST_NEW_TOTAL_BORROWS_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, totalReservesNew) = mulScalarTruncateAddUInt(Exp({mantissa: reserveFactorMantissa}), interestAccumulated, reservesPrior);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.ACCRUE_INTEREST_NEW_TOTAL_RESERVES_CALCULATION_FAILED, uint(mathErr));
        }

        (mathErr, borrowIndexNew) = mulScalarTruncateAddUInt(simpleInterestFactor, borrowIndexPrior, borrowIndexPrior);
        if (mathErr != MathError.NO_ERROR) {
            return fail(Error.ERROR, ErrorRemarks.ACCRUE_INTEREST_NEW_BORROW_INDEX_CALCULATION_FAILED, uint(mathErr));
        }

        // push storage
        accrualBlockNumber = currentBlockNumber;
        borrowIndex = borrowIndexNew;
        totalBorrows = totalBorrowsNew;
        totalReserves = totalReservesNew;

        emit AccrueInterest(cashPrior, interestAccumulated, borrowIndexNew, totalBorrowsNew);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice User supplies assets into the market and receives cTokens in exchange
     * @dev mintTokens = actualMintAmount / exchangeRate
     * @dev totalSupplyNew = totalSupply + mintTokens
     * @dev accountTokensNew = accountTokens[_minter] + mintTokens
     * @param _minter address minter
     * @param _mintAmount mint amount
     * @return SUCCESS, number
     */
    function mintFresh(address _minter, uint _mintAmount)internal returns (uint, uint) {
        require(block.number == accrualBlockNumber, "MINT_FRESHNESS_CHECK");
        
        uint allowed = comptroller.mintAllowed();
        require(allowed == 0, "MINT_COMPTROLLER_REJECTION");

        MintLocalVars memory vars;
        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR, "MINT_EXCHANGE_RATE_READ_FAILED");

        vars.actualMintAmount = doTransferIn(_minter, _mintAmount);

        (vars.mathErr, vars.mintTokens) = divScalarByExpTruncate(vars.actualMintAmount, Exp({mantissa: vars.exchangeRateMantissa}));
        require(vars.mathErr == MathError.NO_ERROR, "mintFresh::divScalarByExpTruncate failure");

        (vars.mathErr, vars.totalSupplyNew) = addUInt(totalSupply, vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "mintFresh::addUInt totalSupply failure");

        (vars.mathErr, vars.accountTokensNew) = addUInt(accountTokens[_minter], vars.mintTokens);
        require(vars.mathErr == MathError.NO_ERROR, "mintFresh::addUInt accountTokens failure");

        totalSupply = vars.totalSupplyNew;
        accountTokens[_minter] = vars.accountTokensNew;

        emit Mint(_minter, vars.actualMintAmount, vars.mintTokens);
        emit Transfer(address(this), _minter, vars.mintTokens);
        return (uint(Error.SUCCESS), vars.actualMintAmount);
    }

    /**
     * @notice Current exchangeRate from the underlying to the FToken
     * @return uint exchangeRate
     */
    function exchangeRateStored() public view returns (uint) {
        (MathError err, uint rate) = exchangeRateStoredInternal();
        require(err == MathError.NO_ERROR, "exchangeRateStored::exchangeRateStoredInternal failure");
        return rate;
    }

    /**
     * @notice Current exchangeRate from the underlying to the FToken
     * @dev exchangeRate = (totalCash + totalBorrows - totalReserves) / totalSupply
     * @return SUCCESS, exchangeRate
     */
    function exchangeRateStoredInternal() internal view returns (MathError, uint) {
        if(totalSupply == 0){
            return (MathError.NO_ERROR, initialExchangeRateMantissa);
        }

        uint _totalSupply = totalSupply;
        uint totalCash = getCashPrior();
        uint cashPlusBorrowsMinusReserves;
        
        MathError err;
        (err, cashPlusBorrowsMinusReserves) = addThenSubUInt(totalCash, totalBorrows, totalReserves);
        if(err != MathError.NO_ERROR) {
            return (err, 0);
        }
        
        Exp memory exchangeRate;
        (err, exchangeRate) = getExp(cashPlusBorrowsMinusReserves, _totalSupply);
        if(err != MathError.NO_ERROR) {
            return (err, 0);
        }
        return (MathError.NO_ERROR, exchangeRate.mantissa);
    }

    function getCash() external view returns (uint) {
        return getCashPrior();
    }

    /**
     * @notice Get a snapshot of the account's balances and the cached exchange rate
     * @param _address address
     * @return SUCCESS, balance, balance, exchangeRate
     */
    function getAccountSnapshot(address _address) external view returns (uint, uint, uint, uint) {
        MathError err;
        uint borrowBalance;
        uint exchangeRateMantissa;

        (err, borrowBalance) = borrowBalanceStoredInternal(_address);
        if(err != MathError.NO_ERROR){
            return (uint(Error.ERROR), 0, 0, 0);
        }
        (err, exchangeRateMantissa) = exchangeRateStoredInternal();
        if(err != MathError.NO_ERROR){
            return (uint(Error.ERROR), 0, 0, 0);
        }
        return (uint(Error.SUCCESS), accountTokens[_address], borrowBalance, exchangeRateMantissa);
    }

    /**
     * @notice current per-block borrow interest rate for this fToken
     * @return current borrowRate
     */
    function borrowRatePerBlock() external view returns (uint) {
        return interestRateModel.getBorrowRate(getCashPrior(), totalBorrows, totalReserves);
    }

    /**
     * @notice current per-block supply interest rate for this fToken
     * @return current supplyRate
     */
    function supplyRatePerBlock() external view returns (uint) {
        return interestRateModel.getSupplyRate(getCashPrior(), totalBorrows, totalReserves, reserveFactorMantissa);
    }

    /**
     * @notice current total borrows plus accrued interest
     * @return totalBorrows
     */
    function totalBorrowsCurrent() external nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.SUCCESS), "totalBorrowsCurrent::accrueInterest failure");
        return totalBorrows;
    }

    /**
     * @notice current borrow limit by account
     * @param _account address
     * @return borrowBalance
     */
    function borrowBalanceCurrent(address _account) external nonReentrant returns (uint) {
        require(accrueInterest() == uint(Error.SUCCESS), "borrowBalanceCurrent::accrueInterest failure");
        return borrowBalanceStored(_account);
    }

    /**
     * @notice Return the borrow balance of account based on stored data
     * @param _account address
     * @return borrowBalance
     */
    function borrowBalanceStored(address _account) public view returns (uint) {
        (MathError err, uint result) = borrowBalanceStoredInternal(_account);
        require(err == MathError.NO_ERROR, "borrowBalanceStored::borrowBalanceStoredInternal failure");
        return result;
    }

    /**
     * @notice Return borrow balance of account based on stored data
     * @param _account address
     * @return SUCCESS, number
     */
    function borrowBalanceStoredInternal(address _account) internal view returns (MathError, uint) {
        BorrowBalanceInfomation storage borrowBalanceInfomation = accountBorrows[_account];
        if(borrowBalanceInfomation.principal == 0) {
            return (MathError.NO_ERROR, 0);
        }
        
        MathError err;
        uint principalTimesIndex;
        (err, principalTimesIndex) = mulUInt(borrowBalanceInfomation.principal, borrowIndex);
        if(err != MathError.NO_ERROR){
            return (err, 0);
        }
        
        uint balance;
        (err, balance) = divUInt(principalTimesIndex, borrowBalanceInfomation.interestIndex);
        if(err != MathError.NO_ERROR){
            return (err, 0);
        }
        return (MathError.NO_ERROR, balance);
    }

    /**
     * @notice Sender redeems fTokens in exchange for the underlying asset
     * @param _redeemTokens fToken number
     * @return SUCCESS
     */
    function redeemInternal(uint _redeemTokens) internal nonReentrant returns (uint) {
        require(_redeemTokens > 0, "CANNOT_BE_ZERO");
        
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "REDEEM_ACCRUE_INTEREST_FAILED");
        return redeemFresh(msg.sender, _redeemTokens, 0);
    }

    /**
     * @notice Sender redeems fTokens in exchange for a specified amount of underlying asset
     * @param _redeemAmount The amount of underlying to receive from redeeming fTokens
     * @return SUCCESS
     */
    function redeemUnderlyingInternal(uint _redeemAmount) internal nonReentrant returns (uint) {
        require(_redeemAmount > 0, "CANNOT_BE_ZERO");

        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "REDEEM_ACCRUE_INTEREST_FAILED");
        return redeemFresh(msg.sender, 0, _redeemAmount);
    }

    /**
     * @notice User redeems cTokens in exchange for the underlying asset
     * @dev redeemAmount = redeemTokensIn x exchangeRateCurrent
     * @dev redeemTokens = redeemAmountIn / exchangeRate
     * @dev totalSupplyNew = totalSupply - redeemTokens
     * @dev accountTokensNew = accountTokens[redeemer] - redeemTokens
     * @param _redeemer fToken address
     * @param _redeemTokensIn redeemTokensIn The number of fTokens to redeem into underlying
     * @param _redeemAmountIn redeemAmountIn The number of underlying tokens to receive from redeeming fTokens
     * @return SUCCESS
     */
    function redeemFresh(address payable _redeemer, uint _redeemTokensIn, uint _redeemAmountIn) internal returns (uint) {
        require(accrualBlockNumber == block.number, "REDEEM_FRESHNESS_CHECK");

        RedeemLocalVars memory vars;
        (vars.mathErr, vars.exchangeRateMantissa) = exchangeRateStoredInternal();
        require(vars.mathErr == MathError.NO_ERROR, "REDEEM_EXCHANGE_RATE_READ_FAILED");
        if(_redeemTokensIn > 0) {
            vars.redeemTokens = _redeemTokensIn;
            (vars.mathErr, vars.redeemAmount) = mulScalarTruncate(Exp({mantissa: vars.exchangeRateMantissa}), _redeemTokensIn);
            require(vars.mathErr == MathError.NO_ERROR, "REDEEM_EXCHANGE_TOKENS_CALCULATION_FAILED");
        } else {
            (vars.mathErr, vars.redeemTokens) = divScalarByExpTruncate(_redeemAmountIn, Exp({mantissa: vars.exchangeRateMantissa}));
            require(vars.mathErr == MathError.NO_ERROR, "REDEEM_EXCHANGE_AMOUNT_CALCULATION_FAILED");
            vars.redeemAmount = _redeemAmountIn;
        }
        uint allowed = comptroller.redeemAllowed(address(this), _redeemer, vars.redeemTokens);
        require(allowed == 0, "REDEEM_COMPTROLLER_REJECTION");
        (vars.mathErr, vars.totalSupplyNew) = subUInt(totalSupply, vars.redeemTokens);
        require(vars.mathErr == MathError.NO_ERROR, "REDEEM_NEW_TOTAL_SUPPLY_CALCULATION_FAILED");

        (vars.mathErr, vars.accountTokensNew) = subUInt(accountTokens[_redeemer], vars.redeemTokens);
        require(vars.mathErr == MathError.NO_ERROR, "REDEEM_NEW_ACCOUNT_BALANCE_CALCULATION_FAILED");

        require(getCashPrior() >= vars.redeemAmount, "REDEEM_TRANSFER_OUT_NOT_POSSIBLE");
        doTransferOut(_redeemer, vars.redeemAmount);

        // push storage
        totalSupply = vars.totalSupplyNew;
        accountTokens[_redeemer] = vars.accountTokensNew;

        emit Transfer(_redeemer, address(this), vars.redeemTokens);
        emit Redeem(_redeemer, vars.redeemAmount, vars.redeemTokens);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param _borrowAmount: The amount of the underlying asset to borrow
     * @return SUCCESS
     */
    function borrowInternal(uint _borrowAmount) internal nonReentrant returns (uint) {
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "BORROW_ACCRUE_INTEREST_FAILED");
        return borrowFresh(msg.sender, _borrowAmount);
    }

    /**
     * @notice Sender borrows assets from the protocol to their own address
     * @param _borrower address
     * @param _borrowAmount number
     * @return SUCCESS
     */
    function borrowFresh(address payable _borrower, uint _borrowAmount) internal returns (uint) {
        uint allowed = comptroller.borrowAllowed(address(this), _borrower, _borrowAmount);
        require(allowed == 0, "BORROW_COMPTROLLER_REJECTION");
        require(block.number == accrualBlockNumber, "BORROW_FRESHNESS_CHECK");
        require(_borrowAmount <= getCashPrior(), "BORROW_CASH_NOT_AVAILABLE");

        BorrowLocalVars memory vars;
        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(_borrower);
        require(vars.mathErr == MathError.NO_ERROR, "BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED");

        (vars.mathErr, vars.accountBorrowsNew) = addUInt(vars.accountBorrows, _borrowAmount);
        require(vars.mathErr == MathError.NO_ERROR, "BORROW_NEW_ACCOUNT_BORROW_BALANCE_CALCULATION_FAILED");

        (vars.mathErr, vars.totalBorrowsNew) = addUInt(totalBorrows, _borrowAmount);
        require(vars.mathErr == MathError.NO_ERROR, "BORROW_NEW_TOTAL_BALANCE_CALCULATION_FAILED");

        doTransferOut(_borrower, _borrowAmount);

        // push storage
        accountBorrows[_borrower].principal = vars.accountBorrowsNew;
        accountBorrows[_borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit Borrow(_borrower, _borrowAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Sender repays their own borrow
     * @param _repayAmount The amount to repay
     * @return SUCCESS, number
     */
    function repayBorrowInternal(uint _repayAmount) internal nonReentrant returns (uint, uint) {
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "REPAY_BORROW_ACCRUE_INTEREST_FAILED");
        return repayBorrowFresh(msg.sender, msg.sender, _repayAmount);
    }

    /**
     * @notice Repay Borrow
     * @param _payer the account paying off the borrow
     * @param _borrower The account with the debt being payed off
     * @param _repayAmount The amount of undelrying tokens being returned
     * @return SUCCESS, number
     */
    function repayBorrowFresh(address _payer, address _borrower, uint _repayAmount) internal returns (uint, uint) {
        require(block.number == accrualBlockNumber, "REPAY_BORROW_FRESHNESS_CHECK");

        uint allowed = comptroller.repayBorrowAllowed();
        require(allowed == 0, "REPAY_BORROW_COMPTROLLER_REJECTION");
        RepayBorrowLocalVars memory vars;
        vars.borrowerIndex = accountBorrows[_borrower].interestIndex;
        (vars.mathErr, vars.accountBorrows) = borrowBalanceStoredInternal(_borrower);
        require(vars.mathErr == MathError.NO_ERROR, "REPAY_BORROW_ACCUMULATED_BALANCE_CALCULATION_FAILED");
        
        if (_repayAmount == uint(-1)) {
            vars.repayAmount = vars.accountBorrows;
        } else {
            vars.repayAmount = _repayAmount;
        }
        vars.actualRepayAmount = doTransferIn(_payer, vars.repayAmount);
        (vars.mathErr, vars.accountBorrowsNew) = subUInt(vars.accountBorrows, vars.actualRepayAmount);
        require(vars.mathErr == MathError.NO_ERROR, "repayBorrowFresh::subUInt vars.accountBorrows failure");

        (vars.mathErr, vars.totalBorrowsNew) = subUInt(totalBorrows, vars.actualRepayAmount);
        require(vars.mathErr == MathError.NO_ERROR, "repayBorrowFresh::subUInt totalBorrows failure");

        // push storage
        accountBorrows[_borrower].principal = vars.accountBorrowsNew;
        accountBorrows[_borrower].interestIndex = borrowIndex;
        totalBorrows = vars.totalBorrowsNew;

        emit RepayBorrow(_payer, _borrower, vars.actualRepayAmount, vars.accountBorrowsNew, vars.totalBorrowsNew);
        return (uint(Error.SUCCESS), vars.actualRepayAmount);
    }

    /**
     * @notice The sender liquidates the borrowers collateral, The collateral seized is transferred to the liquidator
     * @param _borrower The borrower of this cToken to be liquidated
     * @param _repayAmount The amount of the underlying borrowed asset to repay
     * @param _fTokenInterface which to seize collateral from the borrower
     * @return SUCCESS
     */
    function liquidateBorrowInternal(address _borrower, uint _repayAmount, FTokenInterface _fTokenInterface) internal nonReentrant returns (uint, uint) {
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "LIQUIDATE_BORROW_ACCRUE_INTEREST_FAILED");
        if(address(this) != address(_fTokenInterface)) {
            err = _fTokenInterface.accrueInterest();
            require(err == uint(Error.SUCCESS), "LIQUIDATE_BORROW_ACCRUE_INTEREST_FAILED");
        }
        return liquidateBorrowFresh(msg.sender, _borrower, _repayAmount, _fTokenInterface);
    }

    /**
     * @notice The sender liquidates the borrowers collateral, The collateral seized is transferred to the liquidator
     * @param _liquidates The address repaying the borrow and seizing collateral
     * @param _borrower The borrower of this cToken to be liquidated
     * @param _repayAmount The amount of the underlying borrowed asset to repay
     * @param _fTokenInterface which to seize collateral from the borrower
     * @return SUCCESS
     */
    function liquidateBorrowFresh(address _liquidates, address _borrower, uint _repayAmount, FTokenInterface _fTokenInterface) internal returns (uint, uint) {
        require(_liquidates != _borrower, "FToken::liquidateBorrowFresh liquidate_liquidator_is_borrower");
        
        uint allowed = comptroller.liquidateBorrowAllowed(address(this), address(_fTokenInterface), _liquidates, _borrower, _repayAmount);
        require(allowed == 0, "FToken::liquidateBorrowFresh comptroller.liquidateBorrowAllowed failure");
        require(accrualBlockNumber == block.number && _fTokenInterface.accrualBlockNumber() == block.number, "FToken::liquidateBorrowFresh market is not refreshed");
        
        (uint repayBorrowError, uint actualRepayAmount) = repayBorrowFresh(_liquidates, _borrower, _repayAmount);
        require(repayBorrowError == uint(Error.SUCCESS), "FToken::liquidateBorrowFresh liquidate_repay_borrow_fresh_failed");

        (uint amountSeizeError, uint seizeTokens) = comptroller.liquidateCalculateSeizeTokens(address(this), address(_fTokenInterface), actualRepayAmount);
        require(amountSeizeError == uint(Error.SUCCESS), "liquidate_comptroller_calculate_amount_seize_failed");
        require(_fTokenInterface.balanceOf(_borrower) >= seizeTokens, "liquidate_seize_too_much");

        uint seizeError;
        if (address(_fTokenInterface) == address(this)) {
            seizeError = seizeInternal(address(this), _liquidates, _borrower, seizeTokens);
        } else {
            seizeError = _fTokenInterface.seize(_liquidates, _borrower, seizeTokens);
        }
        require(seizeError == uint(Error.SUCCESS), "token seizure failed");

        emit LiquidateBorrow(_liquidates, _borrower, actualRepayAmount, address(_fTokenInterface), seizeTokens);
        return (uint(Error.SUCCESS), actualRepayAmount);
    }

    /**
     * @notice Transfers collateral tokens to the liquidator
     * @param _liquidator address
     * @param _borrower address
     * @param _seizeTokens seize number
     * @return SUCCESS
     */
    function seize(address _liquidator, address _borrower, uint _seizeTokens) external nonReentrant returns (uint) {
        require(_liquidator != _borrower, "LIQUIDATE_SEIZE_LIQUIDATOR_IS_BORROWER");
        return seizeInternal(msg.sender, _liquidator, _borrower, _seizeTokens);
    }

    /**
     * @notice Transfers collateral tokens to the liquidator. Called only during an in-kind liquidation, or by liquidateBorrow during the liquidation of another FToken
     * @dev borrowerTokensNew = accountTokens[borrower] - seizeTokens
     * @dev liquidatorTokensNew = accountTokens[liquidator] + seizeTokens
     * @param _token address
     * @param _liquidator address
     * @param _borrower address
     * @param _seizeTokens seize number
     * @return SUCCESS
     */
    function seizeInternal(address _token, address _liquidator, address _borrower, uint _seizeTokens) internal returns (uint) {
        uint allowed = comptroller.seizeAllowed(address(this), _token);
        require(allowed == 0, "LIQUIDATE_SEIZE_COMPTROLLER_REJECTION");
        
        MathError mathErr;
        uint borrowerTokensNew;
        uint liquidatorTokensNew;
        (mathErr, borrowerTokensNew) = subUInt(accountTokens[_borrower], _seizeTokens);
        require(mathErr == MathError.NO_ERROR, "LIQUIDATE_SEIZE_BALANCE_DECREMENT_FAILED");
        
        (mathErr, liquidatorTokensNew) = addUInt(accountTokens[_liquidator], _seizeTokens);
        require(mathErr == MathError.NO_ERROR, "LIQUIDATE_SEIZE_BALANCE_INCREMENT_FAILED");

        // push storage
        accountTokens[_borrower] = borrowerTokensNew;
        accountTokens[_liquidator] = liquidatorTokensNew;

        emit Transfer(_borrower, _liquidator, _seizeTokens);
        return uint(Error.SUCCESS);
    }

    struct MintLocalVars {
        Error err;
        MathError mathErr;
        uint exchangeRateMantissa;
        uint mintTokens;
        uint totalSupplyNew;
        uint accountTokensNew;
        uint actualMintAmount;
    }

    struct RedeemLocalVars {
        Error err;
        MathError mathErr;
        uint exchangeRateMantissa;
        uint redeemTokens;
        uint redeemAmount;
        uint totalSupplyNew;
        uint accountTokensNew;
    }

    struct BorrowLocalVars {
        MathError mathErr;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
    }

    struct RepayBorrowLocalVars {
        Error err;
        MathError mathErr;
        uint repayAmount;
        uint borrowerIndex;
        uint accountBorrows;
        uint accountBorrowsNew;
        uint totalBorrowsNew;
        uint actualRepayAmount;
    }

    function _setPendingAdmin(address payable _newAdmin) external returns (uint) {
        require(admin == msg.sender, "SET_PENDING_ADMIN_OWNER_CHECK");
        address _old = pendingAdmin;
        pendingAdmin = _newAdmin;
        emit NewPendingAdmin(_old, _newAdmin);
        return uint(Error.SUCCESS);
    }

    function _acceptAdmin() external returns (uint) {
        if (msg.sender != pendingAdmin || msg.sender == address(0)) {
            return fail(Error.ERROR, ErrorRemarks.ACCEPT_ADMIN_PENDING_ADMIN_CHECK, uint(Error.ERROR));
        }
        address oldAdmin = admin;
        address oldPendingAdmin = pendingAdmin;
        admin = pendingAdmin;
        pendingAdmin = address(0);

        emit NewAdmin(oldAdmin, admin);
        emit NewPendingAdmin(oldPendingAdmin, pendingAdmin);
        return uint(Error.SUCCESS);
    }

    function _setComptroller(FireComptrollerInterface _comptrollerInterface) public returns (uint) {
        require(admin == msg.sender, "SET_COMPTROLLER_OWNER_CHECK");
        FireComptrollerInterface old = comptroller;
        require(_comptrollerInterface.fireComptroller(), "FToken::_setComptroller _comptrollerInterface false");
        comptroller = _comptrollerInterface;

        emit NewComptroller(old, _comptrollerInterface);
        return uint(Error.SUCCESS);
    }

    function _setReserveFactor(uint _newReserveFactor) external nonReentrant returns (uint) {
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "SET_RESERVE_FACTOR_ACCRUE_INTEREST_FAILED");
        return _setReserveFactorFresh(_newReserveFactor);
    }

    function _setReserveFactorFresh(uint _newReserveFactor) internal returns (uint) {
        require(block.number == accrualBlockNumber, "SET_RESERVE_FACTOR_FRESH_CHECK");
        require(msg.sender == admin, "SET_RESERVE_FACTOR_ADMIN_CHECK");
        require(_newReserveFactor <= reserveFactorMaxMantissa, "SET_RESERVE_FACTOR_BOUNDS_CHECK");
        
        uint old = reserveFactorMantissa;
        reserveFactorMantissa = _newReserveFactor;

        emit NewReserveFactor(old, _newReserveFactor);
        return uint(Error.SUCCESS);
    }

    function _addResevesInternal(uint _addAmount) internal nonReentrant returns (uint) {
        uint error = accrueInterest();
        require(error == uint(Error.SUCCESS), "ADD_RESERVES_ACCRUE_INTEREST_FAILED");
        
        (error, ) = _addReservesFresh(_addAmount);
        return error;
    }

    function _addReservesFresh(uint _addAmount) internal returns (uint, uint) {
        require(block.number == accrualBlockNumber, "ADD_RESERVES_FRESH_CHECK");
        
        uint actualAddAmount = doTransferIn(msg.sender, _addAmount);
        uint totalReservesNew = totalReserves + actualAddAmount;

        require(totalReservesNew >= totalReserves, "_addReservesFresh::totalReservesNew >= totalReserves failure");

        // push storage
        totalReserves = totalReservesNew;

        emit ReservesAdded(msg.sender, actualAddAmount, totalReservesNew);
        return (uint(Error.SUCCESS), actualAddAmount);
    }

    function _reduceReserves(uint _reduceAmount, address payable _account) external nonReentrant returns (uint) {
        uint error = accrueInterest();
        require(error == uint(Error.SUCCESS), "REDUCE_RESERVES_ACCRUE_INTEREST_FAILED");
        return _reduceReservesFresh(_reduceAmount, _account);
    }

    function _reduceReservesFresh(uint _reduceAmount, address payable _account) internal returns (uint) {
        require(admin == msg.sender, "REDUCE_RESERVES_ADMIN_CHECK");
        require(block.number == accrualBlockNumber, "REDUCE_RESERVES_FRESH_CHECK");
        require(_reduceAmount <= getCashPrior(), "REDUCE_RESERVES_CASH_NOT_AVAILABLE");
        require(_reduceAmount <= totalReserves, "REDUCE_RESERVES_VALIDATION");

        uint totalReservesNew = totalReserves - _reduceAmount;
        require(totalReservesNew <= totalReserves, "_reduceReservesFresh::totalReservesNew <= totalReserves failure");

        // push storage
        totalReserves = totalReservesNew;
        doTransferOut(_account, _reduceAmount);
        emit ReservesReduced(_account, _reduceAmount, totalReservesNew);
        return uint(Error.SUCCESS);
    }

    function _setInterestRateModel(InterestRateModel _interestRateModel) public returns (uint) {
        uint err = accrueInterest();
        require(err == uint(Error.SUCCESS), "SET_INTEREST_RATE_MODEL_ACCRUE_INTEREST_FAILED");
        return _setInterestRateModelFresh(_interestRateModel);
    }

    function _setInterestRateModelFresh(InterestRateModel _interestRateModel) internal returns (uint) {
        require(msg.sender == admin, "SET_INTEREST_RATE_MODEL_OWNER_CHECK");
        require(block.number == accrualBlockNumber, "SET_INTEREST_RATE_MODEL_FRESH_CHECK");

        InterestRateModel old = interestRateModel;
        require(_interestRateModel.isInterestRateModel(), "_setInterestRateModelFresh::_interestRateModel.isInterestRateModel failure");
        interestRateModel = _interestRateModel;
        emit NewMarketInterestRateModel(old, _interestRateModel);
        return uint(Error.SUCCESS);
    }
}