// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "src/Common.sol";
import {AAVEV3LoopingStrategy} from "src/AAVEV3LoopingStrategy.sol";
import {IPool} from "lib/aave-v3-core/contracts/interfaces/IPool.sol";
import {IAToken} from "lib/aave-v3-core/contracts/interfaces/IAToken.sol";
import {VariableDebtToken} from "lib/aave-v3-core/contracts/protocol/tokenization/VariableDebtToken.sol";
import {IWETH} from "test/interface/external/ethereum/IWETH.sol";
import {IwstETH} from "test/interface/external/lido/IwstETH.sol";
import {IStETH} from "test/interface/external/lido/IStETH.sol";

/**
 * @title AAVEV3LoopingStrategyTest
 * @notice Unit tests for the AAVEV3LoopingStrategy contract
 */
contract AAVEV3LoopingStrategyTest is Test {
    // Constants
    address constant LIDO_REFERRAL = 0x00000000000000000000000000000000000cE10d;
    uint256 constant FORK_BLOCK = 19300000; // Mainnet block
    
    // Mainnet addresses
    address constant AAVE_POOL = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant WST_ETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant ST_ETH = 0xae7ab96520DE3A18E5e111B5EaAb095312D7fE84;
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    
    // Reference to contracts
    AAVEV3LoopingStrategy public strategy;
    IPool public aavePool;
    IAToken public aWstETH;
    VariableDebtToken public vDebtWETH;
    IWETH public weth;
    IwstETH public wstEth;
    IWETH public stEth;
    
    // Test addresses
    address public alice = makeAddr("alice");
    address public admin = makeAddr("admin");
    address public allocator = makeAddr("allocator");
    
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
        stEth = IWETH(ST_ETH);
        
        // Get Aave aToken for wstETH and debt token for WETH
        aWstETH = IAToken(aavePool.getReserveData(WST_ETH).aTokenAddress);
        vDebtWETH = VariableDebtToken(aavePool.getReserveData(WETH).variableDebtTokenAddress);
        
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
        
        // Fund alice with ETH
        vm.deal(alice, 100 ether);
        
        // Convert some of alice's ETH to wstETH
        vm.startPrank(alice);
        // First convert ETH to stETH
        (bool success, ) = ST_ETH.call{value: 50 ether}(abi.encodeWithSignature("submit(address)", LIDO_REFERRAL));
        require(success, "ETH to stETH conversion failed");
        
        // Then convert stETH to wstETH
        stEth.approve(WST_ETH, 50 ether);
        wstEth.wrap(40 ether);
        
        // Convert some ETH to WETH
        weth.deposit{value: 30 ether}();
        vm.stopPrank();
    }
    
    function test_deploymentParameters() public {
        assertEq(address(strategy.aavePool()), AAVE_POOL, "Incorrect Aave pool");
        assertEq(address(strategy.collateralAsset()), WST_ETH, "Incorrect collateral asset");
        assertEq(address(strategy.aToken()), address(aWstETH), "Incorrect aToken");
        assertEq(address(strategy.debtAsset()), WETH, "Incorrect debt asset");
        assertEq(address(strategy.variableDebtToken()), address(vDebtWETH), "Incorrect variableDebtToken");
        assertEq(strategy.maxCollateralRatio(), MAX_RATIO, "Incorrect max ratio");
        assertEq(strategy.minCollateralRatio(), MIN_RATIO, "Incorrect min ratio");
        assertEq(strategy.targetCollateralRatio(), TARGET_RATIO, "Incorrect target ratio");
        assertEq(strategy.feePercentage(), FEE_PERCENTAGE, "Incorrect fee percentage");
    }
    
    function test_initialDeposit() public {
        uint256 initialAmount = 10 ether;
        
        // Approve and deposit
        vm.startPrank(alice);
        wstEth.approve(address(strategy), initialAmount);
        
        // Initial balance check
        uint256 aliceBalanceBefore = wstEth.balanceOf(alice);
        uint256 strategyBalanceBefore = aWstETH.balanceOf(address(strategy));
        
        // Do the initial deposit
        vm.expectRevert(); // Should revert because alice doesn't have allocator role
        strategy.depositAndLoop(initialAmount);
        vm.stopPrank();
        
        // Deposit as allocator
        vm.startPrank(allocator);
        vm.expectRevert(); // Should revert because allocator doesn't have the tokens
        strategy.depositAndLoop(initialAmount);
        vm.stopPrank();
        
        // Transfer tokens to allocator and deposit
        vm.startPrank(alice);
        wstEth.transfer(allocator, initialAmount);
        vm.stopPrank();
        
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialAmount);
        strategy.depositAndLoop(initialAmount);
        vm.stopPrank();
        
        // Check balances after deposit
        uint256 aTokenBalance = aWstETH.balanceOf(address(strategy));
        assertGt(aTokenBalance, strategyBalanceBefore, "aToken balance should increase");
        
        // Check that we borrowed ETH and redeposited
        uint256 debtBalance = vDebtWETH.balanceOf(address(strategy));
        assertGt(debtBalance, 0, "Should have debt balance after looping");
        
        // Calculate expected debt based on target ratio
        uint256 collateralInETH = aTokenBalance; // Simplification for test
        uint256 expectedDebtTarget = (collateralInETH * TARGET_RATIO) / 1e18;
        
        // Should be close to target debt (not exact due to slippage simulation)
        assertApproxEqRel(debtBalance, expectedDebtTarget, 0.05e18, "Debt should be close to target ratio");
    }
    
    function test_rebalance() public {
        // First do an initial deposit
        uint256 initialAmount = 10 ether;
        
        // Transfer tokens to allocator and deposit
        vm.startPrank(alice);
        wstEth.transfer(allocator, initialAmount);
        vm.stopPrank();
        
        // Deposit as allocator
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialAmount);
        strategy.depositAndLoop(initialAmount);
        
        // Record initial state
        uint256 initialDebt = vDebtWETH.balanceOf(address(strategy));
        uint256 initialCollateral = aWstETH.balanceOf(address(strategy));
        
        // Simulate price change that would increase collateral ratio (debt/collateral)
        // This would trigger leveraging more in rebalance
        vm.mockCall(
            AAVE_POOL,
            abi.encodeWithSelector(IPool.getUserAccountData.selector, address(strategy)),
            abi.encode(initialCollateral, (initialDebt * 9) / 10, 0, 0, 0, 2e18) // Decrease debt value by 10%
        );
        
        // Rebalance
        strategy.rebalance();
        
        // Debt should increase after rebalancing if ratio was below target
        uint256 newDebt = vDebtWETH.balanceOf(address(strategy));
        assertGt(newDebt, initialDebt, "Debt should increase after rebalancing");
        
        // Reset mock
        vm.clearMockedCalls();
        
        // Now simulate price change that would decrease collateral ratio
        // This would trigger deleveraging in rebalance
        vm.mockCall(
            AAVE_POOL,
            abi.encodeWithSelector(IPool.getUserAccountData.selector, address(strategy)),
            abi.encode(initialCollateral, initialDebt * 1.1, 0, 0, 0, 1.5e18) // Increase debt value by 10%
        );
        
        // Rebalance
        strategy.rebalance();
        
        // Debt should decrease after rebalancing if ratio was above target
        uint256 finalDebt = vDebtWETH.balanceOf(address(strategy));
        assertLt(finalDebt, newDebt, "Debt should decrease after rebalancing");
        
        vm.stopPrank();
    }
    
    function test_withdraw() public {
        // First do an initial deposit
        uint256 initialAmount = 10 ether;
        
        // Transfer tokens to allocator and deposit
        vm.startPrank(alice);
        wstEth.transfer(allocator, initialAmount);
        vm.stopPrank();
        
        // Deposit as allocator
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialAmount);
        strategy.depositAndLoop(initialAmount);
        
        // Mint strategy shares directly to alice (simplification for test)
        vm.stopPrank();
        vm.startPrank(admin);
        strategy.setHasAllocator(false); // Temporarily disable allocator requirement for testing
        vm.stopPrank();
        
        vm.prank(address(strategy));
        strategy.mint(initialAmount, alice);
        
        // Check alice's shares
        uint256 aliceShares = strategy.balanceOf(alice);
        assertEq(aliceShares, initialAmount, "Alice should have strategy shares");
        
        // Calculate how much alice can withdraw
        vm.prank(alice);
        uint256 maxWithdrawAmount = strategy.maxWithdraw(alice);
        assertGt(maxWithdrawAmount, 0, "Alice should be able to withdraw");
        
        // Withdraw half the max amount
        uint256 withdrawAmount = maxWithdrawAmount / 2;
        
        // Set allocator requirement back
        vm.prank(admin);
        strategy.setHasAllocator(true);
        
        // Try to withdraw directly (should fail due to allocator check)
        vm.prank(alice);
        vm.expectRevert();
        strategy.withdraw(withdrawAmount, alice, alice);
        
        // Withdraw through allocator
        vm.prank(allocator);
        uint256 sharesRedeemed = strategy.withdraw(withdrawAmount, alice, alice);
        
        // Verify alice received the tokens
        assertGt(wstEth.balanceOf(alice), 0, "Alice should have received wstETH tokens");
        assertGt(sharesRedeemed, 0, "Shares should have been redeemed");
        assertEq(strategy.balanceOf(alice), aliceShares - sharesRedeemed, "Alice's shares should have decreased");
    }
    
    function test_emergencyExit() public {
        // First do an initial deposit
        uint256 initialAmount = 10 ether;
        
        // Transfer tokens to allocator and deposit
        vm.startPrank(alice);
        wstEth.transfer(allocator, initialAmount);
        vm.stopPrank();
        
        // Deposit as allocator
        vm.startPrank(allocator);
        wstEth.approve(address(strategy), initialAmount);
        strategy.depositAndLoop(initialAmount);
        vm.stopPrank();
        
        // Verify we have debt and collateral
        uint256 initialDebt = vDebtWETH.balanceOf(address(strategy));
        uint256 initialCollateral = aWstETH.balanceOf(address(strategy));
        assertGt(initialDebt, 0, "Should have debt before emergency exit");
        assertGt(initialCollateral, 0, "Should have collateral before emergency exit");
        
        // Try to call emergency exit with non-admin (should fail)
        vm.prank(alice);
        vm.expectRevert();
        strategy.emergencyExit();
        
        // Call emergency exit with admin
        vm.prank(admin);
        strategy.emergencyExit();
        
        // Check that emergency flag is set
        assertTrue(strategy.emergencyExitActivated(), "Emergency exit flag should be set");
        
        // Check that we've unwound positions
        uint256 finalDebt = vDebtWETH.balanceOf(address(strategy));
        uint256 finalCollateral = aWstETH.balanceOf(address(strategy));
        assertLt(finalDebt, initialDebt, "Debt should decrease after emergency exit");
        assertLt(finalCollateral, initialCollateral, "Aave collateral should decrease after emergency exit");
        
        // Verify we have some wstETH in the contract
        uint256 wstEthBalance = wstEth.balanceOf(address(strategy));
        assertGt(wstEthBalance, 0, "Should have wstETH after emergency exit");
    }
    
    function test_getTokenValueInETH() public {
        // Mock the user account data
        uint256 collateralValue = 100 ether;
        uint256 debtValue = 70 ether;
        vm.mockCall(
            AAVE_POOL,
            abi.encodeWithSelector(IPool.getUserAccountData.selector, address(strategy)),
            abi.encode(collateralValue, debtValue, 0, 0, 0, 1.5e18)
        );
        
        // Check totalAssets() which should return the difference
        uint256 tokenValue = strategy.totalAssets();
        assertEq(tokenValue, collateralValue - debtValue, "Token value should be collateral minus debt");
    }
    
    function test_feeCalculation() public {
        uint256 amount = 1000 ether;
        
        // Test fee on raw amount
        uint256 feeRaw = strategy._feeOnRaw(amount);
        uint256 expectedFeeRaw = (amount * FEE_PERCENTAGE) / 10000;
        assertEq(feeRaw, expectedFeeRaw, "Fee on raw calculation incorrect");
        
        // Test fee on total amount
        uint256 feeTotal = strategy._feeOnTotal(amount);
        uint256 expectedFeeTotal = (amount * FEE_PERCENTAGE) / 10000;
        assertEq(feeTotal, expectedFeeTotal, "Fee on total calculation incorrect");
    }
    
    function test_rescueTokens() public {
        // Let's fund the strategy with some WETH directly (not through Aave)
        uint256 rescueAmount = 1 ether;
        vm.startPrank(alice);
        weth.transfer(address(strategy), rescueAmount);
        vm.stopPrank();
        
        // Make sure we can't rescue protocol tokens
        vm.startPrank(admin);
        vm.expectRevert();
        strategy.rescueTokens(WST_ETH, admin, 1);
        
        vm.expectRevert();
        strategy.rescueTokens(WETH, admin, 1);
        
        // But we can rescue other tokens
        address randomToken = makeAddr("randomToken");
        strategy.rescueTokens(randomToken, admin, 1); // Should not revert
        
        // After emergency exit, we should be able to rescue protocol tokens
        strategy.emergencyExit();
        strategy.rescueTokens(WETH, admin, rescueAmount);
        assertEq(weth.balanceOf(admin), rescueAmount, "Admin should receive rescued tokens");
        vm.stopPrank();
    }
    
    function test_updateParameters() public {
        // Test updating fee percentage
        uint256 newFee = 100; // 1%
        vm.prank(admin);
        strategy.setFeePercentage(newFee);
        assertEq(strategy.feePercentage(), newFee, "Fee percentage not updated");
        
        // Test updating collateral ratios
        uint256 newMax = 80 * 1e16; // 80%
        uint256 newTarget = 78 * 1e16; // 78%
        uint256 newMin = 75 * 1e16; // 75%
        
        vm.prank(admin);
        strategy.setCollateralRatioParams(newMax, newMin, newTarget);
        assertEq(strategy.maxCollateralRatio(), newMax, "Max ratio not updated");
        assertEq(strategy.minCollateralRatio(), newMin, "Min ratio not updated");
        assertEq(strategy.targetCollateralRatio(), newTarget, "Target ratio not updated");
        
        // Test invalid ratio ordering
        vm.expectRevert();
        vm.prank(admin);
        strategy.setCollateralRatioParams(newMin, newMax, newTarget); // Min > Max, should fail
    }
}