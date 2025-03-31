// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV2Router02 {
    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible
    /// @param amountIn The amount of input tokens to send
    /// @param amountOutMin The minimum amount of output tokens that must be received for the transaction not to revert
    /// @param path An array of token addresses. path.length must be >= 2. 
    /// The first element of path is the input token, the last is the output token.
    /// @param to Recipient of the output tokens.
    /// @param deadline Unix timestamp after which the transaction will revert.
    /// @return amounts The input token amount and all subsequent output token amounts.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);
}