// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Test, console} from "../../lib/forge-std/src/Test.sol";
import {ERC20Mock} from "../../lib/openzeppelin-contracts/contracts/mocks/token/ERC20Mock.sol";
import {MockV3Aggregator} from "../mocks/MockV3Aggregator.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address weth;
    address ethUsdPriceFeed;
    address btcUsdPriceFeed;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed,, weth,,) = config.activeNetworkConfig();

        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }
    ///////////////////////
    // Constructor Tests //
    ///////////////////////

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPriceFeed);

        vm.expectRevert(DSCEngine.DSCEngine__TokenAddressesAndPriceFeedAddressesAmountsDontMatch.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    /////////////////
    // Price Tests //
    /////////////////
    function testGetUsdValue() public {
        // 15e18 * 2,000/ETH = 30,000e18
        uint256 ethAmount = 15e18;
        uint256 expectedUsd = 30000e18;
        uint256 actualUsd = dsce.getUsdValue(weth, ethAmount);
        assertEq(expectedUsd, actualUsd);
    }

    function testGetTokenAmountFromUsd() public {
        uint256 usdAmount = 100 ether;
        uint256 expectedWeth = 0.05 ether;
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        assertEq(expectedWeth, actualWeth);
    }

    function testLiquidate() public depositedCollateral {
        // USER deposits 10 ETH ($20,000) and mints $5,000 DSC
        vm.prank(USER);
        dsce.mintDsc(5_000 ether);

        // Crash ETH to $750
        MockV3Aggregator(ethUsdPriceFeed).updateAnswer(750e8);

        // Fund liquidator with DSC
        address liquidator = makeAddr("liquidator");
        vm.prank(USER);
        dsc.transfer(liquidator, 5_000 ether);

        // Record liquidator's wETH balance before
        uint256 liquidatorWethBefore = ERC20Mock(weth).balanceOf(liquidator);

        // Liquidate
        vm.startPrank(liquidator);
        dsc.approve(address(dsce), 5_000 ether);
        dsce.liquidate(weth, USER, 5_000 ether);
        vm.stopPrank();

        // Assertions
        assertEq(dsc.balanceOf(USER), 0);
        assertEq(dsce.getHealthFactor(USER), type(uint256).max);
        assertGt(ERC20Mock(weth).balanceOf(liquidator), liquidatorWethBefore);
    }

    /////////////////////////////
    // depositCollateral Tests //
    /////////////////////////////

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testDepositCollateral() public depositedCollateral {
        // User's balance should decrease
        assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL);

        // DSCEngine's balance should increase
        assertEq(ERC20Mock(weth).balanceOf(address(dsce)), AMOUNT_COLLATERAL);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);

        vm.expectRevert(DSCEngine.DSCEngine__NeedsMoreThanZero.selector);
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    ////////////////////////
    // HealthFactor Tests //
    ////////////////////////

    function testRedeemCollateralRevertsIfItBreaksHealthFactor() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(5_000 ether);

        // Before redemption:
        // 10 WETH = $20,000 collateral
        // Threshold-adjusted collateral = $10,000
        // Debt = $5,000
        // HF = 2e18

        uint256 expectedEndingHealthFactor = 0.8e18;

        vm.expectRevert(
            abi.encodeWithSelector(DSCEngine.DSCEngine__BreaksHealthFactor.selector, expectedEndingHealthFactor)
        );

        vm.prank(USER);
        dsce.redeemCollateral(weth, 6 ether);

        // The failed redemption must roll back completely.
        assertEq(ERC20Mock(weth).balanceOf(address(dsce)), AMOUNT_COLLATERAL);

        assertEq(ERC20Mock(weth).balanceOf(USER), STARTING_ERC20_BALANCE - AMOUNT_COLLATERAL);

        assertEq(dsce.getHealthFactor(USER), 2e18);
    }

    function testHealthFactorRevertsWithNoDebt() public {
        // USER has deposited collateral but has NOT minted any DSC
        vm.prank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        vm.prank(USER);
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);

        // s_DSCMinted[USER] == 0

        // This should return max uint (infinitely healthy)
        // But it will revert with division by zero (now fixed in dsce line 285)
        dsce.getHealthFactor(USER);
    }

    function testGetHealthFactorRevertsIfNoDebt() public {
        // hf = healthfactor
        // After the fix, this should NOT revert — it should return max uint
        uint256 hf = dsce.getHealthFactor(USER);
        assertEq(hf, type(uint256).max);
    }

    function testMintDscRevertsIfBreaksHealthFactor() public depositedCollateral {
        // USER has $20,000 collateral. Adjusted is $10,000.
        // Minting $11,000 DSC would push health factor below 1.
        vm.prank(USER);
        vm.expectRevert(); // We expect this to revert
        dsce.mintDsc(11000 ether);
    }

    function testBurnDsc() public depositedCollateral {
        vm.startPrank(USER);
        dsce.mintDsc(5000 ether);

        // Approve the engine to pull the DSC back
        dsc.approve(address(dsce), 5000 ether);

        // Burn it all. Before the fix, this would revert with divide-by-zero.
        dsce.burnDsc(5000 ether);
        vm.stopPrank();

        // User should have 0 DSC
        assertEq(dsc.balanceOf(USER), 0);

        // Health factor should be max now
        assertEq(dsce.getHealthFactor(USER), type(uint256).max);
    }

    function testMintDsc() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(5000 ether);

        // User should have received 5000 DSC
        assertEq(dsc.balanceOf(USER), 5000 ether);
    }

    function testLiquidateRevertsIfHealthFactorOkay() public depositedCollateral {
        vm.prank(USER);
        dsce.mintDsc(1_000 ether);

        vm.expectRevert(DSCEngine.DSCEngine__HealthFactorOk.selector);

        address liquidator = makeAddr("liquidator");
        dsce.liquidate(weth, USER, 500 ether);

        assertEq(dsc.balanceOf(USER), 1_000 ether);
    }
}
