// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;

import {BaseStrategy} from "src/strategy/BaseStrategy.sol";
import {IERC20} from "src/Common.sol";
import {IPool} from "lib/aave-v3-core/contracts/interfaces/IPool.sol"; // Interface for AAVE V3 Pool

contract AAVEV3LoopingStrategy is BaseStrategy {
    /// @notice The AAVE V3 Pool contract
    IPool public immutable aavePool;

    /// @notice The collateral asset (e.g., wstETH)
    IERC20 public immutable collateralAsset;

    /// @notice The debt asset (e.g., ETH)
    IERC20 public immutable debtAsset;

    /// @notice The maximum collateralization ratio (e.g., 75%)
    uint256 public maxCollateralRatio;

    /// @notice The minimum collateralization ratio for rebalancing (e.g., 70%)
    uint256 public minCollateralRatio;

    /// @notice Constructor to initialize the strategy
    /// @param _aavePool The address of the AAVE V3 Pool contract
    /// @param _collateralAsset The address of the collateral asset (e.g., wstETH)
    /// @param _debtAsset The address of the debt asset (e.g., ETH)
    /// @param _maxCollateralRatio The maximum collateralization ratio
    /// @param _minCollateralRatio The minimum collateralization ratio
    constructor(
        address _aavePool,
        address _collateralAsset,
        address _debtAsset,
        uint256 _maxCollateralRatio,
        uint256 _minCollateralRatio
    ) {
        aavePool = IPool(_aavePool);
        collateralAsset = IERC20(_collateralAsset);
        debtAsset = IERC20(_debtAsset);
        maxCollateralRatio = _maxCollateralRatio;
        minCollateralRatio = _minCollateralRatio;
    }

    /// @notice Deposits collateral into AAVE and starts the looping process
    /// @param amount The amount of collateral to deposit
    function depositAndLoop(uint256 amount) external onlyAllocator {
        // Transfer collateral from the caller to the contract
        collateralAsset.transferFrom(msg.sender, address(this), amount);

        // Approve AAVE Pool to spend the collateral
        collateralAsset.approve(address(aavePool), amount);

        // Deposit collateral into AAVE
        aavePool.supply(address(collateralAsset), amount, address(this), 0);

        // Start the looping process
        _loop(amount);
    }

    /// @notice Internal function to perform the looping process
    /// @param initialAmount The initial amount of collateral deposited
    function _loop(uint256 initialAmount) internal {
        uint256 currentCollateral = initialAmount;

        while (true) {
            // Calculate the maximum amount that can be borrowed
            uint256 maxBorrow = (currentCollateral * maxCollateralRatio) / 1e18;

            // Borrow the debt asset
            aavePool.borrow(address(debtAsset), maxBorrow, 2, 0, address(this));

            // Swap the borrowed asset back to collateral (if needed)
            // For simplicity, assume 1:1 conversion (e.g., ETH to wstETH)
            uint256 swappedCollateral = maxBorrow;

            // Deposit the swapped collateral back into AAVE
            collateralAsset.approve(address(aavePool), swappedCollateral);
            aavePool.supply(address(collateralAsset), swappedCollateral, address(this), 0);

            // Update the current collateral amount
            currentCollateral += swappedCollateral;

            // Break the loop if the collateralization ratio is close to the max
            if (currentCollateral * maxCollateralRatio / 1e18 < maxBorrow) {
                break;
            }
        }
    }

    /// @notice Calculates the value of the strategy's tokenized asset in ETH
    /// @return The value of 1 strategy token in ETH
    function getTokenValueInETH() external view returns (uint256) {
        // Fetch the total collateral and debt from AAVE
        (uint256 totalCollateral, uint256 totalDebt) = _getAavePosition();

        // Calculate the net value in ETH
        return totalCollateral - totalDebt;
    }

    /// @notice Internal function to fetch the strategy's position on AAVE
    /// @return totalCollateral The total collateral in AAVE
    /// @return totalDebt The total debt in AAVE
    function _getAavePosition() internal view returns (uint256 totalCollateral, uint256 totalDebt) {
        (totalCollateral, totalDebt, , , , ) = aavePool.getUserAccountData(address(this));
    }

    function _feeOnRaw(uint256 assets) public view override returns (uint256) {
        // Example: Apply a 1% fee on the raw assets
        return (assets * 1) / 100;
    }

    function _feeOnTotal(uint256 assets) public view override returns (uint256) {
        // Example: Apply a 0.5% fee on the total assets
        return (assets * 5) / 1000;
    }
}