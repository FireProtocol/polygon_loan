pragma solidity ^0.5.16;

/**
 * @title Fire Comptroller Interface
 * @author Fire
 */
contract FireComptrollerInterface {
    bool public constant fireComptroller = true;

    function enterMarkets(address[] calldata _fTokens) external returns (uint[] memory);
    
    function exitMarket(address _fToken) external returns (uint);

    function mintAllowed() external returns (uint);

    function redeemAllowed(address _fToken, address _redeemer, uint _redeemTokens) external returns (uint);
    
    function redeemVerify(uint _redeemAmount, uint _redeemTokens) external;

    function borrowAllowed(address _fToken, address _borrower, uint _borrowAmount) external returns (uint);

    function repayBorrowAllowed() external returns (uint);

    function seizeAllowed(address _fTokenCollateral, address _fTokenBorrowed) external returns (uint);

    function transferAllowed(address _fToken, address _src, uint _transferTokens) external returns (uint);

    function liquidateBorrowAllowed(address _fTokenBorrowed, address _fTokenCollateral, address _liquidator, address _borrower, uint _repayAmount) external returns (uint);

    /**
     * @notice liquidation
     */
    function liquidateCalculateSeizeTokens(address _fTokenBorrowed, address _fTokenCollateral, uint _repayAmount) external view returns (uint, uint);
}