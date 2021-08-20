pragma solidity ^0.5.16;

import "./FireComptrollerCommon.sol";
import "./FireComptrollerInterface.sol";
import "./Exponential.sol";
import "./Unitroller.sol";
import "./BaseReporter.sol";
import "./EIP20Interface.sol";
import "./FHrc20.sol";

/**
 * @notice Fire Comptroller contract
 * @author Fire
 */
contract FireComptroller is FireComptrollerCommon, FireComptrollerInterface, Exponential, BaseReporter {
    uint internal constant closeFactorMinMantissa = 0.05e18;
    uint internal constant closeFactorMaxMantissa = 0.9e18;
    uint internal constant collateralFactorMaxMantissa = 0.9e18;
    uint internal constant liquidationIncentiveMinMantissa = 1.0e18;
    uint internal constant liquidationIncentiveMaxMantissa = 1.5e18;

    constructor () public {
        admin = msg.sender;
    }

    /**
     * @notice Returns the assets an account has entered
     * @param _account address account
     * @return FToken[]
     */
    function getAssetsIn(address _account) external view returns (FToken[] memory) {
        return accountAssets[_account];
    }

    /**
     * @notice Whether the current account has corresponding assets
     * @param _account address account
     * @param _fToken FToken
     * @return bool
     */
    function checkMembership(address _account, FToken _fToken) external view returns (bool) {
        return markets[address(_fToken)].accountMembership[_account];
    }

    /**
     * @notice Enter Markets
     * @param _fTokens FToken[]
     * @return uint[]
     */
    function enterMarkets(address[] memory _fTokens) public returns (uint[] memory) {
        uint len = _fTokens.length;
        uint[] memory results = new uint[](len);
        for (uint i = 0; i < len; i++) {
            FToken fToken = FToken(_fTokens[i]);
            results[i] = uint(addToMarketInternal(fToken, msg.sender));
        }
        return results;
    }

    /**
     * @notice Add the market to the borrower's "assets in" for liquidity calculations
     * @param _fToken FToken address
     * @param _sender address sender
     * @return Error SUCCESS
     */
    function addToMarketInternal(FToken _fToken, address _sender) internal returns (Error) {
        Market storage marketToJoin = markets[address(_fToken)];
        require(marketToJoin.isListed, "addToMarketInternal marketToJoin.isListed false");
        if (marketToJoin.accountMembership[_sender] == true) {
            return Error.SUCCESS;
        }

        require(accountAssets[_sender].length < maxAssets, "addToMarketInternal: accountAssets[_sender].length >= maxAssets");
        marketToJoin.accountMembership[_sender] = true;
        accountAssets[_sender].push(_fToken);

        emit MarketEntered(_fToken, _sender);
        return Error.SUCCESS;
    }

    /**
     * @notice Removes asset from sender's account liquidity calculation
     * @param _fTokenAddress fToken address
     * @return SUCCESS
     */
    function exitMarket(address _fTokenAddress) external returns (uint) {
        FToken fToken = FToken(_fTokenAddress);
        (uint err, uint tokensHeld, uint borrowBalance,) = fToken.getAccountSnapshot(msg.sender);
        require(err == uint(Error.SUCCESS), "FireComptroller::exitMarket fToken.getAccountSnapshot failure");
        require(borrowBalance == 0, "FireComptroller::exitMarket borrowBalance Non-zero");

        uint allowed = redeemAllowedInternal(_fTokenAddress, msg.sender, tokensHeld);
        require(allowed == 0, "FireComptroller::exitMarket redeemAllowedInternal failure");

        Market storage marketToExit = markets[address(fToken)];
        if (!marketToExit.accountMembership[msg.sender]) {
            return uint(Error.SUCCESS);
        }
        delete marketToExit.accountMembership[msg.sender];

        FToken[] memory userAssetList = accountAssets[msg.sender];
        uint len = userAssetList.length;
        uint assetIndex = len;
        for (uint i = 0; i < len; i++) {
            if (userAssetList[i] == fToken) {
                assetIndex = i;
                break;
            }
        }
        assert(assetIndex < len);
        FToken[] storage storedList = accountAssets[msg.sender];
        storedList[assetIndex] = storedList[storedList.length - 1];
        storedList.length--;

        emit MarketExited(fToken, msg.sender);
        return uint(Error.SUCCESS);
    }

    /**
     * @dev financial risk management
     */

    function mintAllowed() external returns (uint) {
        require(!_mintGuardianPaused, "FireComptroller::mintAllowed _mintGuardianPaused failure");
        return uint(Error.SUCCESS);
    }
    function repayBorrowAllowed() external returns (uint) {
        require(!_borrowGuardianPaused, "FireComptroller::repayBorrowAllowed _borrowGuardianPaused failure");
        return uint(Error.SUCCESS);
    }
    function seizeAllowed(address _fTokenCollateral, address _fTokenBorrowed) external returns (uint) {
        require(!seizeGuardianPaused, "FireComptroller::seizeAllowedseize seizeGuardianPaused failure");
        if (!markets[_fTokenCollateral].isListed || !markets[_fTokenBorrowed].isListed) {
            return uint(Error.ERROR);
        }
        if (FToken(_fTokenCollateral).comptroller() != FToken(_fTokenBorrowed).comptroller()) {
            return uint(Error.ERROR);
        }
        return uint(Error.SUCCESS);
    }
    
    /**
     * @notice Checks if the account should be allowed to redeem tokens in the given market
     * @param _fToken fToken address
     * @param _redeemer address redeemer
     * @param _redeemTokens number
     * @return SUCCESS
     */
    function redeemAllowed(address _fToken, address _redeemer, uint _redeemTokens) external returns (uint) {
        return redeemAllowedInternal(_fToken, _redeemer, _redeemTokens);
    }

    function redeemAllowedInternal(address _fToken, address _redeemer, uint _redeemTokens) internal view returns (uint) {
        require(markets[_fToken].isListed, "FToken must be in the market");
        if (!markets[_fToken].accountMembership[_redeemer]) {
            return uint(Error.SUCCESS);
        }
        (Error err,, uint shortfall) = getHypotheticalAccountLiquidityInternal(_redeemer, FToken(_fToken), _redeemTokens, 0);
        require(err == Error.SUCCESS && shortfall <= 0, "getHypotheticalAccountLiquidityInternal failure");
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Validates redeem and reverts on rejection
     * @param _redeemAmount number
     * @param _redeemTokens number
     */
    function redeemVerify(uint _redeemAmount, uint _redeemTokens) external {
        if (_redeemTokens == 0 && _redeemAmount > 0) {
            revert("_redeemTokens zero");
        }
    }

    /**
     * @notice Checks if the account should be allowed to borrow the underlying asset of the given market
     * @param _fToken FToken address
     * @param _borrower address borrower
     * @param _borrowAmount number
     * @return SUCCESS
     */
    function borrowAllowed(address _fToken, address _borrower, uint _borrowAmount) external returns (uint) {
        require(!borrowGuardianPaused[_fToken], "FireComptroller::borrowAllowed borrowGuardianPaused failure");
        if (!markets[_fToken].isListed) {
            return uint(Error.ERROR);
        }
        if (!markets[_fToken].accountMembership[_borrower]) {
            require(msg.sender == _fToken, "FireComptroller::accountMembership failure");
            Error err = addToMarketInternal(FToken(msg.sender), _borrower);
            if (err != Error.SUCCESS) {
                return uint(err);
            }
            assert(markets[_fToken].accountMembership[_borrower]);
        }
        if (oracle.getUnderlyingPrice(_fToken) == 0) {
            return uint(Error.ERROR);
        }
        (Error err,, uint shortfall) = getHypotheticalAccountLiquidityInternal(_borrower, FToken(_fToken), 0, _borrowAmount);
        if (err != Error.SUCCESS) {
            return uint(err);
        }
        if (shortfall > 0) {
            return uint(Error.ERROR);
        }
        return uint(Error.SUCCESS);
    }

    function transferAllowed(address _fToken, address _src, uint _transferTokens) external returns (uint) {
        require(!transferGuardianPaused, "FireComptroller::transferAllowed failure");
        uint allowed = redeemAllowedInternal(_fToken, _src, _transferTokens); 
        if (allowed != uint(Error.SUCCESS)) {
            return allowed;
        }
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @param _account address account
     * @return SUCCESS, number, number
     */
    function getAccountLiquidity(address _account) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(_account, FToken(0), 0, 0);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine the current account liquidity wrt collateral requirements
     * @param _account address account
     * @return SUCCESS, number, number
     */
    function getAccountLiquidityInternal(address _account) internal view returns (Error, uint, uint) {
        return getHypotheticalAccountLiquidityInternal(_account, FToken(0), 0, 0);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @param _account address account
     * @param _fTokenModify address fToken
     * @param _redeemTokens number
     * @param _borrowAmount amount
     * @return ERROR, number, number
     */
    function getHypotheticalAccountLiquidity(address _account, address _fTokenModify, uint _redeemTokens, uint _borrowAmount) public view returns (uint, uint, uint) {
        (Error err, uint liquidity, uint shortfall) = getHypotheticalAccountLiquidityInternal(_account, FToken(_fTokenModify), _redeemTokens, _borrowAmount);
        return (uint(err), liquidity, shortfall);
    }

    /**
     * @notice Determine what the account liquidity would be if the given amounts were redeemed/borrowed
     * @dev sumCollateral += tokensToDenom * cTokenBalance
     * @dev sumBorrowPlusEffects += oraclePrice * borrowBalance
     * @dev sumBorrowPlusEffects += tokensToDenom * redeemTokens
     * @dev sumBorrowPlusEffects += oraclePrice * borrowAmount
     * @param _account address account
     * @param _fTokenModify address fToken
     * @param _redeemTokens number
     * @param _borrowAmount amount
     * @return ERROR, number, number
     */
    function getHypotheticalAccountLiquidityInternal(address _account, FToken _fTokenModify, uint _redeemTokens, uint _borrowAmount) internal view returns (Error, uint, uint) {
        AccountLiquidityLocalVars memory vars; // Holds all our calculation results
        uint oErr;
        MathError mErr;
        FToken[] memory assets = accountAssets[_account];
        for (uint i = 0; i < assets.length; i++) {
            FToken asset = assets[i];
            (oErr, vars.fTokenBalance, vars.borrowBalance, vars.exchangeRateMantissa) = asset.getAccountSnapshot(_account);
            if (oErr != 0) {
                return (Error.ERROR, 0, 0);
            }
            vars.collateralFactor = Exp({mantissa: markets[address(asset)].collateralFactorMantissa});
            vars.exchangeRate = Exp({mantissa: vars.exchangeRateMantissa});

            vars.oraclePriceMantissa = oracle.getUnderlyingPrice(address(asset));
            if (vars.oraclePriceMantissa == 0) {
                return (Error.ERROR, 0, 0);
            }
            vars.oraclePrice = Exp({mantissa: vars.oraclePriceMantissa});

            (mErr, vars.tokensToDenom) = mulExp3(vars.collateralFactor, vars.exchangeRate, vars.oraclePrice);
            if (mErr != MathError.NO_ERROR) {
                return (Error.ERROR, 0, 0);
            }

            (mErr, vars.sumCollateral) = mulScalarTruncateAddUInt(vars.tokensToDenom, vars.fTokenBalance, vars.sumCollateral);
            if (mErr != MathError.NO_ERROR) {
                return (Error.ERROR, 0, 0);
            }

            (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, vars.borrowBalance, vars.sumBorrowPlusEffects);
            if (mErr != MathError.NO_ERROR) {
                return (Error.ERROR, 0, 0);
            }

            if (asset == _fTokenModify) {
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.tokensToDenom, _redeemTokens, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.ERROR, 0, 0);
                } 
                (mErr, vars.sumBorrowPlusEffects) = mulScalarTruncateAddUInt(vars.oraclePrice, _borrowAmount, vars.sumBorrowPlusEffects);
                if (mErr != MathError.NO_ERROR) {
                    return (Error.ERROR, 0, 0);
                }
            }
        }
        if (vars.sumCollateral > vars.sumBorrowPlusEffects) {
            return (Error.SUCCESS, vars.sumCollateral - vars.sumBorrowPlusEffects, 0);
        } else {
            return (Error.SUCCESS, 0, vars.sumBorrowPlusEffects - vars.sumCollateral);
        }
    }

    /**
     * @notice Calculate number of tokens of collateral asset to seize given an underlying amount
     * @dev seizeAmount = actualRepayAmount * liquidationIncentive * priceBorrowed / priceCollateral
     * @dev seizeTokens = seizeAmount / exchangeRate = actualRepayAmount * (liquidationIncentive * priceBorrowed) / (priceCollateral * exchangeRate)
     * @param _fTokenBorrowed address borrow
     * @param _fTokenCollateral address collateral
     * @param _actualRepayAmount amount
     * @return SUCCESS, number
     */
    function liquidateCalculateSeizeTokens(address _fTokenBorrowed, address _fTokenCollateral, uint _actualRepayAmount) external view returns (uint, uint) {
        uint priceBorrowedMantissa = oracle.getUnderlyingPrice(_fTokenBorrowed);
        uint priceCollateralMantissa = oracle.getUnderlyingPrice(_fTokenCollateral);
        if (priceBorrowedMantissa == 0 || priceCollateralMantissa == 0) {
            return (uint(Error.ERROR), 0);
        }
        uint exchangeRateMantissa = FToken(_fTokenCollateral).exchangeRateStored();
        uint seizeTokens;
        Exp memory numerator;
        Exp memory denominator;
        Exp memory ratio;
        MathError mathErr;

        (mathErr, numerator) = mulExp(liquidationIncentiveMantissa, priceBorrowedMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.ERROR), 0);
        }
        (mathErr, denominator) = mulExp(priceCollateralMantissa, exchangeRateMantissa);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.ERROR), 0);
        }
        (mathErr, ratio) = divExp(numerator, denominator);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.ERROR), 0);
        }
        (mathErr, seizeTokens) = mulScalarTruncate(ratio, _actualRepayAmount);
        if (mathErr != MathError.NO_ERROR) {
            return (uint(Error.ERROR), 0);
        }
        return (uint(Error.SUCCESS), seizeTokens);
    }

    /**
      * @notice Sets a new price oracle
      * @param _newOracle address PriceOracle
      * @return SUCCESS
      */
    function _setPriceOracle(PriceOracle _newOracle) public returns (uint) {
        require(msg.sender == admin, "SET_PRICE_ORACLE_OWNER_CHECK");
        PriceOracle oldOracle = oracle;
        oracle = _newOracle;
        emit NewPriceOracle(oldOracle, _newOracle);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Sets the closeFactor used when liquidating borrows
     * @param _newCloseFactorMantissa number
     * @return SUCCESS
     */
    function _setCloseFactor(uint _newCloseFactorMantissa) external returns (uint) {
        require(msg.sender == admin, "SET_CLOSE_FACTOR_OWNER_CHECK");
        
        Exp memory newCloseFactorExp = Exp({mantissa: _newCloseFactorMantissa});
        Exp memory lowLimit = Exp({mantissa: closeFactorMinMantissa});
        if (lessThanOrEqualExp(newCloseFactorExp, lowLimit)) {
            return fail(Error.ERROR, ErrorRemarks.SET_CLOSE_FACTOR_VALIDATION, uint(Error.ERROR));
        }

        Exp memory highLimit = Exp({mantissa: closeFactorMaxMantissa});
        if (lessThanExp(highLimit, newCloseFactorExp)) {
            return fail(Error.ERROR, ErrorRemarks.SET_CLOSE_FACTOR_VALIDATION, uint(Error.ERROR));
        }
        uint oldCloseFactorMantissa = closeFactorMantissa;
        closeFactorMantissa = _newCloseFactorMantissa;

        emit NewCloseFactor(oldCloseFactorMantissa, closeFactorMantissa);
        return uint(Error.SUCCESS);
    }

    /**
     * @notice Sets the collateralFactor for a market
     * @param _fToken address FToken
     * @param _newCollateralFactorMantissa uint
     * @return SUCCESS
     */
    function _setCollateralFactor(FToken _fToken, uint _newCollateralFactorMantissa) external returns (uint) {
        require(msg.sender == admin, "SET_COLLATERAL_FACTOR_OWNER_CHECK");
        Market storage market = markets[address(_fToken)];
        if (!market.isListed) {
            return fail(Error.ERROR, ErrorRemarks.SET_COLLATERAL_FACTOR_NO_EXISTS, uint(Error.ERROR));
        }
        Exp memory newCollateralFactorExp = Exp({mantissa: _newCollateralFactorMantissa});
        Exp memory highLimit = Exp({mantissa: collateralFactorMaxMantissa});
        if (lessThanExp(highLimit, newCollateralFactorExp)) {
            return fail(Error.ERROR, ErrorRemarks.SET_COLLATERAL_FACTOR_VALIDATION, uint(Error.ERROR));
        }
        if (_newCollateralFactorMantissa != 0 && oracle.getUnderlyingPrice(address(_fToken)) == 0) {
            return fail(Error.ERROR, ErrorRemarks.SET_COLLATERAL_FACTOR_WITHOUT_PRICE, uint(Error.ERROR));
        }
        uint oldCollateralFactorMantissa = market.collateralFactorMantissa;
        market.collateralFactorMantissa = _newCollateralFactorMantissa;

        emit NewCollateralFactor(_fToken, oldCollateralFactorMantissa, _newCollateralFactorMantissa);
        return uint(Error.SUCCESS);
    }

    /**
      * @notice Sets maxAssets which controls how many markets can be entered
      * @param _newMaxAssets assets
      * @return SUCCESS
      */
    function _setMaxAssets(uint _newMaxAssets) external returns (uint) {
        require(msg.sender == admin, "SET_MAX_ASSETS_OWNER_CHECK");
        
        uint oldMaxAssets = maxAssets;
        maxAssets = _newMaxAssets; // push storage

        emit NewMaxAssets(oldMaxAssets, _newMaxAssets);
        return uint(Error.SUCCESS);
    }

    /**
      * @notice Sets liquidationIncentive
      * @param _newLiquidationIncentiveMantissa uint _newLiquidationIncentiveMantissa
      * @return SUCCESS
      */
    function _setLiquidationIncentive(uint _newLiquidationIncentiveMantissa) external returns (uint) {
        require(msg.sender == admin, "SET_LIQUIDATION_INCENTIVE_OWNER_CHECK");

        Exp memory newLiquidationIncentive = Exp({mantissa: _newLiquidationIncentiveMantissa});
        Exp memory minLiquidationIncentive = Exp({mantissa: liquidationIncentiveMinMantissa});
        if (lessThanExp(newLiquidationIncentive, minLiquidationIncentive)) {
            return fail(Error.ERROR, ErrorRemarks.SET_LIQUIDATION_INCENTIVE_VALIDATION, uint(Error.ERROR));
        }

        Exp memory maxLiquidationIncentive = Exp({mantissa: liquidationIncentiveMaxMantissa});
        if (lessThanExp(maxLiquidationIncentive, newLiquidationIncentive)) {
            return fail(Error.ERROR, ErrorRemarks.SET_LIQUIDATION_INCENTIVE_VALIDATION, uint(Error.ERROR));
        }
        uint oldLiquidationIncentiveMantissa = liquidationIncentiveMantissa;
        liquidationIncentiveMantissa = _newLiquidationIncentiveMantissa; // push storage

        emit NewLiquidationIncentive(oldLiquidationIncentiveMantissa, _newLiquidationIncentiveMantissa);
        return uint(Error.SUCCESS);
    }

    /**
      * @notice Add the market to the markets mapping and set it as listed
      * @param _fToken FToken address
      * @return SUCCESS
      */
    function _supportMarket(FToken _fToken) external returns (uint) {
        require(msg.sender == admin, "change not authorized");
        if (markets[address(_fToken)].isListed) {
            return fail(Error.ERROR, ErrorRemarks.SUPPORT_MARKET_EXISTS, uint(Error.ERROR));
        }
        _fToken.fToken();
        markets[address(_fToken)] = Market({isListed: true, collateralFactorMantissa: 0});
        _addMarketInternal(address(_fToken));
        emit MarketListed(_fToken);
        return uint(Error.SUCCESS);
    }
    function _addMarketInternal(address _fToken) internal {
        for (uint i = 0; i < allMarkets.length; i ++) {
            require(allMarkets[i] != FToken(_fToken), "FireComptroller::_addMarketInternal failure");
        }
        allMarkets.push(FToken(_fToken));
    }

    /**
     * @notice Admin function to change the Pause Guardian
     * @param _newPauseGuardian uint
     * @return SUCCESS
     */
    function _setPauseGuardian(address _newPauseGuardian) public returns (uint) {
        require(msg.sender == admin, "change not authorized");
        address oldPauseGuardian = pauseGuardian;
        pauseGuardian = _newPauseGuardian;
        emit NewPauseGuardian(oldPauseGuardian, pauseGuardian);
        return uint(Error.SUCCESS);
    }

    function _setMintPaused(FToken _fToken, bool _state) public returns (bool) {
        require(markets[address(_fToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || _state == true, "only admin can unpause");

        mintGuardianPaused[address(_fToken)] = _state;
        emit ActionPaused(_fToken, "Mint", _state);
        return _state;
    }

    function _setBorrowPaused(FToken _fToken, bool _state) public returns (bool) {
        require(markets[address(_fToken)].isListed, "cannot pause a market that is not listed");
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || _state == true, "only admin can unpause");

        borrowGuardianPaused[address(_fToken)] = _state;
        emit ActionPaused(_fToken, "Borrow", _state);
        return _state;
    }

    function _setTransferPaused(bool _state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || _state == true, "only admin can unpause");

        transferGuardianPaused = _state;
        emit ActionPaused("Transfer", _state);
        return _state;
    }

    function _setSeizePaused(bool _state) public returns (bool) {
        require(msg.sender == pauseGuardian || msg.sender == admin, "only pause guardian and admin can pause");
        require(msg.sender == admin || _state == true, "only admin can unpause");

        seizeGuardianPaused = _state;
        emit ActionPaused("Seize", _state);
        return _state;
    }

    function _become(Unitroller _unitroller) public {
        require(msg.sender == _unitroller.admin(), "only unitroller admin can change brains");
        require(_unitroller._acceptImplementation() == 0, "change not authorized");
    }

    /**
     * @notice Checks caller is admin, or this contract is becoming the new implementation
     * @return bool
     */
    function adminOrInitializing() internal view returns (bool) {
        return msg.sender == admin || msg.sender == comptrollerImplementation;
    }

    event NewMintGuardianPaused(bool _oldState, bool _newState);
    function _setMintGuardianPaused(bool _state) public returns (bool) {
        require(msg.sender == admin, "change not authorized");
        bool _oldState = _mintGuardianPaused;
        _mintGuardianPaused = _state;
        emit NewMintGuardianPaused(_oldState, _state);
        return _state;
    }

    event NewBorrowGuardianPaused(bool _oldState, bool _newState);
    function _setBorrowGuardianPaused(bool _state) public returns (bool) {
        require(msg.sender == admin, "change not authorized");
        bool _oldState = _borrowGuardianPaused;
        _borrowGuardianPaused = _state;
        emit NewBorrowGuardianPaused(_oldState, _state);
        return _state;
    }

    function liquidateBorrowAllowed(address _cTokenBorrowed, address _fTokenInterface, address _liquidates, address _borrower, uint _repayAmount) external returns (uint) {
        require(markets[_cTokenBorrowed].isListed && markets[_fTokenInterface].isListed, "FireComptroller::repayBorrowAllowed market not listed");
        
        (Error err, , ) = getAccountLiquidityInternal(_borrower);
        require(uint(err) == uint(Error.SUCCESS), "FireComptroller::getAccountLiquidityInternal failure");
        
        uint borrowBalance = FToken(_cTokenBorrowed).borrowBalanceStored(_borrower);
        (MathError mathErr, uint maxClose) = mulScalarTruncate(Exp({mantissa: closeFactorMantissa}), borrowBalance);
        
        require(mathErr == MathError.NO_ERROR, "FireComptroller::mulScalarTruncate failure");
        require(_repayAmount <= maxClose, "FireComptroller::_repayAmount must be less than or equal to maxClose");
        
        return uint(Error.SUCCESS);
    }

    struct AccountLiquidityLocalVars {
        uint sumCollateral;
        uint sumBorrowPlusEffects;
        uint fTokenBalance;
        uint borrowBalance;
        uint exchangeRateMantissa;
        uint oraclePriceMantissa;
        Exp collateralFactor;
        Exp exchangeRate;
        Exp oraclePrice;
        Exp tokensToDenom;
    }

    event MarketListed(FToken _fToken);
    event MarketEntered(FToken _fToken, address _account);
    event MarketExited(FToken _fToken, address _account);
    event NewCloseFactor(uint _oldCloseFactorMantissa, uint _newCloseFactorMantissa);
    event NewCollateralFactor(FToken _fToken, uint _oldCollateralFactorMantissa, uint _newCollateralFactorMantissa);
    event NewLiquidationIncentive(uint _oldLiquidationIncentiveMantissa, uint _newLiquidationIncentiveMantissa);
    event NewMaxAssets(uint _oldMaxAssets, uint _newMaxAssets);
    event NewPriceOracle(PriceOracle _oldPriceOracle, PriceOracle _newPriceOracle);
    event NewPauseGuardian(address _oldPauseGuardian, address _newPauseGuardian);
    event ActionPaused(string _action, bool _pauseState);
    event ActionPaused(FToken _fToken, string _action, bool _pauseState);
    event DistributedSupplierComp(FToken indexed _fToken, address indexed _supplier, uint _compDelta, uint _compSupplyIndex);
    event DistributedBorrowerComp(FToken indexed _fToken, address indexed _borrower, uint _compDelta, uint _compBorrowIndex);
}