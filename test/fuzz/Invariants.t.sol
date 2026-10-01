// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Handler} from "./Handler.t.sol";

contract InvariantsTest is StdInvariant, Test {
    DeployDSC deployer;
    DSCEngine dsce;
    DecentralizedStableCoin dsc;
    HelperConfig config;
    address weth;
    address wbtc;
    Handler handler;

    function setUp() external {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (,, weth, wbtc,) = config.activeNetworkConfig();

        handler = new Handler(dsce, dsc);
        targetContract(address(handler));
    }

    function invariant_protocolMustHaveMoreValueThanTotalSupply() public view {
        uint256 totalSupply = dsc.totalSupply();
        uint256 totalWethDeposited = IERC20(weth).balanceOf(address(dsce));
        uint256 totalWbtcDeposited = IERC20(wbtc).balanceOf(address(dsce));

        uint256 wethValue = dsce.getUsdValue(weth, totalWethDeposited);
        uint256 wbtcValue = dsce.getUsdValue(wbtc, totalWbtcDeposited);

        console.log("totalSupply: ", totalSupply);
        console.log("wethValue: ", wethValue);
        console.log("wbtcValue: ", wbtcValue);
        console.log("Times Mint Called: ", handler.timesMintIsCalled());

        assert(wethValue + wbtcValue >= totalSupply);
    }

    // Invariants.t.sol
    function invariant_gettersMustNotRevert() public view {
        // 1. Per-user getters across every actor that ever deposited
        address[] memory users = handler.getUsersWithCollateralDeposited();
        for (uint256 i = 0; i < users.length; i++) {
            dsce.getHealthFactor(users[i]);
            dsce.getAccountCollateralValue(users[i]);
        }

        // 2. Also check a fresh address: no deposits, no debt
        dsce.getHealthFactor(address(0xdead));
        dsce.getAccountCollateralValue(address(0xdead));

        // 3. Token/USD conversions on allowed collateral only
        dsce.getUsdValue(weth, 1 ether);
        dsce.getUsdValue(wbtc, 1 ether);
        dsce.getTokenAmountFromUsd(weth, 100 ether);
        dsce.getTokenAmountFromUsd(wbtc, 100 ether);

        // 4. The DSC token's own surface
        dsc.totalSupply();
        dsc.balanceOf(address(dsce));
        dsc.decimals();
    }
}
