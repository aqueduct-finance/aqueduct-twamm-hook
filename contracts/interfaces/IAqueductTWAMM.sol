// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";

interface IAqueductTWAMM {
    /// @notice Thrown when account other than owner attempts to interact with an order
    /// @param owner The owner of the order
    /// @param currentAccount The invalid account attempting to interact with the order
    error MustBeOwner(address owner, address currentAccount);

    /// @notice Thrown when trying to cancel an already completed order
    /// @param orderKey The orderKey
    error CannotModifyCompletedOrder(OrderKey orderKey);

    /// @notice Thrown when trying to submit an order with an expiration that isn't on the interval.
    /// @param expiration The expiration timestamp of the order
    error ExpirationNotOnInterval(uint256 expiration);

    /// @notice Thrown when trying to submit an order with an expiration time in the past.
    /// @param expiration The expiration timestamp of the order
    error ExpirationLessThanBlocktime(uint256 expiration);

    /// @notice Thrown when trying to submit an order without initializing TWAMM state first
    error NotInitialized();

    /// @notice Thrown when trying to submit an order that's already ongoing.
    /// @param orderKey The already existing orderKey
    error OrderAlreadyExists(OrderKey orderKey);

    /// @notice Thrown when trying to interact with an order that does not exist.
    /// @param orderKey The already existing orderKey
    error OrderDoesNotExist(OrderKey orderKey);

    /// @notice Thrown when trying to subtract more value from a long term order than exists
    /// @param orderKey The orderKey
    /// @param unsoldAmount The amount still unsold
    /// @param amountDelta The amount delta for the order
    error InvalidAmountDelta(OrderKey orderKey, uint256 unsoldAmount, int256 amountDelta);

    /// @notice Thrown when submitting an order with a sellRate of 0
    error SellRateCannotBeZero();

    /// @notice Information associated with a long term order
    /// @member sellRate Amount of tokens sold per interval
    /// @member earningsFactorLast The accrued earnings factor from which to start claiming owed earnings for this order
    struct Order {
        uint256 sellRate;
        uint256 earningsFactorLast;
    }

    /// @notice Information that identifies an order
    /// @member owner Owner of the order
    /// @member expiration Timestamp when the order expires
    /// @member zeroForOne Bool whether the order is zeroForOne
    struct OrderKey {
        address owner;
        bool zeroForOne;
    }

    /// @notice Emitted when a new long term order is submitted
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the new order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The sell rate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    event SubmitOrder(
        bytes32 indexed poolId,
        address indexed owner,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    /// @notice Emitted when a long term order is updated
    /// @param poolId The id of the corresponding pool
    /// @param owner The owner of the existing order
    /// @param zeroForOne Whether the order is selling token 0 for token 1
    /// @param sellRate The updated sellRate of tokens per second being sold in the order
    /// @param earningsFactorLast The current earningsFactor of the order pool
    ///   (since updated orders will claim existing earnings)
    event UpdateOrder(
        bytes32 indexed poolId,
        address indexed owner,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    /// @notice Claim tokens owed from TWAMM contract
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for which to identify the order
    /// @param to The receipient of the claim
    /// @param amountRequested The amount of tokens requested to claim. Set to 0 to claim all.
    /// @return amountTransferred The total token amount to be collected
    function claimTokens(IPoolManager.PoolKey memory key, OrderKey memory orderKey, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred);

    /// @notice Executes TWAMM orders on the pool, swapping on the pool itself to make up the difference between the
    /// two TWAMM pools swapping against each other
    /// @param key The pool key associated with the TWAMM
    function executeTWAMMOrders(IPoolManager.PoolKey memory key) external;

    function tokensOwed(Currency token, address owner) external returns (uint256);
}
