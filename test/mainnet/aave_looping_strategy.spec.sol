// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "src/Common.sol";
import {AAVEV3LoopingStrategy} from "src/AAVEV3LoopingStrategy.sol";
import {IPool} from "lib/aave-v3-core/contracts/interfaces/IPool.sol";
import {IAToken} from "lib/aave-v3-core/contracts/interfaces/IAToken.sol";
import {IVariableDebtToken} from "lib/aave-v3-core/contracts/interfaces/IVariableDebtToken.sol";
import {IWETH} from "test/interface/external/ethereum/IWETH.sol";
import {IwstETH} from "test/interface/external/lido/IwstETH.sol";
import {IStETH} from "test/interface/external/lido/IStETH.sol";

/**
 * @title AAVEV3LoopingStrategyForkTest
 * @notice Mainnet fork tests for the AAVEV3LoopingStrategy contract
 * @dev These tests use a fork of Ethereum mainnet to test in a realistic environment
 */
contract AAVEV3LoopingStrategyForkTest is Test {
    // Constants
    address constant LIDO_REFERRAL = 0x00000000000000000000000000000000000cE10d;
    uint256 constant FORK_BLOCK = 19300000; // Mainnet block
    
    // Mainnet addresses
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Curve ST-ETH/ETH pool for price data and swap simulation
    address constant CURVE_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;
    
    // Reference to contracts
    AAVEV3LoopingStrategy public strategy;
    IPool public aavePool;
    IAToken public aWstETH;
    IVariableDebtToken public vDebtWETH;
    IWETH public weth;
    IwstETH public wstEth;
    IStETH public stEth;
    
    // Test addresses
    address public whale = makeAddr("whale");
    address public admin = makeAddr("admin");
    address public allocator = makeAddr("allocator");
    address public user = makeAddr("user");
    
    // Strategy parameters
    uint256 public constant MAX_RATIO = 75 * 1e16; // 75%
    uint256 public constant MIN_RATIO = 70 * 1e16; // 70%
    uint256 public constant TARGET_RATIO = 72 * 1e16; // 72%
    uint256 public constant FEE_PERCENTAGE = 50; // 0.5%
    
    function setUp() public {
        // Fork mainnet
        vm.createSelectFork(vm.rpcUrl("mainnet"), FORK_BLOCK);
        
        // Initialize contract references
        aavePool = IPool(AAVE_POOL);
        weth = IWETH(WETH);
        wstEth = IwstETH(WST_ETH);
        stEth = IStETH(ST_ETH);
        
        // Get Aave aToken for wstETH and debt token for WETH
        aWstETH = IAToken(aavePool.getReserveData(WST_ETH).aTokenAddress);
        vDebtWETH = IVariableDebtToken(aavePool.getReserveData(WETH).variableDebtTokenAddress);
        
        // Deploy strategy
        vm.startPrank(admin);
        strategy = new AAVEV3LoopingStrategy(
            AAVE_POOL,
            WST_ETH,
            address(aWstETH),
            WETH,
            address(vDebtWETH),
            MAX_RATIO,
            MIN_RATIO,
            TARGET_RATIO,
            FEE_PERCENTAGE
        );
        
        // Setup roles
        strategy.grantRole(strategy.DEFAULT_ADMIN_ROLE(), admin);
        strategy.grantRole(strategy.ALLOCATOR_ROLE(), allocator);
        strategy.grantRole(strategy.ASSET_MANAGER_ROLE(), admin);
        vm.stopPrank();
        
        // Fund whale with ETH
        vm.deal(whale, 1000 ether);
        
        // Convert some of whale's ETH to wstETH and WETH
        vm.startPrank(whale);
        
        // Convert ETH to stETH then to wstETH
        (bool success, ) = ST_ETH.call{value: 500 ether}(abi.encodeWithSignature("submit(address)", LIDO_REFERRAL));
        require(success, "ETH to stETH conversion failed");
        
        stEth.approve(WST_ETH, 500 ether);
        wstEth.wrap(400 ether);
        
        // Convert some ETH to WETH
        weth.deposit{value: 300 ether}();
        
        // Transfer funds to allocator for strategy use
        wstEth.transfer(allocator, 100 ether);
        
        // Setup swap function for DEX simulation
        weth.approve(address(this), type(uint256).max);
        wstEth.approve(address(this), type(uint256).max);
        
        vm.stopPrank();
        
        // Setup user for testing
        vm.deal(user, 50 ether);
        vm.startPrank(user);
        (success, ) = ST_ETH.call{value: 40 ether}(abi.encodeWithSignature("submit(address)", LIDO_REFERRAL));
        require(success, "ETH to stETH conversion failed");
        stEth.approve(WST_ETH, 40 ether);
        wstEth.wrap(30 ether);
        vm.stopPrank();
    }
    
    // Helper function to simulate swapping WETH to wstETH through Curve
    function _simulateSwap_WETHToWstETH(uint256 wethAmount) internal returns (uint256) {
        // This is a simplified simulation
        // In a real app, you'd use an actual DEX
        
        // Get wstETH price in ETH via stETH
        uint256 stEthPerEth = wstEth.stEthPerToken();
        uint256 wstEthAmount = (wethAmount * 99) / 100; // 1% slippage
        
        // Transfer the WETH from whale to simulate a swap
        vm.startPrank(whale);
        wstEth.transfer(address(this), wstEthAmount);
        vm.stopPrank();
        
        return wstEthAmount;
    }
    
    // Helper function to simulate swapping wstETH to WETH through Curve
    function _simulateSwap_wstETHToWETH(uint256 wstEthAmount) internal returns (uint256) {
        // This is a simplified simulation
        // In a real app, you'd use an actual DEX
        
        // Calculate approximate WETH amount
        uint256 wethAmount = (wstEthAmount * 99) / 100; // 1% slippage
        
        // Transfer the WETH from whale to simulate a swap
        vm.startPrank(whale);
        weth.transfer(address(this), wethAmount);
        vm.stopPrank();
        
        return wethAmount;
    }
    
    function test_endToEndFlow() public {
        // Initial amounts
        uint256 initialDeposit = 50 ether;
        
        // === PART 1: Initial Deposit and Looping ===
        
        console2.log("=== PART 1: Initial Deposit and Looping ===");
        
        // Prepare allocator with wstETH
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialDeposit);
        
        // Log initial state
        console2.log("Initial wstETH balance:", wstEth.balanceOf(allocator) / 1e18);
        
        // Deposit and loop
        strategy.depositAndLoop(initialDeposit);
        
        // Log post-deposit state
        console2.log("Post-deposit wstETH in Aave:", aWstETH.balanceOf(address(strategy)) / 1e18);
        console2.log("WETH debt:", vDebtWETH.balanceOf(address(strategy)) / 1e18);
        
        // Calculate health factor and collateral ratio
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , uint256 healthFactor) = 
            aavePool.getUserAccountData(address(strategy));
        
        console2.log("Total collateral (ETH):", totalCollateralETH / 1e18);
        console2.log("Total debt (ETH):", totalDebtETH / 1e18);
        console2.log("Health factor:", healthFactor / 1e18);
        console2.log("Collateral ratio:", (totalDebtETH * 100) / totalCollateralETH, "%");
        
        // Mint shares to the user for testing
        strategy.setHasAllocator(false); // Temporarily disable allocator requirement
        vm.stopPrank();
        
        // Mint strategy shares to the user
        vm.startPrank(user);
        wstEth.approve(address(strategy), 10 ether);
        uint256 shares = strategy.deposit(10 ether, user);
        console2.log("User deposited wstETH and received shares:", shares / 1e18);
        
        // Track the token value in ETH
        uint256 tokenValueInETH = strategy.totalAssets();
        console2.log("Strategy token value in ETH:", tokenValueInETH / 1e18);
        
        // === PART 2: Rebalancing ===
        
        console2.log("\n=== PART 2: Rebalancing ===");
        
        // Test rebalancing - simulate a price change by directly manipulating Aave position
        // In reality, this would happen due to market movements
        
        // Re-enable allocator requirement
        vm.startPrank(admin);
        strategy.setHasAllocator(true);
        vm.stopPrank();
        
        vm.startPrank(allocator);
        
        // Add more collateral to simulate deleveraging need
        wstEth.transfer(address(strategy), 5 ether);
        wstEth.approve(address(aWstETH), 5 ether);
        aWstETH.mint(address(strategy), 5 ether, 0);
        
        // Rebalance should detect over-collateralization and borrow more
        strategy.rebalance();
        
        // Log post-rebalance state
        (totalCollateralETH, totalDebtETH, , , , healthFactor) = 
            aavePool.getUserAccountData(address(strategy));
        
        console2.log("Total collateral after rebalance (ETH):", totalCollateralETH / 1e18);
        console2.log("Total debt after rebalance (ETH):", totalDebtETH / 1e18);
        console2.log("Health factor after rebalance:", healthFactor / 1e18);
        console2.log("Collateral ratio after rebalance:", (totalDebtETH * 100) / totalCollateralETH, "%");
        
        // Now simulate a need to deleverage
        // First, set up a temp function to modify debt
        vm.mockCall(
            address(vDebtWETH),
            abi.encodeWithSelector(vDebtWETH.balanceOf.selector, address(strategy)),
            abi.encode(vDebtWETH.balanceOf(address(strategy)) * 1.2) // Increase debt by 20%
        );
        
        // Rebalance should detect over-leverage and deleverage
        strategy.rebalance();
        vm.clearMockedCalls();
        
        // Log post-deleveraging state
        (totalCollateralETH, totalDebtETH, , , , healthFactor) = 
            aavePool.getUserAccountData(address(strategy));
        
        console2.log("Total collateral after deleveraging (ETH):", totalCollateralETH / 1e18);
        console2.log("Total debt after deleveraging (ETH):", totalDebtETH / 1e18);
        console2.log("Health factor after deleveraging:", healthFactor / 1e18);
        console2.log("Collateral ratio after deleveraging:", (totalDebtETH * 100) / totalCollateralETH, "%");
        
        // === PART 3: User Withdrawal ===
        
        console2.log("\n=== PART 3: User Withdrawal ===");
        
        // Get user's share balance
        uint256 userShares = strategy.balanceOf(user);
        console2.log("User shares before withdrawal:", userShares / 1e18);
        
        // Calculate max withdrawal
        uint256 maxWithdraw = strategy.maxWithdraw(user);
        console2.log("User max withdrawal amount:", maxWithdraw / 1e18);
        
        // User requests withdrawal of half their balance
        uint256 withdrawAmount = maxWithdraw / 2;
        
        // Do the withdrawal through allocator (since allocator check is enabled)
        uint256 userWstEthBefore = wstEth.balanceOf(user);
        strategy.withdraw(withdrawAmount, user, user);
        uint256 userWstEthAfter = wstEth.balanceOf(user);
        
        console2.log("User wstETH balance increase:", (userWstEthAfter - userWstEthBefore) / 1e18);
        console2.log("User shares after withdrawal:", strategy.balanceOf(user) / 1e18);
        
        // Log strategy state after withdrawal
        (totalCollateralETH, totalDebtETH, , , , healthFactor) = 
            aavePool.getUserAccountData(address(strategy));
        
        console2.log("Total collateral after withdrawal (ETH):", totalCollateralETH / 1e18);
        console2.log("Total debt after withdrawal (ETH):", totalDebtETH / 1e18);
        console2.log("Health factor after withdrawal:", healthFactor / 1e18);
        
        // === PART 4: Emergency Exit ===
        
        console2.log("\n=== PART 4: Emergency Exit ===");
        
        // Log pre-emergency state
        uint256 strategyWstEthBefore = wstEth.balanceOf(address(strategy));
        uint256 strategyATokenBefore = aWstETH.balanceOf(address(strategy));
        uint256 strategyDebtBefore = vDebtWETH.balanceOf(address(strategy));
        
        console2.log("Strategy direct wstETH before exit:", strategyWstEthBefore / 1e18);
        console2.log("Strategy aToken balance before exit:", strategyATokenBefore / 1e18);
        console2.log("Strategy debt before exit:", strategyDebtBefore / 1e18);
        
        // Admin triggers emergency exit
        vm.stopPrank();
        vm.prank(admin);
        strategy.emergencyExit();
        
        // Log post-emergency state
        uint256 strategyWstEthAfter = wstEth.balanceOf(address(strategy));
        uint256 strategyATokenAfter = aWstETH.balanceOf(address(strategy));
        uint256 strategyDebtAfter = vDebtWETH.balanceOf(address(strategy));
        
        console2.log("Strategy direct wstETH after exit:", strategyWstEthAfter / 1e18);
        console2.log("Strategy aToken balance after exit:", strategyATokenAfter / 1e18);
        console2.log("Strategy debt after exit:", strategyDebtAfter / 1e18);
        
        // Assertions to verify the emergency exit worked
        assertLt(strategyATokenAfter, strategyATokenBefore, "aToken balance should decrease");
        assertLt(strategyDebtAfter, strategyDebtBefore, "Debt should decrease");
        assertGt(strategyWstEthAfter, strategyWstEthBefore, "Direct wstETH balance should increase");
    }
    
    function test_strategyValueCalculation() public {
        // Initial deposit to the strategy
        uint256 initialDeposit = 20 ether;
        
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialDeposit);
        strategy.depositAndLoop(initialDeposit);
        vm.stopPrank();
        
        // Get strategy token value in ETH
        uint256 tokenValueInETH = strategy.totalAssets();
        
        // Get current position
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
            aavePool.getUserAccountData(address(strategy));
        
        // Check that token value equals collateral minus debt
        assertEq(tokenValueInETH, totalCollateralETH - totalDebtETH, "Token value should be collateral minus debt");
        
        // Log the strategy token value
        console2.log("Initial strategy token value in ETH:", tokenValueInETH / 1e18);
        
        // Simulate yield accrual by adding staking rewards
        // In real world, this would happen naturally through stETH appreciation
        vm.startPrank(whale);
        wstEth.transfer(address(aWstETH), 1 ether); // Simulate yield
        vm.stopPrank();
        
        // Get updated strategy token value
        uint256 newTokenValue = strategy.totalAssets();
        
        // Verify the token value increased
        assertGt(newTokenValue, tokenValueInETH, "Token value should increase with yield");
        
        console2.log("Updated strategy token value in ETH:", newTokenValue / 1e18);
        console2.log("Value increase:", (newTokenValue - tokenValueInETH) / 1e18);
    }
}