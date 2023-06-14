// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.15;

/// @title TWAMM OrderPool - Represents an OrderPool inside of a TWAMM
library AqueductOrderPool {
    /// @notice Information related to a long term order pool.
    /// @member sellRateCurrent The total current sell rate (sellAmount / second) among all orders
    /// @member earningsFactor Sum of (salesEarnings_k / salesRate_k) over every period k. Stored as Fixed Point X96.
    struct State {
        uint256 sellRateCurrent;
        uint256 earningsFactorCurrent;
    }

    // Performs all the updates on an OrderPool that must happen when updating to the current time not on an interval
    function advanceToCurrentTime(State storage self, uint256 earningsFactor) internal {
        unchecked {
            self.earningsFactorCurrent += earningsFactor;
        }
    }
}
