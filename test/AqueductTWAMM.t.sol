pragma solidity ^0.8.15;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {GasSnapshot} from "forge-gas-snapshot/GasSnapshot.sol";
import {TestERC20} from "@uniswap/v4-core/contracts/test/TestERC20.sol";
import {IERC20Minimal} from "@uniswap/v4-core/contracts/interfaces/external/IERC20Minimal.sol";
import {AqueductTWAMMImplementation} from "./shared/implementation/AqueductTWAMMImplementation.sol";
import {IHooks} from "@uniswap/v4-core/contracts/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/contracts/libraries/Hooks.sol";
import {TickMath} from "@uniswap/v4-core/contracts/libraries/TickMath.sol";
import {PoolManager} from "@uniswap/v4-core/contracts/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/contracts/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/contracts/libraries/PoolId.sol";
import {PoolModifyPositionTest} from "@uniswap/v4-core/contracts/test/PoolModifyPositionTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/contracts/test/PoolSwapTest.sol";
import {PoolDonateTest} from "@uniswap/v4-core/contracts/test/PoolDonateTest.sol";
import {Deployers} from "@uniswap/v4-core/test/foundry-tests/utils/Deployers.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/contracts/libraries/CurrencyLibrary.sol";
import {AqueductTWAMM} from "../contracts/hooks/examples/AqueductTWAMM.sol";
import {IAqueductTWAMM} from "../contracts/interfaces/IAqueductTWAMM.sol";
import {ISuperfluid} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {
    SuperfluidFrameworkDeployer,
    Superfluid,
    CFAv1Library,
    SuperTokenFactory
} from "@superfluid-finance/ethereum-contracts/contracts/utils/SuperfluidFrameworkDeployer.sol";
import {ISuperToken} from "@superfluid-finance/ethereum-contracts/contracts/interfaces/superfluid/ISuperfluid.sol";
import {TestGovernance} from "@superfluid-finance/ethereum-contracts/contracts/utils/TestGovernance.sol";
import {ConstantFlowAgreementV1} from "@superfluid-finance/ethereum-contracts/contracts/agreements/ConstantFlowAgreementV1.sol";
import {TestToken} from "@superfluid-finance/ethereum-contracts/contracts/utils/TestToken.sol";
import {ERC1820RegistryCompiled} from "@superfluid-finance/ethereum-contracts/contracts/libs/ERC1820RegistryCompiled.sol";
import {SuperTokenV1Library} from "@superfluid-finance/ethereum-contracts/contracts/apps/SuperTokenV1Library.sol";

contract AqueductTWAMMTest is Test, Deployers, GasSnapshot {
    using PoolId for IPoolManager.PoolKey;
    using CurrencyLibrary for Currency;
    using SuperTokenV1Library for ISuperToken;

    event SubmitOrder(
        bytes32 indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    event UpdateOrder(
        bytes32 indexed poolId,
        address indexed owner,
        uint160 expiration,
        bool zeroForOne,
        uint256 sellRate,
        uint256 earningsFactorLast
    );

    // address constant TWAMMAddr = address(uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG));
    AqueductTWAMM twamm = AqueductTWAMM(
        address(uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_MODIFY_POSITION_FLAG))
    );
    // TWAMM twamm;
    PoolManager manager;
    PoolModifyPositionTest modifyPositionRouter;
    PoolSwapTest swapRouter;
    PoolDonateTest donateRouter;
    address hookAddress;
    //TestERC20 token0;
    //TestERC20 token1;
    IPoolManager.PoolKey poolKey;
    bytes32 poolId;

    // Superfluid
    struct Framework {
        TestGovernance governance;
        Superfluid host;
        ConstantFlowAgreementV1 cfa;
        CFAv1Library.InitData cfaLib;
        SuperTokenFactory superTokenFactory;
    }
    SuperfluidFrameworkDeployer.Framework sf;
    TestToken public dai;
    ISuperToken public daix;
    TestToken public usdc;
    ISuperToken public usdcx;

    function setUp() public {
        //token0 = new TestERC20(2**128);
        //token1 = new TestERC20(2**128);
        manager = new PoolManager(500000);

        // deploy superfluid and test supertokens
        vm.etch(ERC1820RegistryCompiled.at, ERC1820RegistryCompiled.bin);
        SuperfluidFrameworkDeployer sfDeployer = new SuperfluidFrameworkDeployer();
        sfDeployer.deployTestFramework();
        sf = sfDeployer.getFramework();
        (, daix) = sfDeployer.deployWrapperSuperToken("Fake DAI", "DAI", 18, 1000 ether);
        (, usdcx) = sfDeployer.deployWrapperSuperToken("Fake USDC", "USDC", 18, 1000 ether);
        dai = TestToken(daix.getUnderlyingToken());
        usdc = TestToken(usdcx.getUnderlyingToken());

        AqueductTWAMMImplementation impl = new AqueductTWAMMImplementation(manager, sf.host, twamm);
        (, bytes32[] memory writes) = vm.accesses(address(impl));
        vm.etch(address(twamm), address(impl).code);
        // for each storage key that was written during the hook implementation, copy the value over
        unchecked {
            for (uint256 i = 0; i < writes.length; i++) {
                bytes32 slot = writes[i];
                vm.store(address(twamm), slot, vm.load(address(impl), slot));
            }
        }
        
        modifyPositionRouter = new PoolModifyPositionTest(IPoolManager(address(manager)));
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));

        poolKey = IPoolManager.PoolKey(Currency.wrap(address(daix)), Currency.wrap(address(usdcx)), 3000, 60, twamm);
        poolId = PoolId.toId(poolKey);
        manager.initialize(poolKey, SQRT_RATIO_1_1);

        daix.approve(address(modifyPositionRouter), 100 ether);
        usdcx.approve(address(modifyPositionRouter), 100 ether);
        dai.mint(address(this), 100 ether);
        dai.approve(address(daix), 100 ether);
        daix.upgrade(100 ether);
        usdc.mint(address(this), 100 ether);
        usdc.approve(address(usdcx), 100 ether);
        usdcx.upgrade(100 ether);
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-60, 60, 10 ether));
        modifyPositionRouter.modifyPosition(poolKey, IPoolManager.ModifyPositionParams(-120, 120, 10 ether));
        modifyPositionRouter.modifyPosition(
            poolKey, IPoolManager.ModifyPositionParams(TickMath.minUsableTick(60), TickMath.maxUsableTick(60), 10 ether)
        );
    }

    function testTWAMMEndToEndSimSymmetricalOrderPools() public {
        // create the order with a ~~superfluid stream~~
        IAqueductTWAMM.OrderKey memory orderKey1 = IAqueductTWAMM.OrderKey(address(this), true);
        daix.createFlow(address(twamm), 10000000000);
        
    }
}
