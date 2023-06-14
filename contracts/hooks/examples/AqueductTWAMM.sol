// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickBitmap} from "@uniswap/v4-core/contracts/libraries/TickBitmap.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/contracts/libraries/SqrtPriceMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/contracts/libraries/FixedPoint96.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {SafeCast} from "@uniswap/v4-core/contracts/libraries/SafeCast.sol";
import {BaseHook} from "../../BaseHook.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {IAqueductTWAMM} from "../../interfaces/IAqueductTWAMM.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {TransferHelper} from "../../libraries/TransferHelper.sol";
import {TwammMath} from "../../libraries/TWAMM/TwammMath.sol";
import {AqueductOrderPool} from "../../libraries/TWAMM/AqueductOrderPool.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/contracts/types/BalanceDelta.sol";
import {PoolGetters} from "../../libraries/PoolGetters.sol";
import {ISuperfluid, ISuperToken, ISuperfluidToken, ISuperApp, ISuperAgreement, SuperAppDefinitions} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {SuperAppBase} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperAppBase.sol";
import {CFAv1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/CFAv1Library.sol";
import {IConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/agreements/IConstantFlowAgreementV1.sol";

contract AqueductTWAMM is BaseHook, IAqueductTWAMM, SuperAppBase {
    using TransferHelper for IERC20Minimal;
    using CurrencyLibrary for Currency;
    using AqueductOrderPool for AqueductOrderPool.State;
    using PoolId for IPoolManager.PoolKey;
    using TickMath for int24;
    using TickMath for uint160;
    using SafeCast for uint256;
    using PoolGetters for IPoolManager;
    using TickBitmap for mapping(int16 => uint256);

    int256 internal constant MIN_DELTA = -1;
    bool internal constant ZERO_FOR_ONE = true;
    bool internal constant ONE_FOR_ZERO = false;

    /// @notice Contains full state related to the TWAMM
    /// @member lastVirtualOrderTimestamp Last timestamp in which virtual orders were executed
    /// @member orderPool0For1 Order pool trading token0 for token1 of pool
    /// @member orderPool1For0 Order pool trading token1 for token0 of pool
    /// @member orders Mapping of orderId to individual orders on pool
    struct State {
        uint256 lastVirtualOrderTimestamp;
        AqueductOrderPool.State orderPool0For1;
        AqueductOrderPool.State orderPool1For0;
        mapping(bytes32 => Order) orders;
    }

    // twammStates[poolId] => Twamm.State
    mapping(bytes32 => State) internal twammStates;
    // tokensOwed[token][owner] => amountOwed
    mapping(Currency => mapping(address => uint256)) public tokensOwed;

    // superfluid
    using CFAv1Library for CFAv1Library.InitData;
    CFAv1Library.InitData public cfaV1;
    bytes32 public constant CFA_ID =
        keccak256("org.superfluid-finance.agreements.ConstantFlowAgreement.v1");
    IConstantFlowAgreementV1 cfa;
    ISuperfluid _host;

    constructor(IPoolManager _poolManager, ISuperfluid host) BaseHook(_poolManager) {
        assert(address(host) != address(0));

        // register superapp
        _host = host;
        cfa = IConstantFlowAgreementV1(address(host.getAgreementClass(CFA_ID)));
        cfaV1 = CFAv1Library.InitData(host, cfa);
        uint256 configWord =
            SuperAppDefinitions.APP_LEVEL_FINAL |
            SuperAppDefinitions.BEFORE_AGREEMENT_CREATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_UPDATED_NOOP |
            SuperAppDefinitions.BEFORE_AGREEMENT_TERMINATED_NOOP;
        host.registerApp(configWord);
    }

    function getHooksCalls() public pure override returns (Hooks.Calls memory) {
        return Hooks.Calls({
            beforeInitialize: true,
            afterInitialize: false,
            beforeModifyPosition: true,
            afterModifyPosition: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false
        });
    }

    function beforeInitialize(address, IPoolManager.PoolKey calldata key, uint160)
        external
        virtual
        override
        poolManagerOnly
        returns (bytes4)
    {
        // one-time initialization enforced in PoolManager
        initialize(_getTWAMM(key));
        return BaseHook.beforeInitialize.selector;
    }

    function beforeModifyPosition(
        address,
        IPoolManager.PoolKey calldata key,
        IPoolManager.ModifyPositionParams calldata
    ) external override poolManagerOnly returns (bytes4) {
        executeTWAMMOrders(key);
        return BaseHook.beforeModifyPosition.selector;
    }

    function beforeSwap(address, IPoolManager.PoolKey calldata key, IPoolManager.SwapParams calldata)
        external
        override
        poolManagerOnly
        returns (bytes4)
    {
        executeTWAMMOrders(key);
        return BaseHook.beforeSwap.selector;
    }

    function lastVirtualOrderTimestamp(bytes32 key) external view returns (uint256) {
        return twammStates[key].lastVirtualOrderTimestamp;
    }

    function getOrder(IPoolManager.PoolKey calldata poolKey, OrderKey calldata orderKey)
        external
        view
        returns (Order memory)
    {
        return _getOrder(twammStates[keccak256(abi.encode(poolKey))], orderKey);
    }

    function getOrderPool(IPoolManager.PoolKey calldata key, bool zeroForOne)
        external
        view
        returns (uint256 sellRateCurrent, uint256 earningsFactorCurrent)
    {
        State storage twamm = _getTWAMM(key);
        return zeroForOne
            ? (twamm.orderPool0For1.sellRateCurrent, twamm.orderPool0For1.earningsFactorCurrent)
            : (twamm.orderPool1For0.sellRateCurrent, twamm.orderPool1For0.earningsFactorCurrent);
    }

    /// @notice Initialize TWAMM state
    function initialize(State storage self) internal {
        self.lastVirtualOrderTimestamp = block.timestamp;
    }

    struct CallbackData {
        address sender;
        IPoolManager.PoolKey key;
        IPoolManager.SwapParams params;
    }

    /// @inheritdoc IAqueductTWAMM
    function executeTWAMMOrders(IPoolManager.PoolKey memory key) public {
        bytes32 poolId = key.toId();
        (uint160 sqrtPriceX96,,) = poolManager.getSlot0(poolId);
        State storage twamm = twammStates[poolId];

        (bool zeroForOne, uint160 sqrtPriceLimitX96) = _executeTWAMMOrders(
            twamm, poolManager, key, PoolParamsOnExecute(sqrtPriceX96, poolManager.getLiquidity(poolId))
        );

        if (sqrtPriceLimitX96 != 0 && sqrtPriceLimitX96 != sqrtPriceX96) {
            poolManager.lock(abi.encode(key, IPoolManager.SwapParams(zeroForOne, type(int256).max, sqrtPriceLimitX96)));
        }
    }

    /// @notice Submits a new long term order into the TWAMM. Also executes TWAMM orders if not up to date.
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for the new order
    /// @param sellRate the per second 'flow rate' of the token being sold
    /// @return orderId The bytes32 ID of the order
    function submitOrder(IPoolManager.PoolKey memory key, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        State storage twamm = twammStates[poolId];

        unchecked {
            // checks done in TWAMM library
            orderId = _submitOrder(twamm, orderKey, sellRate);
        }

        emit SubmitOrder(
            poolId,
            orderKey.owner,
            orderKey.zeroForOne,
            sellRate,
            _getOrder(twamm, orderKey).earningsFactorLast
        );
    }

    /// @notice Submits a new long term order into the TWAMM
    /// @dev executeTWAMMOrders must be executed up to current timestamp before calling submitOrder
    /// @param orderKey The OrderKey for the new order
    function _submitOrder(State storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (bytes32 orderId)
    {
        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (self.lastVirtualOrderTimestamp == 0) revert NotInitialized();
        if (sellRate == 0) revert SellRateCannotBeZero();

        orderId = _orderId(orderKey);
        if (self.orders[orderId].sellRate != 0) revert OrderAlreadyExists(orderKey);

        AqueductOrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        unchecked {
            orderPool.sellRateCurrent += sellRate;
        }

        self.orders[orderId] = Order({sellRate: sellRate, earningsFactorLast: orderPool.earningsFactorCurrent});
    }

    /// @notice Update an existing long term order with current earnings, optionally modify the amount selling.
    /// @param key The PoolKey for which to identify the amm pool of the order
    /// @param orderKey The OrderKey for which to identify the order
    /// @param sellRate the per second 'flow rate' of the token being sold
    function updateOrder(IPoolManager.PoolKey memory key, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (uint256 tokens0Owed, uint256 tokens1Owed)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        State storage twamm = twammStates[poolId];

        // This call reverts if the caller is not the owner of the order
        (uint256 buyTokensOwed, uint256 newEarningsFactorLast) =
            _updateOrder(twamm, orderKey, sellRate);

        if (orderKey.zeroForOne) {
            tokens1Owed += buyTokensOwed;
            tokensOwed[key.currency1][orderKey.owner] += tokens1Owed;
        } else {
            tokens0Owed += buyTokensOwed;
            tokensOwed[key.currency0][orderKey.owner] += tokens0Owed;
        }

        emit UpdateOrder(
            poolId, orderKey.owner, orderKey.zeroForOne, sellRate, newEarningsFactorLast
        );
    }

    function _updateOrder(State storage self, OrderKey memory orderKey, uint256 sellRate)
        internal
        returns (uint256 buyTokensOwed, uint256 earningsFactorLast)
    {
        Order storage order = _getOrder(self, orderKey);
        AqueductOrderPool.State storage orderPool = orderKey.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;

        if (orderKey.owner != msg.sender) revert MustBeOwner(orderKey.owner, msg.sender);
        if (order.sellRate == 0) revert OrderDoesNotExist(orderKey);

        unchecked {
            uint256 earningsFactor = orderPool.earningsFactorCurrent - order.earningsFactorLast;
            buyTokensOwed = (earningsFactor * order.sellRate) >> FixedPoint96.RESOLUTION;
            earningsFactorLast = orderPool.earningsFactorCurrent;
            order.earningsFactorLast = earningsFactorLast;

            int256 sellRateDelta = int(sellRate) - int(order.sellRate);
            if (sellRateDelta != 0) {
                if (sellRateDelta < 0) {
                    uint256 unsignedSellRateDelta = order.sellRate - sellRate;
                    orderPool.sellRateCurrent -= unsignedSellRateDelta;
                } else {
                    uint256 unsignedSellRateDelta = sellRate - order.sellRate;
                    orderPool.sellRateCurrent += unsignedSellRateDelta;
                }
                if (sellRate == 0) {
                    delete self.orders[_orderId(orderKey)];
                } else {
                    order.sellRate = sellRate;
                }
            }
        }
    }

    /// @inheritdoc IAqueductTWAMM
    function claimTokens(Currency token, address to, uint256 amountRequested)
        external
        returns (uint256 amountTransferred)
    {
        uint256 currentBalance = token.balanceOfSelf();
        amountTransferred = tokensOwed[token][msg.sender];
        if (amountRequested != 0 && amountRequested < amountTransferred) amountTransferred = amountRequested;
        if (currentBalance < amountTransferred) amountTransferred = currentBalance; // to catch precision errors
        IERC20Minimal(Currency.unwrap(token)).safeTransfer(to, amountTransferred);
    }

    function lockAcquired(uint256, bytes calldata rawData) external override poolManagerOnly returns (bytes memory) {
        (IPoolManager.PoolKey memory key, IPoolManager.SwapParams memory swapParams) =
            abi.decode(rawData, (IPoolManager.PoolKey, IPoolManager.SwapParams));

        BalanceDelta delta = poolManager.swap(key, swapParams);

        if (swapParams.zeroForOne) {
            if (delta.amount0() > 0) {
                key.currency0.transfer(address(poolManager), uint256(uint128(delta.amount0())));
                poolManager.settle(key.currency0);
            }
            if (delta.amount1() < 0) {
                poolManager.take(key.currency1, address(this), uint256(uint128(-delta.amount1())));
            }
        } else {
            if (delta.amount1() > 0) {
                key.currency1.transfer(address(poolManager), uint256(uint128(delta.amount1())));
                poolManager.settle(key.currency1);
            }
            if (delta.amount0() < 0) {
                poolManager.take(key.currency0, address(this), uint256(uint128(-delta.amount0())));
            }
        }
        return bytes("");
    }

    function _getTWAMM(IPoolManager.PoolKey memory key) private view returns (State storage) {
        return twammStates[keccak256(abi.encode(key))];
    }

    struct OrderParams {
        address owner;
        bool zeroForOne;
        uint256 amountIn;
        uint160 expiration;
    }

    struct PoolParamsOnExecute {
        uint160 sqrtPriceX96;
        uint128 liquidity;
    }

    /// @notice Executes all existing long term orders in the TWAMM
    /// @param pool The relevant state of the pool
    function _executeTWAMMOrders(
        State storage self,
        IPoolManager poolManager,
        IPoolManager.PoolKey memory key,
        PoolParamsOnExecute memory pool
    ) internal returns (bool zeroForOne, uint160 newSqrtPriceX96) {
        if (!_hasOutstandingOrders(self)) {
            self.lastVirtualOrderTimestamp = block.timestamp;
            return (false, 0);
        }

        uint160 initialSqrtPriceX96 = pool.sqrtPriceX96;
        uint256 prevTimestamp = self.lastVirtualOrderTimestamp;

        AqueductOrderPool.State storage orderPool0For1 = self.orderPool0For1;
        AqueductOrderPool.State storage orderPool1For0 = self.orderPool1For0;

        unchecked {
            if (prevTimestamp < block.timestamp && _hasOutstandingOrders(self)) {
                if (orderPool0For1.sellRateCurrent != 0 && orderPool1For0.sellRateCurrent != 0) {
                    pool = _advanceToNewTimestamp(
                        self,
                        poolManager,
                        key,
                        AdvanceParams(block.timestamp, block.timestamp - prevTimestamp, pool)
                    );
                } else {
                    pool = _advanceTimestampForSinglePoolSell(
                        self,
                        poolManager,
                        key,
                        AdvanceSingleParams(
                            block.timestamp,
                            block.timestamp - prevTimestamp,
                            pool,
                            orderPool0For1.sellRateCurrent != 0
                        )
                    );
                }
            }
        }

        self.lastVirtualOrderTimestamp = block.timestamp;
        newSqrtPriceX96 = pool.sqrtPriceX96;
        zeroForOne = initialSqrtPriceX96 > newSqrtPriceX96;
    }

    struct AdvanceParams {
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
    }

    function _advanceToNewTimestamp(
        State storage self,
        IPoolManager poolManager,
        IPoolManager.PoolKey memory poolKey,
        AdvanceParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        uint160 finalSqrtPriceX96;
        uint256 secondsElapsedX96 = params.secondsElapsed * FixedPoint96.Q96;

        AqueductOrderPool.State storage orderPool0For1 = self.orderPool0For1;
        AqueductOrderPool.State storage orderPool1For0 = self.orderPool1For0;

        while (true) {
            TwammMath.ExecutionUpdateParams memory executionParams = TwammMath.ExecutionUpdateParams(
                secondsElapsedX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                orderPool0For1.sellRateCurrent,
                orderPool1For0.sellRateCurrent
            );

            finalSqrtPriceX96 = TwammMath.getNewSqrtPriceX96(executionParams);

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolManager, poolKey, finalSqrtPriceX96);
            unchecked {
                if (crossingInitializedTick) {
                    uint256 secondsUntilCrossingX96;
                    (params.pool, secondsUntilCrossingX96) = _advanceTimeThroughTickCrossing(
                        self,
                        poolManager,
                        poolKey,
                        TickCrossingParams(tick, params.nextTimestamp, secondsElapsedX96, params.pool)
                    );
                    secondsElapsedX96 = secondsElapsedX96 - secondsUntilCrossingX96;
                } else {
                    (uint256 earningsFactorPool0, uint256 earningsFactorPool1) =
                        TwammMath.calculateEarningsUpdates(executionParams, finalSqrtPriceX96);

                    orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
                    orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

                    params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                    break;
                }
            }
        }

        return params.pool;
    }

    struct AdvanceSingleParams {
        uint256 nextTimestamp;
        uint256 secondsElapsed;
        PoolParamsOnExecute pool;
        bool zeroForOne;
    }

    function _advanceTimestampForSinglePoolSell(
        State storage self,
        IPoolManager poolManager,
        IPoolManager.PoolKey memory poolKey,
        AdvanceSingleParams memory params
    ) private returns (PoolParamsOnExecute memory) {
        AqueductOrderPool.State storage orderPool = params.zeroForOne ? self.orderPool0For1 : self.orderPool1For0;
        uint256 sellRateCurrent = orderPool.sellRateCurrent;
        uint256 amountSelling = sellRateCurrent * params.secondsElapsed;
        uint256 totalEarnings;

        while (true) {
            uint160 finalSqrtPriceX96 = SqrtPriceMath.getNextSqrtPriceFromInput(
                params.pool.sqrtPriceX96, params.pool.liquidity, amountSelling, params.zeroForOne
            );

            (bool crossingInitializedTick, int24 tick) =
                _isCrossingInitializedTick(params.pool, poolManager, poolKey, finalSqrtPriceX96);

            if (crossingInitializedTick) {
                int128 liquidityNetAtTick = poolManager.getNetLiquidityAtTick(poolKey.toId(), tick);
                uint160 initializedSqrtPrice = TickMath.getSqrtRatioAtTick(tick);

                uint256 swapDelta0 = SqrtPriceMath.getAmount0Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );
                uint256 swapDelta1 = SqrtPriceMath.getAmount1Delta(
                    params.pool.sqrtPriceX96, initializedSqrtPrice, params.pool.liquidity, true
                );

                params.pool.liquidity = params.zeroForOne
                    ? params.pool.liquidity - uint128(liquidityNetAtTick)
                    : params.pool.liquidity + uint128(-liquidityNetAtTick);
                params.pool.sqrtPriceX96 = initializedSqrtPrice;

                unchecked {
                    totalEarnings += params.zeroForOne ? swapDelta1 : swapDelta0;
                    amountSelling -= params.zeroForOne ? swapDelta0 : swapDelta1;
                }
            } else {
                if (params.zeroForOne) {
                    totalEarnings += SqrtPriceMath.getAmount1Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                } else {
                    totalEarnings += SqrtPriceMath.getAmount0Delta(
                        params.pool.sqrtPriceX96, finalSqrtPriceX96, params.pool.liquidity, true
                    );
                }

                uint256 accruedEarningsFactor = (totalEarnings * FixedPoint96.Q96) / sellRateCurrent;

                orderPool.advanceToCurrentTime(accruedEarningsFactor);
                params.pool.sqrtPriceX96 = finalSqrtPriceX96;
                break;
            }
        }

        return params.pool;
    }

    struct TickCrossingParams {
        int24 initializedTick;
        uint256 nextTimestamp;
        uint256 secondsElapsedX96;
        PoolParamsOnExecute pool;
    }

    function _advanceTimeThroughTickCrossing(
        State storage self,
        IPoolManager poolManager,
        IPoolManager.PoolKey memory poolKey,
        TickCrossingParams memory params
    ) private returns (PoolParamsOnExecute memory, uint256) {
        uint160 initializedSqrtPrice = params.initializedTick.getSqrtRatioAtTick();

        uint256 secondsUntilCrossingX96 = TwammMath.calculateTimeBetweenTicks(
            params.pool.liquidity,
            params.pool.sqrtPriceX96,
            initializedSqrtPrice,
            self.orderPool0For1.sellRateCurrent,
            self.orderPool1For0.sellRateCurrent
        );

        (uint256 earningsFactorPool0, uint256 earningsFactorPool1) = TwammMath.calculateEarningsUpdates(
            TwammMath.ExecutionUpdateParams(
                secondsUntilCrossingX96,
                params.pool.sqrtPriceX96,
                params.pool.liquidity,
                self.orderPool0For1.sellRateCurrent,
                self.orderPool1For0.sellRateCurrent
            ),
            initializedSqrtPrice
        );

        self.orderPool0For1.advanceToCurrentTime(earningsFactorPool0);
        self.orderPool1For0.advanceToCurrentTime(earningsFactorPool1);

        unchecked {
            // update pool
            int128 liquidityNet = poolManager.getNetLiquidityAtTick(poolKey.toId(), params.initializedTick);
            if (initializedSqrtPrice < params.pool.sqrtPriceX96) liquidityNet = -liquidityNet;
            params.pool.liquidity = liquidityNet < 0
                ? params.pool.liquidity - uint128(-liquidityNet)
                : params.pool.liquidity + uint128(liquidityNet);

            params.pool.sqrtPriceX96 = initializedSqrtPrice;
        }
        return (params.pool, secondsUntilCrossingX96);
    }

    function _isCrossingInitializedTick(
        PoolParamsOnExecute memory pool,
        IPoolManager poolManager,
        IPoolManager.PoolKey memory poolKey,
        uint160 nextSqrtPriceX96
    ) internal view returns (bool crossingInitializedTick, int24 nextTickInit) {
        // use current price as a starting point for nextTickInit
        nextTickInit = pool.sqrtPriceX96.getTickAtSqrtRatio();
        int24 targetTick = nextSqrtPriceX96.getTickAtSqrtRatio();
        bool searchingLeft = nextSqrtPriceX96 < pool.sqrtPriceX96;
        bool nextTickInitFurtherThanTarget = false; // initialize as false

        // nextTickInit returns the furthest tick within one word if no tick within that word is initialized
        // so we must keep iterating if we haven't reached a tick further than our target tick
        while (!nextTickInitFurtherThanTarget) {
            unchecked {
                if (searchingLeft) nextTickInit -= 1;
            }
            (nextTickInit, crossingInitializedTick) = poolManager.getNextInitializedTickWithinOneWord(
                poolKey.toId(), nextTickInit, poolKey.tickSpacing, searchingLeft
            );
            nextTickInitFurtherThanTarget = searchingLeft ? nextTickInit <= targetTick : nextTickInit > targetTick;
            if (crossingInitializedTick == true) break;
        }
        if (nextTickInitFurtherThanTarget) crossingInitializedTick = false;
    }

    function _getOrder(State storage self, OrderKey memory key) internal view returns (Order storage) {
        return self.orders[_orderId(key)];
    }

    function _orderId(OrderKey memory key) private pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    function _hasOutstandingOrders(State storage self) internal view returns (bool) {
        return self.orderPool0For1.sellRateCurrent != 0 || self.orderPool1For0.sellRateCurrent != 0;
    }

    function _handleSuperfluidCallback(
        ISuperToken _superToken,
        bytes calldata _agreementData,
        bytes calldata _ctx
    ) internal {
        // decode superfluid context and decode userData into the pool key
        ISuperfluid.Context memory decompiledContext = cfaV1.host.decodeCtx(_ctx);
        IPoolManager.PoolKey memory key = abi.decode(decompiledContext.userData, (IPoolManager.PoolKey));

        // execute twamm orders up to this point
        executeTWAMMOrders(key);

        // get user and flowrate
        (address user, ) = abi.decode(_agreementData, (address, address));
        (, int96 flowRate, , ) = cfa.getFlow(_superToken, user, address(this));
        uint256 sellRate = uint(int(flowRate));

        // create order key and get order id
        OrderKey memory orderKey = OrderKey({owner: user, zeroForOne: address(_superToken) == Currency.unwrap(key.currency0)});
        bytes32 orderId = _orderId(orderKey);

        // get pool state
        State storage twamm = _getTWAMM(key);

        // submit order
        if (twamm.orders[orderId].sellRate == 0) {
            submitOrder(key, orderKey, sellRate);
        } else {
            updateOrder(key, orderKey, sellRate);
        }
    }

    function afterAgreementCreated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, //_agreementId
        bytes calldata _agreementData,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        require(1 == 2);
        _handleSuperfluidCallback(_superToken, _agreementData, _ctx);
        newCtx = _ctx;
    }

    function afterAgreementUpdated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, // _agreementId,
        bytes calldata _agreementData,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        _handleSuperfluidCallback(_superToken, _agreementData, _ctx);
        newCtx = _ctx;
    }

    function afterAgreementTerminated(
        ISuperToken _superToken,
        address, //_agreementClass,
        bytes32, // _agreementId,
        bytes calldata _agreementData,
        bytes calldata ,//_cbdata,
        bytes calldata _ctx
    ) external override onlyHost returns (bytes memory newCtx) {
        _handleSuperfluidCallback(_superToken, _agreementData, _ctx);
        newCtx = _ctx;
    }

    modifier onlyHost() {
        require(
            msg.sender == address(cfaV1.host),
            "RedirectAll: support only one host"
        );
        _;
    }
}
