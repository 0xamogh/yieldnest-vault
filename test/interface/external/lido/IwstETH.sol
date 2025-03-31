// SPDX-License-Identifier: BSD-3-Clause
pragma solidity ^0.8.24;
import {IERC20} from "src/Common.sol";

interface IwstETH is IERC20{
    function wrap(uint256 _stETHAmount) external returns (uint256);
    function unwrap(uint256 _wstETHAmount) external returns (uint256);
}
