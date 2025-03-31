// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseStrategy} from "src/strategy/BaseStrategy.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "lib/openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPool} from "lib/aave-v3-core/contracts/interfaces/IPool.sol"; // Interface for AAVE V3 Pool
import {IAToken} from "lib/aave-v3-core/contracts/interfaces/IAToken.sol"; // Interface for AAVE aToken
import {VariableDebtToken} from "lib/aave-v3-core/contracts/protocol/tokenization/VariableDebtToken.sol";

contract AAVEV3LoopingStrategy is BaseStrategy {
    using SafeERC20 for IERC20;
    
    /// @notice Emitted when the strategy is rebalanced
    event Rebalanced(uint256 collateralAmount, uint256 debtAmount, uint256 timestamp);
    
    /// @notice Emitted when emergency exit is triggered
    event EmergencyExit(uint256 timestamp);
    
    /// @notice Emitted when collateral ratio parameters are updated
    event CollateralRatioUpdated(uint256 maxCollateralRatio, uint256 minCollateralRatio, uint256 targetCollateralRatio);

    /// @notice Interest rate type for variable rate
    uint256 public constant VARIABLE_RATE = 2;
    
    /// @notice Emergency exit flag
    bool public emergencyExitActivated;

    /// @notice The AAVE V3 Pool contract
    IPool public immutable aavePool;

    /// @notice The collateral asset (e.g., wstETH)
    IERC20 public immutable collateralAsset;
    
    /// @notice The aToken for the collateral asset
    IAToken public immutable aToken;
    
    /// @notice The debt asset (e.g., ETH)
    IERC20 public immutable debtAsset;
    
    /// @notice The variable debt token for the debt asset
    VariableDebtToken public immutable variableDebtToken;

    /// @notice The maximum collateralization ratio (e.g., 75% = 75 * 1e16)
    uint256 public maxCollateralRatio;

    /// @notice The minimum collateralization ratio for rebalancing (e.g., 70% = 70 * 1e16)
    uint256 public minCollateralRatio;
    
    /// @notice The target collateralization ratio after rebalancing (e.g., 72% = 72 * 1e16)
    uint256 public targetCollateralRatio;
    
    /// @notice The fee percentage for the strategy (in basis points, e.g., 100 = 1%)
    uint256 public feePercentage;

    /// @notice Constructor to initialize the strategy
    /// @param _aavePool The address of the AAVE V3 Pool contract
    /// @param _collateralAsset The address of the collateral asset (e.g., wstETH)
    /// @param _aToken The address of the aToken for the collateral asset
    /// @param _debtAsset The address of the debt asset (e.g., ETH)
    /// @param _variableDebtToken The address of the variable debt token for the debt asset
    /// @param _maxCollateralRatio The maximum collateralization ratio (e.g., 75 * 1e16 for 75%)
    /// @param _minCollateralRatio The minimum collateralization ratio (e.g., 70 * 1e16 for 70%)
    /// @param _targetCollateralRatio The target collateralization ratio (e.g., 72 * 1e16 for 72%)
    /// @param _feePercentage The fee percentage in basis points (e.g., 100 for 1%)
    constructor(
        address _aavePool,
        address _collateralAsset,
        address _aToken,
        address _debtAsset,
        address _variableDebtToken,
        uint256 _maxCollateralRatio,
        uint256 _minCollateralRatio,
        uint256 _targetCollateralRatio,
        uint256 _feePercentage
    ) {
        require(_maxCollateralRatio > _targetCollateralRatio, "Max ratio must be greater than target");
        require(_targetCollateralRatio > _minCollateralRatio, "Target ratio must be greater than min");
        require(_feePercentage <= 1000, "Fee percentage too high"); // Max 10%
        
        aavePool = IPool(_aavePool);
        collateralAsset = IERC20(_collateralAsset);
        aToken = IAToken(_aToken);
        debtAsset = IERC20(_debtAsset);
        variableDebtToken = VariableDebtToken(_variableDebtToken);
        
        maxCollateralRatio = _maxCollateralRatio;
        minCollateralRatio = _minCollateralRatio;
        targetCollateralRatio = _targetCollateralRatio;
        feePercentage = _feePercentage;
        
        // Set the collateral asset as the strategy's asset
        _addAsset(_collateralAsset, IERC20Metadata(_collateralAsset).decimals(), true);
        
        // Approve AAVE Pool to spend the collateral
        IERC20(_collateralAsset).approve(_aavePool, type(uint256).max);
    }
    
    /// @notice Sets emergency exit flag
    /// @dev Can only be called by the admin
    function setEmergencyExit(bool _emergencyExit) external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyExitActivated = _emergencyExit;
        emit EmergencyExit(block.timestamp);
    }
    
    /// @notice Updates the collateral ratio parameters
    /// @param _maxCollateralRatio The maximum collateralization ratio
    /// @param _minCollateralRatio The minimum collateralization ratio
    /// @param _targetCollateralRatio The target collateralization ratio
    function setCollateralRatioParams(
        uint256 _maxCollateralRatio,
        uint256 _minCollateralRatio,
        uint256 _targetCollateralRatio
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_maxCollateralRatio > _targetCollateralRatio, "Max ratio must be greater than target");
        require(_targetCollateralRatio > _minCollateralRatio, "Target ratio must be greater than min");
        
        maxCollateralRatio = _maxCollateralRatio;
        minCollateralRatio = _minCollateralRatio;
        targetCollateralRatio = _targetCollateralRatio;
        
        emit CollateralRatioUpdated(_maxCollateralRatio, _minCollateralRatio, _targetCollateralRatio);
    }
    
    /// @notice Sets the fee percentage
    /// @param _feePercentage The fee percentage in basis points
    function setFeePercentage(uint256 _feePercentage) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_feePercentage <= 1000, "Fee percentage too high"); // Max 10%
        feePercentage = _feePercentage;
    }

    /// @notice Deposits collateral into AAVE and starts the looping process
    /// @param amount The amount of collateral to deposit
    function depositAndLoop(uint256 amount) external onlyAllocator {
        require(!emergencyExitActivated, "Emergency exit activated");
        require(amount > 0, "Amount must be greater than 0");
        
        // Transfer collateral from caller to contract
        collateralAsset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Deposit into AAVE
        aavePool.supply(address(collateralAsset), amount, address(this), 0);
        
        // Start the looping process
        _loop();
    }
    
    /// @notice Internal function to perform the looping process based on the current position
    function _loop() internal {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , uint256 healthFactor) = 
            aavePool.getUserAccountData(address(this));
            
        // Check if we need to loop (borrow more)
        if (healthFactor == type(uint256).max || // No debt yet
            _getCurrentCollateralRatio() < targetCollateralRatio) {
                
            // Calculate the target debt amount
            uint256 targetDebtETH = (totalCollateralETH * targetCollateralRatio) / 1e18;
            
            // If we already have debt, calculate how much more to borrow
            uint256 amountToBorrow = 0;
            if (totalDebtETH < targetDebtETH) {
                amountToBorrow = targetDebtETH - totalDebtETH;
            }
            
            if (amountToBorrow > 0) {
                // Borrow debt asset
                aavePool.borrow(
                    address(debtAsset), 
                    amountToBorrow, 
                    VARIABLE_RATE, 
                    0, 
                    address(this)
                );
                
                // Swap the borrowed asset back to collateral (simulated with a 1:1 ratio)
                // In a real implementation, you would use a DEX or other swapping mechanism
                uint256 swappedCollateral = amountToBorrow;
                
                // Deposit the swapped collateral back into AAVE
                aavePool.supply(address(collateralAsset), swappedCollateral, address(this), 0);
            }
        }
    }
    
    /// @notice Rebalances the position if the collateral ratio falls outside desired range
    function rebalance() external onlyAllocator {
        require(!emergencyExitActivated, "Emergency exit activated");
        
        uint256 currentRatio = _getCurrentCollateralRatio();
        
        if (currentRatio <= minCollateralRatio) {
            // Deleverage: Withdraw collateral and repay some debt
            _deleverage();
        } else if (currentRatio >= maxCollateralRatio) {
            // Leverage more: Borrow more and provide more collateral
            _loop();
        }
        
        // Emit rebalance event with updated position
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
            aavePool.getUserAccountData(address(this));
            
        emit Rebalanced(totalCollateralETH, totalDebtETH, block.timestamp);
    }
    
    /// @notice Internal function to reduce leverage by repaying debt
    function _deleverage() internal {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
            aavePool.getUserAccountData(address(this));
            
        // Calculate target debt based on target ratio
        uint256 targetDebtETH = (totalCollateralETH * targetCollateralRatio) / 1e18;
        
        // If current debt is higher than target, reduce it
        if (totalDebtETH > targetDebtETH) {
            uint256 debtToRepay = totalDebtETH - targetDebtETH;
            
            // Withdraw collateral from AAVE
            aavePool.withdraw(address(collateralAsset), debtToRepay, address(this));
            
            // Swap collateral to debt asset (simulated with a 1:1 ratio)
            // In a real implementation, you would use a DEX or other swapping mechanism
            uint256 swappedDebt = debtToRepay;
            
            // Repay debt
            debtAsset.approve(address(aavePool), swappedDebt);
            aavePool.repay(address(debtAsset), swappedDebt, VARIABLE_RATE, address(this));
        }
    }
    
    /// @notice Full unwinding of the position in an emergency
    function emergencyExit() external onlyRole(DEFAULT_ADMIN_ROLE) {
        emergencyExitActivated = true;
        
        // Get current debt amount
        uint256 debtAmount = variableDebtToken.balanceOf(address(this));
        
        if (debtAmount > 0) {
            // Withdraw all collateral from AAVE
            uint256 aTokenBalance = aToken.balanceOf(address(this));
            aavePool.withdraw(address(collateralAsset), aTokenBalance, address(this));
            
            // Swap collateral to debt asset for repayment (simulated with a 1:1 ratio)
            // In a real implementation, you would use a DEX or other swapping mechanism
            uint256 collateralBalance = collateralAsset.balanceOf(address(this));
            uint256 swapAmount = Math.min(collateralBalance, debtAmount);
            
            // Repay as much debt as possible
            debtAsset.approve(address(aavePool), swapAmount);
            aavePool.repay(address(debtAsset), swapAmount, VARIABLE_RATE, address(this));
        } else {
            // If no debt, just withdraw everything
            uint256 aTokenBalance = aToken.balanceOf(address(this));
            aavePool.withdraw(address(collateralAsset), aTokenBalance, address(this));
        }
        
        emit EmergencyExit(block.timestamp);
    }

    /// @notice Calculates the current collateralization ratio
    /// @return The current collateralization ratio
    function _getCurrentCollateralRatio() internal view returns (uint256) {
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
            aavePool.getUserAccountData(address(this));
            
        if (totalDebtETH == 0) {
            return 0; // No debt, no ratio
        }
        
        return (totalDebtETH * 1e18) / totalCollateralETH;
    }
    
    /// @notice Returns the current health factor of the position
    /// @return The health factor
    function getHealthFactor() external view returns (uint256) {
        (, , , , , uint256 healthFactor) = aavePool.getUserAccountData(address(this));
        return healthFactor;
    }

    /// @notice Calculate the total value of assets for the strategy
    /// @return The total asset value
    function totalAssets() public view override returns (uint256) {
        // Get collateral and debt from AAVE
        (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
            aavePool.getUserAccountData(address(this));
            
        // Net value = collateral - debt
        return totalCollateralETH > totalDebtETH ? totalCollateralETH - totalDebtETH : 0;
    }
    
    /// @notice Internal function to determine available assets for withdrawal
    /// @param asset_ The asset address to check
    /// @return availableAssets The amount of available assets for withdrawal
    function _availableAssets(address asset_) internal view override returns (uint256 availableAssets) {
        if (asset_ == address(collateralAsset)) {
            // For the collateral asset, we need to calculate how much is available after accounting for debt
            (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
                aavePool.getUserAccountData(address(this));
                
            // Available = total collateral - minimum required to maintain debt
            uint256 minRequiredCollateral = 0;
            if (totalDebtETH > 0) {
                // Calculate minimum collateral needed at maximum ratio
                minRequiredCollateral = (totalDebtETH * 1e18) / maxCollateralRatio;
                
                // Add a small buffer for safety
                minRequiredCollateral = (minRequiredCollateral * 102) / 100; // +2% buffer
            }
            
            if (totalCollateralETH > minRequiredCollateral) {
                availableAssets = totalCollateralETH - minRequiredCollateral;
                
                // Check if we actually have this much collateral in the aToken
                uint256 aTokenBalance = aToken.balanceOf(address(this));
                if (availableAssets > aTokenBalance) {
                    availableAssets = aTokenBalance;
                }
            } else {
                availableAssets = 0;
            }
            
            // Add any direct balance of collateral in the contract
            availableAssets += IERC20(asset_).balanceOf(address(this));
        } else {
            // For other assets, just return the balance
            availableAssets = IERC20(asset_).balanceOf(address(this));
        }
    }
    
    /// @notice Implementation of withdraw function to handle unwinding when needed
    /// @param caller The address calling the withdraw function
    /// @param receiver The address receiving the withdrawn assets
    /// @param owner The owner of the shares being burned
    /// @param assets The amount of assets to withdraw
    /// @param shares The amount of shares to burn
    function _withdrawAsset(
        address asset_,
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) internal override onlyAllocator {
        if (asset_ == address(collateralAsset)) {
            // Check if we need to unwind some positions to fulfill withdrawal
            uint256 directBalance = collateralAsset.balanceOf(address(this));
            
            if (assets > directBalance) {
                uint256 amountToWithdraw = assets - directBalance;
                
                // Calculate how much aToken we need to withdraw
                uint256 aTokenToWithdraw = amountToWithdraw;
                
                // Check if we need to deleverage first
                (uint256 totalCollateralETH, uint256 totalDebtETH, , , , ) = 
                    aavePool.getUserAccountData(address(this));
                    
                if (totalDebtETH > 0) {
                    // Calculate the new collateral amount after withdrawal
                    uint256 remainingCollateral = totalCollateralETH - amountToWithdraw;
                    
                    // Check if this would breach our max collateral ratio
                    uint256 newRatio = (totalDebtETH * 1e18) / remainingCollateral;
                    
                    if (newRatio > maxCollateralRatio) {
                        // Need to repay some debt first
                        uint256 targetDebt = (remainingCollateral * targetCollateralRatio) / 1e18;
                        uint256 debtToRepay = totalDebtETH - targetDebt;
                        
                        if (debtToRepay > 0) {
                            // We need to withdraw extra collateral to repay debt
                            uint256 extraWithdrawal = debtToRepay;
                            
                            // Withdraw the extra amount
                            aavePool.withdraw(
                                address(collateralAsset), 
                                extraWithdrawal, 
                                address(this)
                            );
                            
                            // Swap to debt asset (simulated 1:1)
                            // In a real implementation, use a DEX
                            
                            // Repay debt
                            debtAsset.approve(address(aavePool), debtToRepay);
                            aavePool.repay(
                                address(debtAsset), 
                                debtToRepay, 
                                VARIABLE_RATE, 
                                address(this)
                            );
                        }
                    }
                }
                
                // Now withdraw the requested amount
                aavePool.withdraw(address(collateralAsset), aTokenToWithdraw, address(this));
            }
        }
        
        // Continue with the standard withdrawal logic
        super._withdrawAsset(asset_, caller, receiver, owner, assets, shares);
    }

    /// @notice Fee calculation on raw amount
    /// @param assets The asset amount
    /// @return fee The fee amount
    function _feeOnRaw(uint256 assets) public view override returns (uint256) {
        return (assets * feePercentage) / 10000;
    }

    /// @notice Fee calculation on total amount
    /// @param assets The asset amount
    /// @return fee The fee amount
    function _feeOnTotal(uint256 assets) public view override returns (uint256) {
        return (assets * feePercentage) / 10000;
    }
    
    /// @notice Rescue tokens that are stuck in the contract
    /// @param token The token to rescue
    /// @param to The address to send the tokens to
    /// @param amount The amount of tokens to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        // Cannot rescue collateral or debt tokens unless in emergency
        if (!emergencyExitActivated) {
            require(
                token != address(collateralAsset) && 
                token != address(debtAsset) &&
                token != address(aToken) &&
                token != address(variableDebtToken),
                "Cannot rescue protocol tokens"
            );
        }
        
        IERC20(token).safeTransfer(to, amount);
    }
}